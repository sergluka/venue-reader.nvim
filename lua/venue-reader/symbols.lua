local M = {}
local Request = require("venue-reader.symbols.request")
local observers = {}
local next_picker = 0

local function watch(buffer, callback)
  local observer = observers[buffer]
  if not observer then
    observer = {}
    observers[buffer] = observer
    vim.api.nvim_buf_attach(buffer, false, {
      on_lines = function()
        for listener in pairs(observer) do
          listener("changed")
        end
      end,
      on_reload = function()
        for listener in pairs(observer) do
          listener("changed")
        end
      end,
      on_detach = function()
        observers[buffer] = nil
        for listener in pairs(observer) do
          listener("detached")
        end
      end,
    })
  end
  observer[callback] = true
  return function()
    observer[callback] = nil
  end
end

function M.open(client, buffer, options)
  local available, pickers = pcall(require, "telescope.pickers")
  assert(available, "Document symbols requires telescope.nvim and plenary.nvim")
  local config = require("telescope.config").values
  local actions = require("telescope.actions")
  local async = require("plenary.async")
  local opts = vim.tbl_extend("force", {}, options or {})
  opts.bufnr = buffer
  opts.path_display = opts.path_display or { "hidden" }
  opts.cache_picker = false
  opts.selection_strategy = "follow"
  local timeout = opts.timeout_ms == nil and 30000 or opts.timeout_ms
  assert(
    type(timeout) == "number" and timeout >= 0 and timeout < math.huge and timeout % 1 == 0,
    "symbols.timeout_ms must be a finite non-negative integer"
  )
  assert(client.initialized and not client:is_stopped(), "Venue Reader is not ready")
  assert(vim.lsp.buf_is_attached(buffer, client.id), "Venue Reader is not attached to the buffer")
  assert(
    client:supports_method("textDocument/documentSymbol", buffer),
    "Server does not provide document symbols"
  )

  local allowed
  if opts.symbols then
    local kinds = type(opts.symbols) == "string" and { opts.symbols } or opts.symbols
    assert(type(kinds) == "table" and vim.islist(kinds), "symbols must be a kind name or list")
    allowed = {}
    for _, kind in ipairs(kinds) do
      assert(type(kind) == "string", "symbol kinds must be strings")
      allowed[kind:lower()] = true
    end
  end
  local entry_maker = opts.entry_maker or require("telescope.make_entry").gen_from_lsp_symbols(opts)
  local source_uri = vim.uri_from_bufnr(buffer)
  local entries, queue, timers = {}, {}, {}
  local queue_head = 1
  local epoch = 0
  local changedtick = vim.api.nvim_buf_get_changedtick(buffer)
  local closed, loading, processing, responded = false, true, false, false
  local failure, percentage, request, picker, unwatch
  local refreshes = 0
  local displayed = false
  local representation
  next_picker = next_picker + 1
  local group =
    vim.api.nvim_create_augroup("venue-reader-symbols-" .. next_picker, { clear = true })

  local function stop_timer(name)
    local timer = timers[name]
    if timer then
      timers[name] = nil
      timer:stop()
      timer:close()
    end
  end

  local function later(name, delay, callback)
    stop_timer(name)
    local timer = assert(vim.uv.new_timer())
    timers[name] = timer
    timer:start(
      delay,
      0,
      vim.schedule_wrap(function()
        if timers[name] ~= timer then
          return
        end
        stop_timer(name)
        if not closed then
          callback()
        end
      end)
    )
  end

  local function current(captured)
    return not closed
      and (captured == nil or captured == epoch)
      and vim.api.nvim_buf_is_valid(buffer)
      and vim.api.nvim_buf_is_loaded(buffer)
      and vim.uri_from_bufnr(buffer) == source_uri
      and vim.api.nvim_buf_get_changedtick(buffer) == changedtick
  end

  local function finder()
    local snapshot, count, captured, stopped = entries, #entries, epoch, false
    return setmetatable({
      close = function()
        stopped = true
      end,
    }, {
      __call = function(_, _, process, complete)
        local started = vim.uv.hrtime()
        for index = 1, count do
          if stopped or not current(captured) then
            return
          end
          local entry = snapshot[index]
          entry.index = index
          if process(entry) then
            return
          end
          if vim.uv.hrtime() - started >= 2000000 then
            async.util.sleep(1)
            started = vim.uv.hrtime()
          end
        end
        if not stopped and current(captured) then
          complete()
        end
      end,
    })
  end

  local function refresh(immediate)
    immediate = immediate or (not displayed and #entries > 0)
    if closed or (timers.refresh and not immediate) then
      return
    end
    later("refresh", (immediate or refreshes == 0) and 0 or 100, function()
      if current() and vim.api.nvim_buf_is_valid(picker.prompt_bufnr) then
        refreshes = refreshes + 1
        displayed = displayed or #entries > 0
        picker:refresh(finder(), { reset_prompt = false })
      end
    end)
  end

  local function clear()
    entries, queue, queue_head, processing = {}, {}, 1, false
    stop_timer("convert")
    if picker then
      picker.finder:close()
      picker._selection_entry = nil
      for _, entry in ipairs(picker:get_multi_selection()) do
        picker._multi:drop(entry)
      end
    end
  end

  local function cancel()
    if request then
      request.cancel()
      request = nil
    end
  end

  local function fail(message)
    cancel()
    failure, loading = tostring(message), false
    clear()
    refresh(true)
  end

  local function close()
    if closed then
      return
    end
    closed = true
    epoch = epoch + 1
    cancel()
    for name in pairs(timers) do
      stop_timer(name)
    end
    if unwatch then
      unwatch()
    end
    vim.api.nvim_del_augroup_by_id(group)
    clear()
  end

  local function close_window()
    close()
    vim.schedule(function()
      if picker and vim.api.nvim_buf_is_valid(picker.prompt_bufnr) then
        actions.close(picker.prompt_bufnr)
      end
    end)
  end

  local pump
  pump = function()
    if not current() or failure then
      return
    end
    local started = vim.uv.hrtime()
    while queue_head <= #queue do
      local batch = queue[queue_head]
      while batch.next <= #batch.symbols do
        local symbol = batch.symbols[batch.next]
        local shape = type(symbol) == "table" and (symbol.location and "flat" or "tree")
        if not shape or (representation and representation ~= shape) then
          fail("Invalid or mixed document symbol representations")
          return
        end
        representation = shape
        local success, items =
          pcall(vim.lsp.util.symbols_to_items, { symbol }, buffer, client.offset_encoding)
        if not success or #items == 0 then
          fail(success and "Invalid document symbol" or items)
          return
        end
        for _, item in ipairs(items) do
          if not allowed or allowed[item.kind:lower()] then
            local made, entry = pcall(entry_maker, item)
            if not made then
              fail(entry)
              return
            end
            if entry then
              if not opts.entry_maker then
                local display = entry.display
                entry.display = function(value)
                  local width = math.max(vim.o.columns, opts.symbol_width or 25) + 1
                  if #value.symbol_name > width * 4 then
                    -- Plenary's truncator copies the remaining string for every character.
                    local visible = setmetatable({
                      symbol_name = vim.fn.strcharpart(value.symbol_name, 0, width),
                    }, { __index = value })
                    return display(visible)
                  end
                  return display(value)
                end
              end
              entries[#entries + 1] = entry
            end
          end
        end
        batch.symbols[batch.next] = false
        batch.next = batch.next + 1
        if vim.uv.hrtime() - started >= 2000000 then
          refresh()
          later("convert", 1, pump)
          return
        end
      end
      queue[queue_head] = false
      queue_head = queue_head + 1
    end
    queue, queue_head, processing = {}, 1, false
    if responded then
      loading = false
    end
    refresh()
  end

  local function start()
    if not current() then
      close_window()
      return
    end
    if client:is_stopped() or not vim.lsp.buf_is_attached(buffer, client.id) then
      fail("Venue Reader disconnected")
      return
    end
    local captured = epoch
    request = Request.start(client, buffer, {
      timeout_ms = timeout,
      on_batch = function(symbols)
        if not current(captured) then
          return
        end
        queue[#queue + 1] = { symbols = symbols, next = 1 }
        if not processing then
          processing = true
          later("convert", 0, pump)
        end
      end,
      on_progress = function(progress)
        if not current(captured) then
          return
        end
        if type(progress.percentage) == "number" then
          percentage = math.max(percentage or 0, math.min(100, math.max(0, progress.percentage)))
        end
        refresh()
      end,
      on_done = function(err)
        if not current(captured) then
          return
        end
        responded = true
        if err then
          fail(type(err) == "table" and err.message or err)
        else
          if not processing then
            loading = false
          end
          refresh()
        end
      end,
    })
  end

  opts.get_status_text = function()
    if loading then
      return "Loading symbols…" .. (percentage and (" " .. math.floor(percentage) .. "%") or "")
    end
    return failure and ("Failed: " .. failure) or "Request finished"
  end
  picker = pickers.new(opts, {
    prompt_title = "Venue Reader Symbols",
    finder = finder(),
    previewer = config.qflist_previewer(opts),
    sorter = config.prefilter_sorter({ tag = "symbol_type", sorter = config.generic_sorter(opts) }),
    push_cursor_on_edit = true,
    push_tagstack_on_edit = true,
  })
  local get_selection = picker.get_selection
  picker.get_selection = function(self)
    if current() and not failure then
      return get_selection(self)
    end
  end
  picker:find()
  unwatch = watch(buffer, function(event)
    if event == "detached" then
      close_window()
      return
    end
    epoch = epoch + 1
    cancel()
    clear()
    changedtick = vim.api.nvim_buf_get_changedtick(buffer)
    failure, percentage, representation = nil, nil, nil
    loading, responded, refreshes, displayed = true, false, 0, false
    refresh(true)
    later("restart", 150, start)
  end)
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = picker.prompt_bufnr,
    callback = close,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufFilePre" }, {
    group = group,
    buffer = buffer,
    callback = close_window,
  })
  vim.api.nvim_create_autocmd("LspDetach", {
    group = group,
    buffer = buffer,
    callback = function(event)
      if event.data.client_id == client.id then
        fail("Venue Reader disconnected")
      end
    end,
  })
  start()
  return picker
end

return M

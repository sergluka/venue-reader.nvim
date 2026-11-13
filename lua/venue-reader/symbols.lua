local M = {}
local Request = require("venue-reader.symbols.request")
local observers = {}
local next_picker = 0

local function before(left, right)
  return left.line < right.line or (left.line == right.line and left.character < right.character)
end

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

-- Upstream streaming will make this custom picker unnecessary:
-- https://github.com/folke/snacks.nvim/issues/2993
function M.open(client, buffer, options)
  local available, snacks = pcall(require, "snacks")
  assert(available, "Document symbols requires snacks.nvim")
  local lsp = require("snacks.picker.source.lsp")
  local opts = vim.tbl_deep_extend("force", {
    tree = true,
    keep_parents = true,
    filter = { fix = true, default = true },
  }, options or {})
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
  local kinds = opts.filter[vim.bo[buffer].filetype]
  if kinds == nil then
    kinds = opts.filter.default
  end
  assert(
    type(kinds) == "boolean" or (type(kinds) == "table" and vim.islist(kinds)),
    "filter must provide a boolean or symbol-kind list for this filetype"
  )
  local source_uri = vim.uri_from_bufnr(buffer)
  local source_window = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(source_window) ~= buffer then
    source_window = vim.fn.win_findbuf(buffer)[1]
  end
  local cursor_position = source_window
    and vim.lsp.util.make_position_params(source_window, client.offset_encoding).position
  local cursor_entry, cursor_depth
  local entries, queue, timers = {}, {}, {}
  local root, last = { root = true }, {}
  local queue_head, epoch = 1, 0
  local changedtick = vim.api.nvim_buf_get_changedtick(buffer)
  local closed, loading, processing, responded = false, true, false, false
  local failure, percentage, representation, request, picker, unwatch
  next_picker = next_picker + 1
  local group =
    vim.api.nvim_create_augroup("venue-reader-symbols-" .. next_picker, { clear = true })

  local function stop_cursor_selection()
    cursor_position, cursor_entry, cursor_depth = nil, nil, nil
  end

  local function valid_source()
    return vim.api.nvim_buf_is_valid(buffer)
      and vim.api.nvim_buf_is_loaded(buffer)
      and vim.uri_from_bufnr(buffer) == source_uri
      and vim.api.nvim_buf_get_changedtick(buffer) == changedtick
  end

  local function current(captured)
    -- Buffer observers invalidate the generation before async finders resume.
    if vim.in_fast_event() then
      return not closed and (captured == nil or captured == epoch)
    end
    return not closed and (captured == nil or captured == epoch) and valid_source()
  end

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

  local function refresh()
    if not picker or closed then
      return
    end
    picker.title = loading
        and ("Loading symbols…" .. (percentage and (" " .. math.floor(percentage) .. "%") or ""))
      or (failure and ("Failed: " .. failure) or "Request finished")
    picker.finder.task:resume()
    picker.list.dirty = true
    picker:update_titles()
    picker:update()
  end

  local function cancel()
    if request then
      request.cancel()
      request = nil
    end
  end

  local function clear(preserve_items)
    stop_cursor_selection()
    entries, queue, queue_head, processing = {}, {}, 1, false
    root, last = { root = true }, {}
    stop_timer("convert")
    if picker and not picker.closed then
      -- Finish aborted coroutines before Snacks replaces their task objects.
      for _, owner in ipairs({ picker.finder, picker.matcher }) do
        local task = owner.task
        task:abort()
        task:step()
      end
      if preserve_items then
        return
      end
      picker.finder.items = {}
      -- Buffer observers run under textlock; invalidate without rendering.
      picker.list.selected, picker.list.selected_map = {}, {}
      picker.list:clear()
      picker.list.target = nil
    end
  end

  local function restart_finder()
    if current() and picker then
      picker:find({ refresh = true })
      refresh()
    end
  end

  local function fail(message)
    cancel()
    failure, loading = tostring(message), false
    clear()
    later("refresh", 0, restart_finder)
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
    -- Snacks exports list items after on_close; let its teardown retain them.
    clear(true)
  end

  local function close_window()
    close()
    vim.schedule(function()
      if picker and not picker.closed then
        picker:close()
      end
    end)
  end

  local function convert(symbol, parent, depth)
    assert(type(symbol) == "table", "Invalid document symbol")
    local shape = symbol.location and "flat" or "tree"
    assert(
      not representation or representation == shape,
      "Invalid or mixed document symbol representations"
    )
    representation = shape
    local kind = lsp.symbol_kind(symbol.kind)
    local location = symbol.location
      or { uri = source_uri, range = symbol.selectionRange or symbol.range }
    local range = symbol.location and symbol.location.range or symbol.range
    assert(type(symbol.name) == "string" and range and location.range, "Invalid document symbol")
    if type(kinds) == "boolean" or vim.tbl_contains(kinds, kind) then
      local item = {
        name = symbol.name,
        kind = kind,
        detail = symbol.detail,
        text = kind .. " " .. symbol.name,
        range = range,
        item = symbol,
        parent = parent,
        tree = opts.tree,
        last = true,
      }
      lsp.add_loc(item, location, client)
      item.buf = location.uri == source_uri and buffer or vim.fn.bufnr(item.file)
      if item.buf == -1 then
        item.buf = nil
      end
      if last[parent] then
        last[parent].last = nil
      end
      last[parent] = item
      entries[#entries + 1] = item
      parent = item
      if
        cursor_position
        and location.uri == source_uri
        and not before(cursor_position, range.start)
        and before(cursor_position, range["end"])
      then
        local previous = cursor_entry and cursor_entry.range
        if
          not previous
          or (
            not before(range.start, previous.start)
            and not before(previous["end"], range["end"])
            and (
              before(previous.start, range.start)
              or before(range["end"], previous["end"])
              or depth > cursor_depth
            )
          )
        then
          cursor_entry, cursor_depth = item, depth
        end
      end
    end
    for _, child in ipairs(symbol.children or {}) do
      convert(child, parent, depth + 1)
    end
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
        local success, err = pcall(convert, batch.symbols[batch.next], root, 0)
        if not success then
          fail(err)
          return
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
        if current(captured) then
          if type(progress.percentage) == "number" then
            percentage = math.max(percentage or 0, math.min(100, math.max(0, progress.percentage)))
          end
          refresh()
        end
      end,
      on_done = function(err)
        if not current(captured) then
          return
        end
        responded = true
        if err then
          fail(type(err) == "table" and err.message or err)
        else
          loading = processing
          refresh()
        end
      end,
    })
  end

  opts.finder = function(_, context)
    local captured = epoch
    return function(emit)
      local index = 1
      while current(captured) and not failure do
        while index <= #entries and current(captured) do
          emit(entries[index])
          index = index + 1
        end
        if not loading then
          return
        end
        context.async:suspend()
      end
    end
  end
  opts.matcher = vim.tbl_extend("force", opts.matcher or {}, {
    keep_parents = opts.keep_parents,
    sort = true,
    sort_empty = opts.keep_parents or (opts.matcher and opts.matcher.sort_empty),
  })
  if opts.keep_parents then
    opts.sort = { fields = { "idx" } }
  end
  opts.live, opts.show_empty, opts.auto_confirm = false, true, false
  opts.find, opts.title = false, "Loading symbols…"
  opts.limit, opts.limit_live = math.huge, math.huge
  local on_close = opts.on_close
  opts.on_close = function(value)
    close()
    if on_close then
      on_close(value)
    end
  end
  for _, existing in ipairs(snacks.picker.get({ source = "lsp_symbols" })) do
    existing:close()
  end
  picker = snacks.picker.lsp_symbols(opts)
  local get_current, selected = picker.current, picker.selected
  picker.current = function(self, ...)
    if current() and not failure then
      return get_current(self, ...)
    end
  end
  picker.selected = function(self, ...)
    return valid_source() and not failure and selected(self, ...) or {}
  end
  local query_pattern = picker.input.filter.pattern
  local query_pending = query_pattern ~= ""
  for _, method in ipairs({ "move", "select" }) do
    local original = picker.list[method]
    picker.list[method] = function(self, ...)
      -- List rendering calls move(0) to clamp its cursor.
      if method ~= "move" or select(1, ...) ~= 0 then
        query_pattern, query_pending = picker.input.filter.pattern, false
        stop_cursor_selection()
      end
      return original(self, ...)
    end
  end
  local match_done = picker.matcher.on_done
  picker.matcher.on_done = function(self, value)
    local selection = cursor_entry or picker:current({ resolve = false })
    local pattern, captured = picker.input.filter.pattern, epoch
    match_done(self, value)
    -- The stock symbol matcher moves to the first match at completion.
    vim.schedule(function()
      if current(captured) and picker.input.filter.pattern == pattern and selection then
        for index = 1, picker.list:count() do
          if picker.list:get(index) == selection then
            picker.list:view(index)
            break
          end
        end
      end
    end)
  end
  local update = picker.list.update
  picker.list.update = function(self, ...)
    local pattern = picker.input.filter.pattern
    if pattern ~= query_pattern then
      query_pattern, query_pending = pattern, pattern ~= ""
    end
    if query_pending then
      for index = 1, self:count() do
        local item = self:get(index)
        if item.match_tick == picker.matcher.tick and not item.child_match_only then
          self:view(index, nil, false)
          query_pending = false
          break
        end
      end
    end
    if cursor_entry and current() and picker.input.filter.pattern == "" then
      for index = 1, self:count() do
        if self:get(index) == cursor_entry then
          self:view(index, nil, false)
          break
        end
      end
    end
    return update(self, ...)
  end
  if picker.input.filter.pattern ~= "" then
    stop_cursor_selection()
  end
  picker:show()
  vim.api.nvim_buf_attach(picker.input.win.buf, false, {
    on_lines = stop_cursor_selection,
  })
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
    loading, responded = true, false
    later("refresh", 0, restart_finder)
    later("restart", 150, start)
  end)
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
  picker:find()
  picker:show()
  start()
  return picker
end

return M

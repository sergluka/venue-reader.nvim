local M = {}

local namespace = vim.api.nvim_create_namespace("venue-reader.summary")
local documents = {}
local options = { mode = "off", highlight = "VenueReaderSummary" }
local managed
local generation = 0
local queued = false
local channels = {
  front = { inlayHints = true, codeLens = false },
  above = { inlayHints = true, codeLens = false },
  codelens = { inlayHints = false, codeLens = true },
  off = { inlayHints = false, codeLens = false },
}

local function custom()
  return options.mode == "front" or options.mode == "above"
end

local function clear(buffer)
  if vim.api.nvim_buf_is_valid(buffer) then
    vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
  end
end

local function document(buffer, client_id)
  documents[buffer] = documents[buffer] or { revision = 0, clients = {} }
  local doc = documents[buffer]
  doc.clients[client_id] = doc.clients[client_id] or {}
  return doc, doc.clients[client_id]
end

local function invalidate(buffer, client_id)
  local doc = documents[buffer]
  if not doc then
    return
  end
  local state = doc.clients[client_id]
  if state and state.query then
    local client = vim.lsp.get_client_by_id(client_id)
    if client then
      client:cancel_request(state.query)
    end
  end
  doc.clients[client_id] = nil
  doc.revision = doc.revision + 1
  clear(buffer)
end

local function problem(state, buffer)
  if options.mode == "off" then
    return
  end
  if not state.configuration then
    return state.failure or "Effective configuration pending"
  end
  local effective = state.configuration.effective
  if effective["messageSummary.enabled"] == false then
    return "messageSummary.enabled is disabled by effective server configuration"
  end
  for key, expected in pairs(channels[options.mode]) do
    local setting = "messageSummary.channels." .. key
    if effective[setting] ~= expected then
      local source = state.configuration.sources and state.configuration.sources[setting]
      if type(source) == "table" and source.layer == "client" then
        return "Server configuration update pending"
      end
      return setting .. " conflicts with " .. options.mode .. "; source: " .. vim.inspect(source)
    end
  end
  local limit =
    effective[options.mode == "codelens" and "limits.codeLensLines" or "limits.rangeLines"]
  if options.mode ~= "off" and limit and vim.api.nvim_buf_line_count(buffer) > limit then
    return "Document exceeds effective "
      .. (options.mode == "codelens" and "limits.codeLensLines" or "limits.rangeLines")
      .. " ("
      .. limit
      .. ")"
  end
end

local function valid(state, buffer, client_id)
  return state.hints
    and state.tick == vim.api.nvim_buf_get_changedtick(buffer)
    and state.uri == vim.uri_from_bufnr(buffer)
    and state.generation == generation
    and vim.lsp.buf_is_attached(buffer, client_id)
    and not problem(state, buffer)
end

local function redraw()
  if queued then
    return
  end
  queued = true
  local captured = generation
  vim.schedule(function()
    queued = false
    if captured ~= generation then
      return redraw()
    end
    vim.cmd("redraw!")
    if options.mode ~= "above" then
      return
    end
    for _, window in ipairs(vim.api.nvim_list_wins()) do
      local buffer = vim.api.nvim_win_get_buf(window)
      local doc = documents[buffer]
      if doc and vim.lsp.inlay_hint.is_enabled({ bufnr = buffer }) then
        local first_line = false
        for client_id, state in pairs(doc.clients) do
          if valid(state, buffer, client_id) then
            for _, hint in ipairs(state.hints) do
              if hint.position.line == 0 then
                first_line = true
              end
            end
          end
        end
        if first_line then
          vim.api.nvim_win_call(window, function()
            local view = vim.fn.winsaveview()
            if view.topline == 1 and view.topfill < 1 then
              vim.fn.winrestview({ topfill = 1 })
            end
          end)
        end
      end
    end
  end)
end

local function configure_document(client, buffer, state)
  if state.query then
    return
  end
  local commands = client.server_capabilities.executeCommandProvider
  if not commands or not vim.tbl_contains(commands.commands or {}, "fix.describeOverrides") then
    state.failure = "Server does not advertise fix.describeOverrides"
    return
  end
  local captured, epoch = generation, state.epoch
  local success, request_id = client:request("workspace/executeCommand", {
    command = "fix.describeOverrides",
    arguments = { vim.uri_from_bufnr(buffer) },
  }, function(err, result)
    local doc = documents[buffer]
    if
      not doc
      or doc.clients[client.id] ~= state
      or captured ~= generation
      or state.epoch ~= epoch
    then
      return
    end
    state.query = nil
    if err or type(result) ~= "table" or type(result.effective) ~= "table" then
      state.failure = err and err.message or "Effective configuration pending"
    else
      state.configuration, state.failure = result, nil
      local warning = problem(state, buffer)
      if warning and warning ~= "Server configuration update pending" then
        if options.mode == "codelens" then
          vim.lsp.codelens.enable(false, { client_id = client.id })
        end
        vim.notify_once("venue-reader: " .. warning, vim.log.levels.WARN)
      end
    end
    doc.revision = doc.revision + 1
    redraw()
  end, buffer)
  if success then
    state.query = request_id
  end
end

function M.settings(summary, settings)
  assert(
    type(summary) == "table" and channels[summary.mode],
    "summary.mode: use front, above, codelens or off"
  )
  assert(type(summary.highlight) == "string", "summary.highlight must be a highlight group")
  local result = vim.deepcopy(settings)
  result.fix = result.fix or {}
  local configured = result.fix.messageSummary or {}
  for key, expected in pairs(channels[summary.mode]) do
    local explicit = configured.channels and configured.channels[key]
    assert(
      explicit == nil or explicit == expected,
      "settings.fix.messageSummary.channels." .. key .. " contradicts summary.mode"
    )
  end
  result.fix.messageSummary =
    vim.tbl_deep_extend("force", configured, { channels = channels[summary.mode] })
  return result
end

function M.attach(client, buffer)
  vim.lsp.codelens.enable(options.mode == "codelens", { client_id = client.id })
  if custom() then
    vim.lsp.inlay_hint.enable(true, { bufnr = buffer })
  elseif options.mode == "codelens" then
    vim.lsp.codelens.enable(true, { bufnr = buffer })
    local _, state = document(buffer, client.id)
    configure_document(client, buffer, state)
  end
end

function M.handler(err, result, ctx)
  local fields, summaries = {}, {}
  for _, hint in ipairs(result or {}) do
    if hint.data and hint.data.kind == "summary" then
      table.insert(summaries, hint)
    else
      table.insert(fields, hint)
    end
  end
  vim.lsp.handlers["textDocument/inlayHint"](err, fields, ctx)
  local doc = documents[ctx.bufnr]
  local state = doc and doc.clients[ctx.client_id]
  local request = state and state.latest
  if not request or request.id ~= ctx.request_id then
    return
  end
  state.latest = nil
  if
    err
    or request.cancelled
    or request.tick ~= vim.api.nvim_buf_get_changedtick(ctx.bufnr)
    or request.uri ~= vim.uri_from_bufnr(ctx.bufnr)
    or request.generation ~= generation
    or not custom()
    or not vim.lsp.inlay_hint.is_enabled({ bufnr = ctx.bufnr })
    or not vim.lsp.buf_is_attached(ctx.bufnr, ctx.client_id)
  then
    return
  end
  state.hints = {}
  for _, hint in ipairs(summaries) do
    if
      hint.data.uri == request.uri
      and hint.data.version == ctx.version
      and hint.position.character == 0
    then
      table.insert(state.hints, hint)
    end
  end
  state.tick, state.uri, state.generation = request.tick, request.uri, generation
  doc.revision = doc.revision + 1
  configure_document(vim.lsp.get_client_by_id(ctx.client_id), ctx.bufnr, state)
  redraw()
end

function M.status(buffer, client_id)
  local doc = documents[buffer]
  local state = doc and doc.clients[client_id]
  local enabled = vim.lsp.inlay_hint.is_enabled({ bufnr = buffer })
  if options.mode == "codelens" then
    enabled = vim.lsp.codelens.is_enabled({ bufnr = buffer, client_id = client_id })
  end
  local warning
  if state then
    warning = problem(state, buffer)
  elseif options.mode ~= "off" then
    warning = "Effective configuration pending"
  end
  return {
    mode = options.mode,
    native_enabled = enabled,
    effective = state and state.configuration and state.configuration.effective,
    problem = warning,
    lines = vim.api.nvim_buf_is_valid(buffer) and vim.api.nvim_buf_line_count(buffer) or nil,
  }
end

function M.configure(summary, predicate)
  managed = predicate
  if vim.deep_equal(options, summary) then
    return false
  end
  generation = generation + 1
  for buffer, doc in pairs(documents) do
    for client_id in pairs(doc.clients) do
      invalidate(buffer, client_id)
    end
  end
  documents = {}
  options = vim.deepcopy(summary)
  vim.api.nvim_set_hl(0, options.highlight, { default = true, link = "Comment" })
  for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
    if managed(client) then
      vim.lsp.codelens.enable(false, { client_id = client.id })
    end
  end
  return true
end

function M.clear(buffer, client_id)
  if client_id then
    invalidate(buffer, client_id)
  else
    local doc = documents[buffer]
    if doc then
      for current in pairs(doc.clients) do
        invalidate(buffer, current)
      end
    end
    documents[buffer] = nil
  end
end

local group = vim.api.nvim_create_augroup("venue-reader.summary", { clear = true })
vim.api.nvim_create_autocmd("LspRequest", {
  group = group,
  callback = function(event)
    local client = vim.lsp.get_client_by_id(event.data.client_id)
    if not managed or not client or not managed(client) then
      return
    end
    if event.data.request.method == "textDocument/codeLens" and options.mode == "codelens" then
      if event.data.request.type == "complete" then
        local _, state = document(event.buf, client.id)
        local captured = generation
        state.configuration = nil
        vim.schedule(function()
          local doc = documents[event.buf]
          if captured == generation and doc and doc.clients[client.id] == state then
            configure_document(client, event.buf, state)
          end
        end)
      end
      return
    end
    if event.data.request.method ~= "textDocument/inlayHint" then
      return
    end
    local doc, state = document(event.buf, client.id)
    local kind = event.data.request.type
    if kind == "pending" then
      if state.query then
        client:cancel_request(state.query)
        state.query = nil
      end
      state.epoch = (state.epoch or 0) + 1
      state.configuration, state.failure = nil, nil
      state.latest = {
        id = event.data.request_id,
        tick = vim.api.nvim_buf_get_changedtick(event.buf),
        uri = vim.uri_from_bufnr(event.buf),
        generation = generation,
      }
    elseif state.latest and state.latest.id == event.data.request_id then
      if kind == "cancel" then
        state.latest = nil
      elseif kind == "complete" then
        local request = state.latest
        vim.schedule(function()
          if state.latest == request then
            state.latest = nil
          end
        end)
      end
    end
    doc.revision = doc.revision + 1
  end,
})
vim.api.nvim_create_autocmd("LspAttach", {
  group = group,
  callback = function(event)
    local client = vim.lsp.get_client_by_id(event.data.client_id)
    if managed and client and managed(client) then
      M.attach(client, event.buf)
    end
  end,
})
vim.api.nvim_create_autocmd("LspDetach", {
  group = group,
  callback = function(event)
    M.clear(event.buf, event.data.client_id)
  end,
})
vim.api.nvim_create_autocmd({ "BufFilePre", "BufWipeout" }, {
  group = group,
  callback = function(event)
    M.clear(event.buf)
  end,
})
vim.api.nvim_set_decoration_provider(namespace, {
  on_win = function(_, _, buffer)
    local doc = documents[buffer]
    if not doc then
      return false
    end
    local enabled = custom() and vim.lsp.inlay_hint.is_enabled({ bufnr = buffer })
    local key = doc.revision
      .. ":"
      .. vim.api.nvim_buf_get_changedtick(buffer)
      .. ":"
      .. tostring(enabled)
    if doc.drawn == key then
      return false
    end
    clear(buffer)
    doc.drawn = key
    if not enabled then
      return false
    end
    for client_id, state in pairs(doc.clients) do
      if valid(state, buffer, client_id) then
        for _, hint in ipairs(state.hints) do
          local chunks = {}
          if hint.paddingLeft then
            table.insert(chunks, { " ", options.highlight })
          end
          if type(hint.label) == "string" then
            table.insert(chunks, { hint.label, options.highlight })
          else
            for _, part in ipairs(hint.label) do
              table.insert(chunks, { part.value, options.highlight })
            end
          end
          if hint.paddingRight then
            table.insert(chunks, { " ", options.highlight })
          end
          local mark = options.mode == "front" and { virt_text = chunks, virt_text_pos = "inline" }
            or { virt_lines = { chunks }, virt_lines_above = true }
          vim.api.nvim_buf_set_extmark(buffer, namespace, hint.position.line, 0, mark)
        end
      end
    end
    return false
  end,
})

return M

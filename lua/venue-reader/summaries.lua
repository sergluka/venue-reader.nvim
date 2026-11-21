local M = {}

local namespace = vim.api.nvim_create_namespace("venue-reader.summary")
local documents = {}
local options = { mode = "off", semantic_highlighting = true }
local Styles = require("venue-reader.summary_styles")
local managed
local generation = 0
local queued = false
local modes = {
  front = { channels = { inlayHints = true, codeLens = false }, draw = "inline" },
  above = { channels = { inlayHints = true, codeLens = false }, draw = "above" },
  hidden = { channels = { inlayHints = true, codeLens = false }, draw = false },
  codelens = { channels = { inlayHints = false, codeLens = true }, draw = false },
  off = { channels = { inlayHints = false, codeLens = false }, draw = false },
}

-- Custom summaries arrive as inlay hints, so that channel flag selects the custom modes.
local function custom()
  return modes[options.mode].channels.inlayHints
end

local function styled(state)
  return options.semantic_highlighting
    and state.configuration.effective["messageSummary.semanticTokens"] ~= false
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
  for key, expected in pairs(modes[options.mode].channels) do
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
  return state.rows
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
          if valid(state, buffer, client_id) and state.rows[0] then
            first_line = true
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
  local mode = type(summary) == "table" and modes[summary.mode]
  assert(mode, "summary.mode: use front, above, hidden, codelens or off")
  assert(summary.highlight == nil, "summary.highlight was removed; use VenueReaderSummary")
  assert(
    type(summary.semantic_highlighting) == "boolean",
    "summary.semantic_highlighting must be boolean"
  )
  local result = vim.deepcopy(settings)
  result.fix = result.fix or {}
  -- The selected mode overrides channel values from vim.lsp.config and live client settings.
  result.fix.messageSummary = vim.tbl_deep_extend("force", result.fix.messageSummary or {}, {
    channels = vim.deepcopy(mode.channels),
    semanticTokens = summary.semantic_highlighting and mode.channels.inlayHints,
  })
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
  state.rows = {}
  local line_count = vim.api.nvim_buf_line_count(ctx.bufnr)
  for _, hint in ipairs(summaries) do
    if
      type(hint.position) == "table"
      and hint.position.character == 0
      and type(hint.position.line) == "number"
      and hint.position.line >= 0
      and hint.position.line < line_count
    then
      state.rows[hint.position.line] = hint
    end
  end
  state.tick, state.uri, state.generation = request.tick, request.uri, generation
  doc.revision = doc.revision + 1
  configure_document(vim.lsp.get_client_by_id(ctx.client_id), ctx.bufnr, state)
  redraw()
end

local function styling(state)
  if not state or not state.configuration or not options.semantic_highlighting or not custom() then
    return nil
  end
  if state.configuration.effective["messageSummary.semanticTokens"] ~= false then
    return nil
  end
  return "Summary semantic metadata is disabled; source: "
    .. vim.inspect((state.configuration.sources or {})["messageSummary.semanticTokens"])
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
    styling = styling(state),
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
  vim.api.nvim_set_hl(0, "VenueReaderSummary", { default = true, link = "Comment" })
  for _, client in ipairs(vim.lsp.get_clients({ name = "venue-reader" })) do
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

function M.current_summary(value)
  value = value or {}
  local format = value.format or "text"
  assert(format == "text" or format == "chunks" or format == "statusline", "Invalid summary format")
  local empty = format == "chunks" and {} or ""
  if not custom() then
    return empty
  end
  local window = value.winid or 0
  if window == 0 then
    window = vim.api.nvim_get_current_win()
  end
  if not vim.api.nvim_win_is_valid(window) then
    return empty
  end
  local buffer = vim.api.nvim_win_get_buf(window)
  local doc = documents[buffer]
  if not doc or not vim.lsp.inlay_hint.is_enabled({ bufnr = buffer }) then
    return empty
  end
  local row = vim.api.nvim_win_get_cursor(window)[1] - 1
  for client_id, state in pairs(doc.clients) do
    if state.rows and state.rows[row] and valid(state, buffer, client_id) then
      local chunks = Styles.chunks(
        state.rows[row],
        vim.lsp.get_client_by_id(client_id),
        styled(state),
        false,
        value.details == false
      )
      if #chunks == 0 then
        return empty
      end
      if format == "chunks" then
        return chunks
      end
      if format == "statusline" then
        return Styles.statusline(chunks)
      end
      local text = {}
      for index, chunk in ipairs(chunks) do
        text[index] = chunk[1]
      end
      return table.concat(text)
    end
  end
  return empty
end

local group = vim.api.nvim_create_augroup("venue-reader.summary", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = function()
    Styles.clear()
    for _, doc in pairs(documents) do
      doc.revision = doc.revision + 1
    end
    redraw()
  end,
})
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
    local draw = modes[options.mode].draw
    local enabled = draw and vim.lsp.inlay_hint.is_enabled({ bufnr = buffer })
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
        local client = vim.lsp.get_client_by_id(client_id)
        local semantic = styled(state)
        for row, hint in pairs(state.rows) do
          local chunks = Styles.chunks(hint, client, semantic, true)
          local mark = draw == "inline" and { virt_text = chunks, virt_text_pos = "inline" }
            or { virt_lines = { chunks }, virt_lines_above = true }
          vim.api.nvim_buf_set_extmark(buffer, namespace, row, 0, mark)
        end
      end
    end
    return false
  end,
})

return M

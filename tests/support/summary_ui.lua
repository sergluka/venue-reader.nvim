local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local Transport = require("tests.support.transport")
local Plugin = require("venue-reader")
local release = require("venue-reader.release")

local equal = MiniTest.expect.equality
local namespace = vim.api.nvim_create_namespace("venue-reader.summary")

local function marks(buffer)
  vim.cmd("redraw!")
  return vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })
end

local function pending(transport, method)
  local found
  for id, request in pairs(transport.pending) do
    if request.method == method and (not found or id > found.id) then
      found = request
    end
  end
  return found
end

local function wait_request(transport, method)
  local request
  Lsp.wait(function()
    request = pending(transport, method)
    return request ~= nil
  end, method)
  return request
end

local function fixture(mode, lines)
  local original_rpc, original_system = vim.lsp.rpc.start, vim.system
  local transports = {}
  MiniTest.finally(function()
    vim.lsp.enable("venue_reader", false)
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
      client:stop(true)
    end
    for _, transport in ipairs(transports) do
      transport:exit(0, 0)
    end
    vim.wait(30)
    rawset(vim.lsp.rpc, "start", original_rpc)
    rawset(vim, "system", original_system)
  end)
  rawset(vim, "system", function(command, options, callback)
    if command[1]:find("summary-test", 1, true) then
      vim.schedule(function()
        options.stdout(nil, "venue-reader " .. release.version .. "\n")
        callback({ code = 0 })
      end)
      return { kill = function() end }
    end
    return original_system(command, options, callback)
  end)
  rawset(vim.lsp.rpc, "start", function(_, dispatchers)
    local transport = Transport.new()
    transports[#transports + 1] = transport
    local rpc = transport.command(dispatchers)
    vim.schedule(function()
      transport:reply(1, {
        capabilities = {
          textDocumentSync = { openClose = true, change = 1 },
          hoverProvider = true,
          inlayHintProvider = true,
          codeLensProvider = {},
          executeCommandProvider = { commands = { "fix.describeOverrides" } },
        },
        serverInfo = { name = "venue-reader", version = release.version },
      })
    end)
    return rpc
  end)
  Plugin.setup({
    server = { cmd = { "summary-test", "--stdio" } },
    summary = { mode = mode or "front" },
  })
  local buffer = Lsp.buffer(lines or { "8=FIX.4.4|35=0|", "8=FIX.4.4|35=1|" })
  vim.api.nvim_set_current_buf(buffer)
  local client
  Lsp.wait(function()
    client = vim.lsp.get_clients({ bufnr = buffer, name = "venue_reader" })[1]
    return client and client.initialized
  end, "summary attachment")
  return { buffer = buffer, client = client, transport = transports[1], transports = transports }
end

local function configuration(context, overrides)
  local request = wait_request(context.transport, "workspace/executeCommand")
  equal(request.params.command, "fix.describeOverrides")
  local effective = {
    ["messageSummary.enabled"] = true,
    ["messageSummary.channels.inlayHints"] = true,
    ["messageSummary.channels.codeLens"] = false,
    ["limits.rangeLines"] = 2000,
    ["limits.codeLensLines"] = 20000,
  }
  context.transport:reply(request.id, {
    effective = vim.tbl_extend("force", effective, overrides or {}),
    sources = {},
    warnings = {},
    dictionaries = {},
  })
  vim.wait(30)
end

local function hints(context, label)
  local opened = assert(context.transport:notification("textDocument/didOpen"))
  local version = opened.textDocument.version
  for _, notification in ipairs(context.transport.notifications) do
    if
      notification.method == "textDocument/didChange"
      and notification.params.textDocument.uri == opened.textDocument.uri
    then
      version = notification.params.textDocument.version
    end
  end
  return {
    {
      position = { line = 0, character = 0 },
      label = { { value = label or "Heartbeat λ" }, { value = " details" } },
      paddingLeft = true,
      paddingRight = true,
      data = {
        kind = "summary",
        uri = opened.textDocument.uri,
        version = version,
      },
    },
    { position = { line = 0, character = 12 }, label = "MsgType", data = { kind = "tag" } },
  }
end

local function reply(context, result)
  local request = wait_request(context.transport, "textDocument/inlayHint")
  equal(request.params.range.start.line, 0)
  equal(request.params.range["end"].line, vim.api.nvim_buf_line_count(context.buffer))
  context.transport:reply(request.id, result or hints(context))
  vim.wait(30)
  return request
end

local function refresh(context)
  vim.lsp.handlers["workspace/inlayHint/refresh"](nil, nil, { client_id = context.client.id })
end

return {
  fixture = fixture,
  reply = reply,
  configuration = configuration,
  marks = marks,
  refresh = refresh,
  hints = hints,
  pending = pending,
  wait_request = wait_request,
}

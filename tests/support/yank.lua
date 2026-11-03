local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local Transport = require("tests.support.transport")
local Commands = require("venue-reader.commands")

local Fixture = {}

function Fixture.new(value)
  value = value or {}
  local transport = Transport.new()
  local buffer = Lsp.buffer(value.lines or { "8=FIX.4.4|35=0|", "8=FIX.4.4|35=1|", "" })
  vim.api.nvim_set_current_buf(buffer)
  local client = Lsp.start({
    name = "yank-controlled",
    cmd = transport.command,
    root_dir = vim.uv.cwd(),
    settings = { fix = {} },
    before_init = Commands.before_init,
    handlers = { ["workspace/configuration"] = Commands.configuration },
  }, buffer)
  transport:reply(1, {
    capabilities = {
      textDocumentSync = { openClose = true, change = 1 },
      positionEncoding = value.encoding or "utf-16",
      executeCommandProvider = { commands = { "fix.decode", "fix.describeOverrides" } },
    },
  })
  Lsp.ready(client, buffer)
  Commands.setup({ timeout_ms = value.timeout_ms or 1000 }, function(_, _, callback)
    callback(nil, client)
  end, function(candidate)
    return candidate.id == client.id
  end)
  transport.dispatchers.server_request(
    "workspace/configuration",
    { items = { { section = "fix" } } }
  )
  vim.wait(5)
  MiniTest.finally(function()
    Commands.closed(client.id)
  end)
  return { transport = transport, buffer = buffer, client = client }
end

function Fixture.pending(context, command)
  local found
  for _, request in pairs(context.transport.pending) do
    if
      request.method == "workspace/executeCommand"
      and request.params.command == command
      and (not found or request.id > found.id)
    then
      found = request
    end
  end
  return found
end

function Fixture.request(context, command)
  local request
  Lsp.wait(function()
    request = Fixture.pending(context, command or "fix.decode")
    return request ~= nil
  end, command or "fix.decode")
  return request
end

function Fixture.result(context, request, texts)
  texts = texts or { [0] = "decoded" }
  local version =
    assert(context.transport:notification("textDocument/didOpen")).textDocument.version
  for _, notification in ipairs(context.transport.notifications) do
    if notification.method == "textDocument/didChange" then
      version = notification.params.textDocument.version
    end
  end
  local result = {
    textDocument = { uri = vim.uri_from_bufnr(context.buffer), version = version },
    results = {},
  }
  local last_line = vim.api.nvim_buf_line_count(context.buffer) - 1
  for index, range in ipairs(request.params.arguments[1].ranges) do
    local rows = {}
    for line = range.start.line, math.min(range["end"].line, last_line) do
      rows[#rows + 1] = { line = line, text = texts[line] or "" }
    end
    result.results[index] = { rangeIndex = index - 1, lines = rows }
  end
  return result
end

function Fixture.reply(context, texts, mutate)
  local request = Fixture.request(context)
  local result = Fixture.result(context, request, texts)
  if mutate then
    mutate(result)
  end
  context.transport:reply(request.id, result)
  vim.wait(20)
  return request
end

return Fixture

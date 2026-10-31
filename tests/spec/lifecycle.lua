local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local Plugin = require("venue-reader")
local tests = MiniTest.new_set()
local equal = MiniTest.expect.equality

local function setup()
  Plugin.setup({ server = { cmd = { assert(vim.env.VENUE_READER_TEST_SERVER), "--stdio" } } })
  MiniTest.finally(function()
    vim.lsp.enable("venue_reader", false)
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
      client:stop(true)
    end
    Lsp.wait(function()
      return #vim.lsp.get_clients({ name = "venue_reader" }) == 0
    end, "cleanup")
  end)
end

local function client(buffer)
  local result
  Lsp.wait(function()
    result = vim.lsp.get_clients({ bufnr = buffer, name = "venue_reader" })[1]
    return result and result.initialized
  end, "managed attachment")
  return result
end

tests["attach share rename stop and restart a real session"] = function()
  setup()
  local first = Lsp.buffer()
  local active = client(first)
  local second = Lsp.buffer()
  equal(client(second).id, active.id)
  equal(active.server_capabilities.inlayHintProvider, nil)
  assert(not vim.lsp.semantic_tokens.is_enabled({ client_id = active.id }))
  local old = vim.uri_from_bufnr(first)
  vim.api.nvim_buf_call(first, function()
    vim.cmd("file renamed.fix")
  end)
  equal(client(first).id, active.id)
  local uri = vim.uri_from_bufnr(first)
  assert(uri ~= old)
  Lsp.wait(function()
    local response = active:request_sync(
      "workspace/executeCommand",
      { command = "fix.describeOverrides", arguments = { uri } },
      500,
      first
    )
    return response and not response.err
  end, "configuration after rename")
  local hover = Lsp.request(active, "textDocument/hover", {
    textDocument = { uri = uri },
    position = { line = 0, character = 12 },
  }, first)
  assert(hover and hover.contents.value:find("Heartbeat", 1, true))
  Plugin.setup({
    server = { cmd = { vim.env.VENUE_READER_TEST_SERVER, "--stdio" } },
    settings = { fix = { limits = { rangeLines = 123 } } },
  })
  equal(active.settings.fix.limits.rangeLines, 123)
  vim.api.nvim_buf_call(first, function()
    vim.cmd("saveas saved.fix")
  end)
  equal(client(first).id, active.id)
  Plugin.stop(first)
  Lsp.wait(function()
    return vim.lsp.get_client_by_id(active.id) == nil
  end, "stop")
  local third = Lsp.buffer()
  vim.wait(50)
  equal(#vim.lsp.get_clients({ bufnr = third, name = "venue_reader" }), 0)
  Plugin.restart(first)
  assert(client(first).id ~= active.id)
end

tests["unnamed FIX buffer attaches only after naming"] = function()
  setup()
  local buffer = vim.api.nvim_create_buf(true, false)
  MiniTest.finally(function()
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)
  vim.api.nvim_set_option_value("filetype", "fix", { buf = buffer })
  equal(#vim.lsp.get_clients({ bufnr = buffer, name = "venue_reader" }), 0)
  vim.api.nvim_buf_call(buffer, function()
    vim.cmd("file /tmp/venue-unnamed/input.fix")
  end)
  client(buffer)
end

tests["rename closes old URI before opening new and preserves unrelated clients"] = function()
  local Transport = require("tests.support.transport")
  local transport = Transport.new()
  local original = vim.lsp.rpc.start
  local spawns = 0
  MiniTest.finally(function()
    rawset(vim.lsp.rpc, "start", original)
  end)
  rawset(vim.lsp.rpc, "start", function(_, dispatchers)
    spawns = spawns + 1
    return transport.command(dispatchers)
  end)
  setup()
  local buffer = Lsp.buffer()
  vim.api.nvim_buf_call(buffer, function()
    vim.cmd("file /tmp/venue-protocol/input.fix")
  end)
  Lsp.wait(function()
    return transport.pending[1] ~= nil
  end, "initialize request")
  local second = Lsp.buffer()
  vim.api.nvim_buf_call(second, function()
    vim.cmd("file /tmp/venue-protocol/second.fix")
  end)
  vim.wait(30)
  equal(spawns, 1)
  transport:reply(1, {
    capabilities = {
      textDocumentSync = { openClose = true, change = 1 },
      hoverProvider = true,
      inlayHintProvider = true,
      semanticTokensProvider = {
        legend = { tokenTypes = { "type" }, tokenModifiers = {} },
        range = true,
        full = true,
      },
      codeLensProvider = {},
    },
  })
  local managed = client(buffer)
  local unrelated_transport = Transport.new()
  local unrelated = Lsp.start({ name = "unrelated", cmd = unrelated_transport.command }, buffer)
  unrelated_transport:initialize()
  Lsp.ready(unrelated, buffer)
  local old = vim.uri_from_bufnr(buffer)
  vim.api.nvim_buf_call(buffer, function()
    vim.cmd("file /tmp/venue-protocol/renamed.fix")
  end)
  client(buffer)
  local close = transport:notification("textDocument/didClose")
  equal(close.textDocument.uri, old)
  local opened = {}
  for _, event in ipairs(transport.notifications) do
    if event.method == "textDocument/didOpen" then
      table.insert(opened, event.params.textDocument.uri)
    end
  end
  equal(opened[3], vim.uri_from_bufnr(buffer))
  local initial = { opened[1], opened[2] }
  table.sort(initial)
  local expected = { old, vim.uri_from_bufnr(second) }
  table.sort(expected)
  equal(initial, expected)
  local close_index
  for index, event in ipairs(transport.notifications) do
    if event.method == "textDocument/didClose" then
      close_index = index
    end
    if
      event.method == "textDocument/didOpen"
      and event.params.textDocument.uri == vim.uri_from_bufnr(buffer)
    then
      assert(close_index and close_index < index)
    end
  end
  assert(vim.lsp.buf_is_attached(buffer, unrelated.id))
  for _, event in ipairs(transport.events) do
    assert(
      not event:match("semanticTokens")
        and event ~= "textDocument/inlayHint"
        and event ~= "textDocument/codeLens",
      event
    )
  end
  Plugin.stop(buffer)
  Lsp.wait(function()
    return vim.lsp.get_client_by_id(managed.id) == nil
  end, "fake stop")
end

tests["stop during acquisition prevents attachment and other roots remain usable"] = function()
  setup()
  local buffer = Lsp.buffer()
  vim.api.nvim_buf_call(buffer, function()
    vim.cmd("file /tmp/venue-pending/input.fix")
  end)
  Plugin.stop(buffer)
  vim.wait(80)
  equal(#vim.lsp.get_clients({ bufnr = buffer, name = "venue_reader" }), 0)
  local other = Lsp.buffer()
  vim.api.nvim_buf_call(other, function()
    vim.cmd("file /tmp/venue-other/input.fix")
  end)
  client(other)
  Plugin.start(buffer)
  client(buffer)
end

local function named_buffer(directory)
  local buffer = Lsp.buffer()
  vim.api.nvim_buf_call(buffer, function()
    vim.cmd("file " .. vim.fn.fnameescape(directory .. "/input-" .. buffer .. ".fix"))
  end)
  return buffer
end

tests["repeated restart keeps new buffers and drops removed settings"] = function()
  setup()
  local directory = vim.fn.tempname()
  local first = named_buffer(directory)
  local initial = client(first)
  Plugin.restart(first)
  Lsp.wait(function()
    local current = vim.lsp.get_clients({ bufnr = first, name = "venue_reader" })[1]
    return current and current.initialized and current.id ~= initial.id
  end, "first replacement")
  local second = named_buffer(directory)
  local replacement = client(second)
  equal(client(first).id, replacement.id)
  Plugin.setup({
    server = { cmd = { vim.env.VENUE_READER_TEST_SERVER, "--stdio" } },
    settings = { fix = { limits = { rangeLines = 111 } } },
  })
  equal(replacement.settings.fix.limits.rangeLines, 111)
  Plugin.setup({
    server = { cmd = { vim.env.VENUE_READER_TEST_SERVER, "--stdio" } },
    settings = {},
  })
  equal(vim.lsp.config.venue_reader.settings.fix.limits, nil)
  equal(replacement.settings.fix.limits, nil)
  Plugin.restart(first)
  Lsp.wait(function()
    local candidates = vim.lsp.get_clients({ bufnr = first, name = "venue_reader" })
    return candidates[1] and candidates[1].initialized and candidates[1].id ~= replacement.id
  end, "second replacement")
  equal(client(first).id, client(second).id)
  equal(client(second).settings.fix.limits, nil)
end

local function controlled()
  local Transport = require("tests.support.transport")
  local original = vim.lsp.rpc.start
  local transports = {}
  MiniTest.finally(function()
    rawset(vim.lsp.rpc, "start", original)
  end)
  rawset(vim.lsp.rpc, "start", function(_, dispatchers)
    local transport = Transport.new()
    transports[#transports + 1] = transport
    return transport.command(dispatchers)
  end)
  setup()
  return transports
end

local function initialize(transports, index)
  Lsp.wait(function()
    return transports[index] and transports[index].pending[1]
  end, "initialize pending")
  transports[index]:initialize()
end

tests["crash preserves every buffer for explicit recovery"] = function()
  local transports = controlled()
  local directory = vim.fn.tempname()
  local first = named_buffer(directory)
  initialize(transports, 1)
  local initial = client(first)
  local second = named_buffer(directory)
  equal(client(second).id, initial.id)
  transports[1]:exit(7, 0)
  Lsp.wait(function()
    return vim.lsp.get_client_by_id(initial.id) == nil
  end, "crash cleanup")
  assert(Plugin.status(first).session.suppressed)
  assert(Plugin.status(first).session.failure:find("7", 1, true))
  Plugin.restart(first)
  initialize(transports, 2)
  equal(client(first).id, client(second).id)
end

tests["restart replaces an initializing transport"] = function()
  local transports = controlled()
  local buffer = named_buffer(vim.fn.tempname())
  Lsp.wait(function()
    return transports[1] and transports[1].pending[1]
  end, "held initialize")
  Plugin.restart(buffer)
  initialize(transports, 2)
  client(buffer)
  assert(transports[1].closing)
end

tests["external clean stop suppresses restart without an error notification"] = function()
  setup()
  local buffer = named_buffer(vim.fn.tempname())
  local active = client(buffer)
  local original = vim.notify
  local errors = {}
  MiniTest.finally(function()
    rawset(vim, "notify", original)
  end)
  rawset(vim, "notify", function(message, level)
    if level == vim.log.levels.ERROR then
      table.insert(errors, message)
    end
  end)
  active:stop(true)
  Lsp.wait(function()
    return vim.lsp.get_client_by_id(active.id) == nil
  end, "external stop")
  equal(errors, {})
  assert(Plugin.status(buffer).session.suppressed)
  equal(Plugin.status(buffer).session.failure, nil)
  Plugin.restart(buffer)
  client(buffer)
end

tests["health reports a ready server and a failed discovery"] = function()
  setup()
  local buffer = named_buffer(vim.fn.tempname())
  client(buffer)
  local reports = {}
  for _, name in ipairs({ "start", "ok", "info", "error" }) do
    local previous = vim.health[name]
    MiniTest.finally(function()
      rawset(vim.health, name, previous)
    end)
    rawset(vim.health, name, function(message)
      table.insert(reports, { name, message })
    end)
  end
  require("venue-reader.health").check()
  assert(vim.iter(reports):any(function(item)
    return item[1] == "ok" and item[2]:find("Compatible server", 1, true)
  end))
  Plugin.setup({ server = { cmd = { "/missing/venue-review-server", "--stdio" } } })
  local missing = named_buffer(vim.fn.tempname())
  vim.api.nvim_set_current_buf(missing)
  Lsp.wait(function()
    return Plugin.status(missing).acquisition.error
  end, "failed discovery")
  reports = {}
  require("venue-reader.health").check()
  assert(vim.iter(reports):any(function(item)
    return item[1] == "error"
  end))
end

tests["restart during exit cleanup does not hang"] = function()
  local transports = controlled()
  local buffer = named_buffer(vim.fn.tempname())
  initialize(transports, 1)
  client(buffer)
  transports[1]:exit(7, 0)
  vim.schedule(function()
    Plugin.restart(buffer)
  end)
  initialize(transports, 2)
  client(buffer)
end

tests["stop after root resolution cancels scheduled spawn without warnings"] = function()
  local transports = controlled()
  local original = vim.notify
  local warnings = {}
  MiniTest.finally(function()
    rawset(vim, "notify", original)
  end)
  rawset(vim, "notify", function(message, level)
    if level and level >= vim.log.levels.WARN then
      table.insert(warnings, message)
    end
  end)
  local buffer = vim.api.nvim_create_buf(true, false)
  MiniTest.finally(function()
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)
  vim.api.nvim_buf_set_name(buffer, vim.fn.tempname() .. "/input.fix")
  vim.api.nvim_set_option_value("filetype", "fix", { buf = buffer })
  local resolved = false
  local config = vim.lsp.config.venue_reader
  config.root_dir(buffer, function(directory)
    resolved = true
    Plugin.stop(buffer)
    local pending = vim.deepcopy(config)
    pending.root_dir = directory
    vim.lsp.start(pending, { bufnr = buffer })
  end)
  Lsp.wait(function()
    return resolved
  end, "resolved then stopped")
  vim.wait(50)
  equal(#transports, 0)
  equal(warnings, {})
  equal(#vim.lsp.get_clients({ bufnr = buffer, name = "venue_reader" }), 0)
end
return tests

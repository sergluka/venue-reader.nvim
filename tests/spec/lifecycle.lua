local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local Plugin = require("venue-reader")

local tests = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.lsp.config.venue_reader = {} -- luacheck: ignore 122
    end,
  },
})
local equal = MiniTest.expect.equality
local ready_documents = {}

local function configure(value)
  local handler = function(err, result, ctx)
    if not err and result then
      ready_documents[ctx.client_id .. ":" .. result.uri] = true
    end
    return vim.lsp.handlers["textDocument/publishDiagnostics"](err, result, ctx)
  end
  vim.lsp.config("venue_reader", { handlers = { ["textDocument/publishDiagnostics"] = handler } })
  Plugin.setup(value)
end

local function setup()
  configure({
    summary = { mode = "off" },
    server = { cmd = { assert(vim.env.VENUE_READER_TEST_SERVER), "--stdio" } },
  })
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
  vim.api.nvim_set_current_buf(buffer)
  local result
  Lsp.wait(function()
    result = vim.lsp.get_clients({ bufnr = buffer, name = "venue_reader" })[1]
    if not result or not result.initialized then
      return false
    end
    return true
  end, "managed attachment")
  return result
end

local function named_buffer(directory)
  local buffer = vim.api.nvim_create_buf(true, false)
  MiniTest.finally(function()
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)
  vim.api.nvim_buf_set_name(buffer, directory .. "/input-" .. buffer .. ".fix")
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "8=FIX.4.4|35=0|" })
  vim.api.nvim_set_option_value("filetype", "fix", { buf = buffer })
  return buffer
end

tests["attach share rename stop and restart a real session"] = function()
  setup()
  local first = Lsp.buffer()
  local active = client(first)
  Lsp.wait(function()
    return ready_documents[active.id .. ":" .. vim.uri_from_bufnr(first)]
  end, "initial document configuration")
  local second = Lsp.buffer()
  equal(client(second).id, active.id)
  Lsp.wait(function()
    return ready_documents[active.id .. ":" .. vim.uri_from_bufnr(second)]
  end, "second document configuration")
  assert(active.server_capabilities.inlayHintProvider)
  assert(vim.lsp.semantic_tokens.is_enabled({ client_id = active.id }))
  local old = vim.uri_from_bufnr(first)
  vim.api.nvim_buf_call(first, function()
    vim.cmd("file renamed.fix")
  end)
  equal(client(first).id, active.id)
  local uri = vim.uri_from_bufnr(first)
  assert(uri ~= old)
  Lsp.wait(function()
    return ready_documents[active.id .. ":" .. uri]
  end, "document diagnostics after rename")
  local hover = Lsp.request(active, "textDocument/hover", {
    textDocument = { uri = uri },
    position = { line = 0, character = 12 },
  }, first)
  assert(hover and hover.contents.value:find("Heartbeat", 1, true))
  active.settings.fix.limits = { rangeLines = 123 }
  active:notify("workspace/didChangeConfiguration", { settings = active.settings })
  Plugin.summary("off")
  equal(active.settings.fix.limits.rangeLines, 123)
  local before_save = vim.api.nvim_list_bufs()
  vim.api.nvim_buf_call(first, function()
    vim.cmd("saveas saved.fix")
  end)
  for _, created in ipairs(vim.api.nvim_list_bufs()) do
    if not vim.tbl_contains(before_save, created) then
      MiniTest.finally(function()
        if vim.api.nvim_buf_is_valid(created) then
          vim.api.nvim_buf_delete(created, { force = true })
        end
      end)
    end
  end
  equal(client(first).id, active.id)
  Plugin.stop(first)
  Lsp.wait(function()
    return vim.lsp.get_client_by_id(active.id) == nil
  end, "stop")
  local third = Lsp.buffer()
  client(third)
  Plugin.start()
  client(first)
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
    vim.cmd.file({ args = { vim.fn.tempname() .. ".fix" } })
  end)
  client(buffer)
end

tests["rename closes old URI before opening new and preserves unrelated clients"] = function()
  local Transport = require("tests.support.transport")
  local transport = Transport.new()
  MiniTest.finally(function()
    if transport.dispatchers then
      transport:exit(0, 0)
    end
  end)
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
  local directory = vim.fs.normalize(vim.fn.tempname())
  local buffer = named_buffer(directory)
  Lsp.wait(function()
    return transport.pending[1] ~= nil
  end, "initialize request")
  local second = named_buffer(directory)
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
    vim.cmd.file({ args = { directory .. "/renamed.fix" } })
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
  assert(managed.server_capabilities.inlayHintProvider)
  assert(managed.server_capabilities.semanticTokensProvider)
  assert(managed.server_capabilities.codeLensProvider)
  vim.lsp.inlay_hint.enable(true, { bufnr = buffer })
  Lsp.wait(function()
    return vim.tbl_contains(transport.events, "textDocument/inlayHint")
  end, "native inlay request")
  assert(vim.tbl_contains(transport.events, "textDocument/semanticTokens/full"))
  Plugin.stop(buffer)
  Lsp.wait(function()
    return vim.lsp.get_client_by_id(managed.id) == nil
  end, "fake stop")
end

tests["native disable during acquisition prevents attachment"] = function()
  setup()
  local buffer = Lsp.buffer()
  vim.api.nvim_buf_call(buffer, function()
    vim.cmd.file({ args = { vim.fn.tempname() .. ".fix" } })
  end)
  vim.cmd("lsp disable venue_reader")
  vim.wait(80)
  equal(#vim.lsp.get_clients({ bufnr = buffer, name = "venue_reader" }), 0)
  local other = Lsp.buffer()
  vim.api.nvim_buf_call(other, function()
    vim.cmd.file({ args = { vim.fn.tempname() .. ".fix" } })
  end)
  equal(#vim.lsp.get_clients({ bufnr = other, name = "venue_reader" }), 0)
  Plugin.start(buffer)
  client(buffer)
  client(other)
end

tests["native restart adopts registered settings instead of live changes"] = function()
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
  vim.lsp.config("venue_reader", { settings = { fix = { limits = { rangeLines = 111 } } } })
  equal(replacement.settings.fix.limits, nil)
  replacement.settings.fix.limits = { rangeLines = 19 }
  replacement:notify("workspace/didChangeConfiguration", { settings = replacement.settings })
  Plugin.restart(first)
  Lsp.wait(function()
    local candidates = vim.lsp.get_clients({ bufnr = first, name = "venue_reader" })
    return candidates[1] and candidates[1].initialized and candidates[1].id ~= replacement.id
  end, "second replacement")
  equal(client(first).id, client(second).id)
  equal(client(second).settings.fix.limits.rangeLines, 111)
end

local function controlled()
  local Transport = require("tests.support.transport")
  local original = vim.lsp.rpc.start
  local transports = {}
  MiniTest.finally(function()
    for _, transport in ipairs(transports) do
      transport:exit(0, 0)
    end
  end)
  MiniTest.finally(function()
    rawset(vim.lsp.rpc, "start", original)
  end)
  rawset(vim.lsp.rpc, "start", function(_, dispatchers)
    local transport = Transport.new()
    transports[#transports + 1] = transport
    local rpc = transport.command(dispatchers)
    vim.schedule(function()
      local request = transport.pending[1]
      if request then
        transport.root = request.params.rootUri
        transport:initialize()
      end
    end)
    return rpc
  end)
  setup()
  return transports
end

tests["native enable reattaches buffers after a crash"] = function()
  local transports = controlled()
  local directory = vim.fn.tempname()
  local first = named_buffer(directory)
  local initial = client(first)
  local second = named_buffer(directory)
  equal(client(second).id, initial.id)
  for _, transport in ipairs(transports) do
    if transport.root == vim.uri_from_fname(directory) then
      transport:exit(7, 0)
    end
  end
  Lsp.wait(function()
    return vim.lsp.get_client_by_id(initial.id) == nil
  end, "crash cleanup")
  equal(#vim.lsp.get_clients({ bufnr = first, name = "venue_reader" }), 0)
  vim.cmd("lsp enable venue_reader")
  equal(client(first).id, client(second).id)
end

tests["native stop and enable work without plugin suppression"] = function()
  setup()
  local buffer = named_buffer(vim.fn.tempname())
  local active = client(buffer)
  Lsp.wait(function()
    return ready_documents[active.id .. ":" .. vim.uri_from_bufnr(buffer)]
  end, "configuration before stop")
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
  vim.cmd("lsp stop venue_reader")
  Lsp.wait(function()
    return vim.lsp.get_client_by_id(active.id) == nil
  end, "external stop")
  equal(errors, {})
  equal(Plugin.status(buffer).session, nil)
  vim.cmd("lsp enable venue_reader")
  client(buffer)
end

tests["health reports a ready server and a failed discovery"] = function()
  setup()
  local buffer = named_buffer(vim.fn.tempname())
  client(buffer)
  local reports = {}
  for _, name in ipairs({ "start", "ok", "info", "error", "warn" }) do
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
  configure({
    summary = { mode = "off" },
    server = { cmd = { "/missing/venue-review-server", "--stdio" } },
  })
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

tests["native restart retains buffers and leaves unrelated clients alone"] = function()
  setup()
  local directory = vim.fn.tempname()
  local first = named_buffer(directory)
  local old = client(first)
  local second = named_buffer(directory)
  equal(client(second).id, old.id)
  local Transport = require("tests.support.transport")
  local foreign = Transport.new()
  local unrelated = Lsp.start({ name = "unrelated", cmd = foreign.command }, first)
  foreign:initialize()
  Lsp.ready(unrelated, first)
  vim.cmd("lsp restart venue_reader")
  Lsp.wait(function()
    local current = vim.lsp.get_clients({ bufnr = first, name = "venue_reader" })[1]
    return current and current.initialized and current.id ~= old.id
  end, "native replacement")
  equal(client(first).id, client(second).id)
  assert(vim.lsp.buf_is_attached(first, unrelated.id))
end

tests["cold initialization mode changes preserve native settings"] = function()
  local Transport = require("tests.support.transport")
  local transport = Transport.new()
  local original = vim.lsp.rpc.start
  rawset(vim.lsp.rpc, "start", function(_, dispatchers)
    return transport.command(dispatchers)
  end)
  MiniTest.finally(function()
    rawset(vim.lsp.rpc, "start", original)
    if transport.dispatchers then
      transport:exit(0, 0)
    end
  end)
  vim.lsp.config("venue_reader", { settings = { fix = { limits = { rangeLines = 19 } } } })
  setup()
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buffer)
  MiniTest.finally(function()
    vim.api.nvim_buf_delete(buffer, { force = true })
  end)
  Plugin.tag(35)
  Lsp.wait(function()
    return transport.pending[1] ~= nil
  end, "cold initialize")
  Plugin.summary("codelens")
  transport:initialize()
  local active
  Lsp.wait(function()
    active = vim.lsp.get_clients({ name = "venue_reader" })[1]
    return active ~= nil
  end, "cold client initialization")
  equal(active.settings.fix.limits.rangeLines, 19)
  equal(active.settings.fix.messageSummary.channels, { inlayHints = false, codeLens = true })
  equal(active.config.settings.fix.limits.rangeLines, 19)
  local response = transport.dispatchers.server_request("workspace/configuration", {
    items = { { section = "fix" } },
  })
  equal(response, { active.settings.fix })
end

return tests

local MiniTest = require("mini.test")
local Commands = require("venue-reader.commands")
local Lsp = require("tests.support.lsp")
local Transport = require("tests.support.transport")

local equal = MiniTest.expect.equality
local tests = MiniTest.new_set()
local advertised = {
  "fix.decode",
  "fix.describeTag",
  "fix.describeOverrides",
  "fix.listDictionaries",
  "fix.useDictionary",
}

local function setup(options)
  options = options or {}
  local transport = Transport.new()
  local buffer = Lsp.buffer()
  vim.api.nvim_set_current_buf(buffer)
  local notifications = {}
  local original_notify = vim.notify
  rawset(vim, "notify", function(message)
    table.insert(notifications, message)
  end)
  MiniTest.finally(function()
    rawset(vim, "notify", original_notify)
  end)
  local selected
  local guard = true
  local function configure()
    Commands.setup({ timeout_ms = options.timeout_ms or 1000 }, function(_, _, callback)
      callback(nil, selected, function()
        return guard
      end)
    end, function(client)
      return client.config.name == "commands-test"
    end)
  end
  configure()
  local client = Lsp.start({
    name = "commands-test",
    cmd = transport.command,
    root_dir = vim.uv.cwd(),
    settings = { fix = { limits = { rangeLines = 17 } } },
    before_init = Commands.before_init,
    handlers = { ["workspace/configuration"] = Commands.configuration },
    on_exit = function(_, _, client_id)
      Commands.closed(client_id)
    end,
  }, buffer)
  selected = client
  MiniTest.finally(function()
    Commands.closed(client.id)
  end)
  local initialized = false
  local function initialize()
    transport:reply(1, {
      capabilities = {
        textDocumentSync = { openClose = true, change = 1 },
        executeCommandProvider = { commands = options.commands or advertised },
      },
    })
    Lsp.ready(client, buffer)
    initialized = true
  end
  local function pull(items)
    return transport.dispatchers.server_request("workspace/configuration", {
      items = items or { { section = "fix" } },
    })
  end
  local function request()
    local found
    Lsp.wait(function()
      for _, pending in pairs(transport.pending) do
        if pending.method == "workspace/executeCommand" then
          found = pending
          return true
        end
      end
    end, "command request")
    return found
  end
  if not options.cold then
    initialize()
  end
  if not options.no_pull and initialized then
    pull()
    vim.wait(5, function()
      return false
    end)
  end
  return {
    transport = transport,
    client = client,
    buffer = buffer,
    pull = pull,
    request = request,
    initialize = initialize,
    notifications = notifications,
    configure = configure,
    invalidate = function()
      guard = false
    end,
  }
end

local function preview()
  local previews = {}
  local original = vim.lsp.util.open_floating_preview
  rawset(vim.lsp.util, "open_floating_preview", function(lines, filetype)
    table.insert(previews, { lines = lines, filetype = filetype })
  end)
  MiniTest.finally(function()
    rawset(vim.lsp.util, "open_floating_preview", original)
  end)
  return previews
end

tests["initial options and native configuration result stay identical"] = function()
  local fixture = setup({ no_pull = true })
  local initial = fixture.transport.pending[1]
  equal(initial, nil)
  equal(fixture.client.config.venue_reader_initial_settings, fixture.client.settings)
  local result, err = fixture.pull({ { section = "fix" }, { section = "missing" } })
  equal(result, { fixture.client.settings.fix, vim.NIL })
  equal(err, nil)
end

tests["cold command waits for first global configuration response"] = function()
  local fixture = setup({ cold = true })
  local initialize_request = fixture.transport.pending[1]
  equal(initialize_request.params.initializationOptions, fixture.client.settings)
  Commands.tag("35", "D")
  fixture.initialize()
  equal(fixture.transport.next_id, 1)
  fixture.pull({ { section = "fix", scopeUri = vim.uri_from_bufnr(fixture.buffer) } })
  vim.wait(5, function()
    return false
  end)
  equal(fixture.transport.next_id, 1)
  local result = fixture.pull()
  equal(result, { fixture.client.settings.fix })
  equal(fixture.transport.next_id, 1)
  local pending = fixture.request()
  equal(pending.params, { command = "fix.describeTag", arguments = { 35, "D" } })
end

tests["tag validates u32 and shows server Markdown with native float"] = function()
  local fixture = setup()
  local previews = preview()
  for _, invalid in ipairs({ "0", "-1", "1.0", "4294967296", "1e2", "", 1.5 }) do
    Commands.tag(invalid)
  end
  equal(#fixture.notifications, 7)
  equal(fixture.transport.next_id, 1)
  Commands.tag("4294967295", "")
  local pending = fixture.request()
  equal(pending.params.arguments, { 4294967295, "" })
  fixture.transport:reply(pending.id, "# Public reference\nDescription")
  Lsp.wait(function()
    return #previews == 1
  end, "tag preview")
  equal(previews[1], { lines = { "# Public reference", "Description" }, filetype = "markdown" })
end

tests["missing advertised command reports capability without sending"] = function()
  local fixture = setup({ commands = {} })
  Commands.tag("35")
  equal(fixture.transport.next_id, 1)
  equal(#fixture.notifications, 1)
  assert(fixture.notifications[1]:find("does not advertise fix.describeTag", 1, true))
end

tests["timeout cancels native request and ignores late result"] = function()
  local fixture = setup({ timeout_ms = 20 })
  local previews = preview()
  Commands.tag("35")
  local pending = fixture.request()
  Lsp.wait(function()
    return #fixture.notifications > 0
  end, "timeout notification")
  equal(fixture.transport:notification("$/cancelRequest"), { id = pending.id })
  fixture.transport:reply(pending.id, "late")
  vim.wait(10, function()
    return false
  end)
  equal(#previews, 0)
end

tests["bootstrap timeout does not dispatch a late command"] = function()
  local fixture = setup({ timeout_ms = 20, no_pull = true })
  Commands.tag("35")
  Lsp.wait(function()
    return #fixture.notifications > 0
  end, "bootstrap timeout")
  fixture.pull()
  vim.wait(10, function()
    return false
  end)
  equal(fixture.transport.next_id, 1)
end

tests["setup cancels operations and discards bootstrap continuations"] = function()
  local fixture = setup({ no_pull = true })
  Commands.tag("35")
  fixture.configure()
  fixture.pull()
  vim.wait(10, function()
    return false
  end)
  equal(fixture.transport.next_id, 1)
end

tests["changed initial settings never dispatch pending command"] = function()
  local fixture = setup({ no_pull = true })
  Commands.tag("35")
  fixture.client.settings.fix.limits.rangeLines = 18
  fixture.pull()
  vim.wait(10, function()
    return false
  end)
  equal(fixture.transport.next_id, 1)
end

tests["context guard invalidates document-free pending work"] = function()
  local fixture = setup({ no_pull = true })
  Commands.tag("35")
  fixture.invalidate()
  fixture.pull()
  vim.wait(10, function()
    return false
  end)
  equal(fixture.transport.next_id, 1)
end

tests["server errors are shown once without retry"] = function()
  local fixture = setup()
  Commands.tag("35")
  local pending = fixture.request()
  fixture.transport:reply(pending.id, nil, { code = -32002, message = "configuration not ready" })
  Lsp.wait(function()
    return #fixture.notifications > 0
  end, "native error")
  equal(fixture.notifications, { "venue-reader: configuration not ready" })
  equal(fixture.transport.next_id, pending.id)
end

tests["settings uses captured document and one committed snapshot float"] = function()
  local fixture = setup()
  local previews = preview()
  Commands.settings()
  local pending = fixture.request()
  equal(pending.params.arguments, { vim.uri_from_bufnr(fixture.buffer) })
  local snapshot = { effective = { ["limits.rangeLines"] = 17 }, sources = {}, warnings = {} }
  fixture.transport:reply(pending.id, snapshot)
  Lsp.wait(function()
    return #previews == 1
  end, "settings preview")
  equal(table.concat(previews[1].lines, "\n"), vim.inspect(snapshot))
  equal(previews[1].filetype, "lua")
end

tests["document edit cancels settings result"] = function()
  local fixture = setup()
  local previews = preview()
  Commands.settings()
  local pending = fixture.request()
  vim.api.nvim_buf_set_lines(fixture.buffer, 0, 1, false, { "8=FIX.4.4|35=D|" })
  fixture.transport:reply(pending.id, { effective = {} })
  vim.wait(10, function()
    return false
  end)
  equal(#previews, 0)
end

tests["detach cancels outstanding native document request"] = function()
  local fixture = setup()
  Commands.settings()
  local pending = fixture.request()
  vim.lsp.buf_detach_client(fixture.buffer, fixture.client.id)
  Lsp.wait(function()
    return fixture.transport:notification("$/cancelRequest") ~= nil
  end, "detach cancellation")
  equal(fixture.transport:notification("$/cancelRequest"), { id = pending.id })
end

tests["dictionary picker uses exact labels and same captured client"] = function()
  local fixture = setup({ timeout_ms = 30 })
  local original = vim.ui.select
  local choose
  rawset(vim.ui, "select", function(items, options, callback)
    equal(options.format_item(items[1]), "Exact server label")
    choose = function()
      callback(items[1])
    end
  end)
  MiniTest.finally(function()
    rawset(vim.ui, "select", original)
  end)
  Commands.dictionary()
  local pending = fixture.request()
  equal(pending.params.command, "fix.listDictionaries")
  fixture.transport:reply(pending.id, {
    dictionaries = { { name = "identity", label = "Exact server label" } },
  })
  Lsp.wait(function()
    return choose ~= nil
  end, "dictionary picker")
  vim.wait(50, function()
    return false
  end)
  equal(fixture.notifications, {})
  choose()
  pending = fixture.request()
  equal(pending.params, { command = "fix.useDictionary", arguments = { "identity" } })
  fixture.transport:reply(pending.id, { name = "identity" })
  Lsp.wait(function()
    return #fixture.notifications > 0
  end, "dictionary success")
  assert(fixture.notifications[1]:find("project and modeline", 1, true))
end

tests["stale or canceled dictionary picker sends nothing"] = function()
  local fixture = setup()
  local original = vim.ui.select
  local choose
  rawset(vim.ui, "select", function(items, _, callback)
    choose = function(value)
      callback(value and items[1] or nil)
    end
  end)
  MiniTest.finally(function()
    rawset(vim.ui, "select", original)
  end)
  Commands.dictionary()
  local pending = fixture.request()
  fixture.transport:reply(pending.id, { dictionaries = { { name = "x", label = "X" } } })
  Lsp.wait(function()
    return choose ~= nil
  end, "dictionary picker")
  choose(false)
  equal(fixture.transport.next_id, pending.id)
  fixture.invalidate()
  choose(true)
  equal(fixture.transport.next_id, pending.id)
end

tests["malformed command results do not enter native UI"] = function()
  local fixture = setup()
  local previews = preview()
  Commands.tag("35")
  local pending = fixture.request()
  fixture.transport:reply(pending.id, {})
  Lsp.wait(function()
    return #fixture.notifications > 0
  end, "contract error")
  assert(fixture.notifications[1]:find("unsupported fix.describeTag result", 1, true))
  equal(#previews, 0)
end

tests["rename and wipe cancel document requests through native events"] = function()
  for _, event in ipairs({ "BufFilePre", "BufWipeout" }) do
    local fixture = setup()
    Commands.settings()
    local pending = fixture.request()
    vim.api.nvim_exec_autocmds(event, { buffer = fixture.buffer })
    equal(fixture.transport:notification("$/cancelRequest"), { id = pending.id })
  end
end

tests["client exit discards a late bootstrap continuation"] = function()
  local fixture = setup({ no_pull = true })
  Commands.tag("35")
  fixture.pull()
  fixture.transport:exit(0, 0)
  Lsp.wait(function()
    return fixture.client:is_stopped()
  end, "native client shutdown")
  equal(fixture.transport.next_id, 1)
end

tests["explicit dictionary submits once without opening a picker"] = function()
  local fixture = setup()
  Commands.dictionary("FIX.4.4")
  local pending = fixture.request()
  equal(pending.params, { command = "fix.useDictionary", arguments = { "FIX.4.4" } })
end

tests["one operation deadline spans sequential command requests"] = function()
  local fixture = setup({ timeout_ms = 40 })
  local completed = false
  Commands.operation(fixture.buffer, true, function(pending)
    pending:request("fix.describeOverrides", { pending.uri }, function(err)
      assert(not err)
      pending:request(
        "fix.decode",
        { { textDocument = { uri = pending.uri }, ranges = {} } },
        function()
          completed = true
          pending:finish()
        end
      )
    end)
  end)
  local first = fixture.request()
  vim.wait(25, function()
    return false
  end)
  fixture.transport:reply(first.id, { effective = {} })
  local second = fixture.request()
  Lsp.wait(function()
    return #fixture.notifications > 0
  end, "shared operation timeout")
  equal(fixture.transport:notification("$/cancelRequest"), { id = second.id })
  equal(completed, false)
end

return tests

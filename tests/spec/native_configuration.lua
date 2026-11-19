local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local Transport = require("tests.support.transport")
local Plugin = require("venue-reader")
local release = require("venue-reader.release")

local custom_root = vim.fs.normalize(vim.fn.tempname())
local equal = MiniTest.expect.equality

local tests = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.lsp.config.venue_reader = {} -- luacheck: ignore 122
    end,
  },
})

local function fixture(config, options)
  local transports, messages = {}, {}
  local original_notify = vim.notify
  rawset(vim, "notify", function(message)
    messages[#messages + 1] = tostring(message)
  end)
  MiniTest.finally(function()
    vim.lsp.enable("venue_reader", false)
    local clients = vim.lsp.get_clients({ name = "venue_reader", _uninitialized = true })
    for _, client in ipairs(clients) do
      client:stop(true)
    end
    for _, transport in ipairs(transports) do
      if transport.dispatchers then
        transport:exit(0, 0)
      end
    end
    vim.wait(30)
    rawset(vim, "notify", original_notify)
  end)
  config = vim.tbl_extend("force", {
    cmd = function(dispatchers)
      local transport = Transport.new()
      transports[#transports + 1] = transport
      return transport.command(dispatchers)
    end,
  }, config or {})
  vim.lsp.config("venue_reader", config)
  local setup_options = vim.tbl_deep_extend("force", {
    server = { cmd = { "/must-not-discover/native-command", "--stdio" }, auto_install = false },
    treesitter = { enabled = false },
    summary = { mode = "off" },
  }, options or {})
  Plugin.setup(setup_options)
  return { transports = transports, messages = messages, options = setup_options }
end

local function transport_for(context, count)
  assert(
    vim.wait(5000, function()
      return #context.transports >= (count or 1)
    end, 10),
    "Native command not invoked: " .. table.concat(context.messages, "\n")
  )
  return context.transports[count or 1]
end

local function initialized(context, buffer)
  local transport = transport_for(context)
  transport:initialize()
  local client
  Lsp.wait(function()
    client = vim.lsp.get_clients({ name = "venue_reader" })[1]
    return client
      and client.initialized
      and (not buffer or vim.lsp.buf_is_attached(buffer, client.id))
  end, "native initialization: " .. table.concat(context.messages, "\n"))
  return client, transport
end

local function plain_buffer()
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buffer)
  MiniTest.finally(function()
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end)
  return buffer
end

local function configuration(transport, client)
  return transport.dispatchers.server_request("workspace/configuration", {
    items = { { section = "fix" }, { section = "unrelated" } },
  }, { client_id = client.id })
end

for _, case in ipairs({
  { name = "default", expected = true },
  { name = "explicit true", value = true, expected = true },
  { name = "explicit false", value = false, expected = false },
}) do
  tests["repeated setup preserves documentChanges " .. case.name .. " in initialize"] = function()
    local context = fixture({
      capabilities = {
        workspace = {
          workspaceEdit = { documentChanges = case.value, normalizesLineEndings = false },
        },
        experimental = { unrelated = true },
      },
    })
    Plugin.setup(context.options)
    local buffer = Lsp.buffer()
    local capabilities = transport_for(context).pending[1].params.capabilities
    equal(capabilities.workspace.workspaceEdit.documentChanges, case.expected)
    equal(capabilities.workspace.workspaceEdit.normalizesLineEndings, false)
    equal(capabilities.experimental.unrelated, true)
    equal(capabilities.experimental.venueReader.summaryTokens, 1)
    initialized(context, buffer)
  end
end

tests["native settings survive setup and mode changes"] = function()
  local settings = {
    fix = {
      messageSummary = { template = "{35.valueName}", details = false },
      diagnostics = { enabled = false },
      limits = { rangeLines = 17 },
    },
    unrelated = { keep = true },
  }
  local context = fixture({ settings = vim.deepcopy(settings) })
  local buffer = Lsp.buffer()
  local client, transport = initialized(context, buffer)
  equal(vim.lsp.config.venue_reader.settings, settings)
  for _, mode in ipairs({ "front", "above", "hidden", "codelens", "off" }) do
    Plugin.summary(mode)
    equal(vim.lsp.config.venue_reader.settings, settings)
    equal(client.settings.fix.messageSummary.template, settings.fix.messageSummary.template)
    equal(client.settings.fix.diagnostics, settings.fix.diagnostics)
    equal(client.settings.fix.limits, settings.fix.limits)
    equal(client.settings.unrelated, settings.unrelated)
    equal(configuration(transport, client), { client.settings.fix, settings.unrelated })
  end
end

tests["settings registered after setup reach initialization and native pulls"] = function()
  local context = fixture()
  vim.lsp.config("venue_reader", { settings = { fix = { limits = { rangeLines = 23 } } } })
  local buffer = Lsp.buffer()
  local transport = transport_for(context)
  equal(transport.pending[1].params.initializationOptions.fix.limits.rangeLines, 23)
  local client = initialized(context, buffer)
  equal(configuration(transport, client)[1].limits.rangeLines, 23)
end

tests["native callbacks preserve initialization options and capabilities"] = function()
  local calls = { before = 0, initialized = 0, attached = 0, exited = 0 }
  local context = fixture({
    root_dir = custom_root,
    init_options = { unrelated = { keep = true } },
    capabilities = { experimental = { unrelated = true } },
    before_init = function(_, config)
      calls.before = calls.before + 1
      config.settings.fix = config.settings.fix or {}
      config.settings.fix.limits = { rangeLines = 29 }
    end,
    on_init = function(client)
      calls.initialized = calls.initialized + 1
      client.settings.unrelated = { from_callback = true }
    end,
    on_attach = function()
      calls.attached = calls.attached + 1
    end,
    on_exit = function()
      calls.exited = calls.exited + 1
    end,
  })
  Plugin.setup(context.options)
  local buffer = Lsp.buffer()
  local transport = transport_for(context)
  local params = transport.pending[1].params
  equal(params.rootUri, vim.uri_from_fname(custom_root))
  equal(params.initializationOptions.unrelated, { keep = true })
  equal(params.initializationOptions.fix.limits.rangeLines, 29)
  equal(params.capabilities.experimental.unrelated, true)
  local client = initialized(context, buffer)
  equal(client.settings.unrelated, { from_callback = true })
  equal(calls, { before = 1, initialized = 1, attached = 1, exited = 0 })
  transport:exit(0, 0)
  Lsp.wait(function()
    return calls.exited == 1
  end, "user exit callback")
end

tests["explicit live settings survive summary mode changes on command-only client"] = function()
  local context = fixture({ settings = { fix = { limits = { rangeLines = 31 } } } })
  plain_buffer()
  Plugin.tag(35)
  local client, transport = initialized(context)
  equal(next(client.attached_buffers), nil)
  client.settings.fix.limits.rangeLines = 37
  client:notify("workspace/didChangeConfiguration", { settings = client.settings })
  Plugin.summary("codelens")
  equal(client.settings.fix.messageSummary.channels, { inlayHints = false, codeLens = true })
  equal(client.settings.fix.limits.rangeLines, 37)
  equal(vim.lsp.config.venue_reader.settings.fix.limits.rangeLines, 31)
  equal(configuration(transport, client)[1].limits.rangeLines, 37)
end

tests["mode changes during cold initialization reconcile only managed settings"] = function()
  local context = fixture({ settings = { fix = { limits = { rangeLines = 41 } } } })
  plain_buffer()
  Plugin.tag(35)
  local transport = transport_for(context)
  equal(transport.pending[1].params.initializationOptions.fix.limits.rangeLines, 41)
  Plugin.summary("codelens")
  local client = initialized(context)
  equal(client.settings.fix.limits.rangeLines, 41)
  equal(client.settings.fix.messageSummary.channels, { inlayHints = false, codeLens = true })
  equal(client.config.settings, client.settings)
  equal(configuration(transport, client)[1], client.settings.fix)
end

tests["a silent root resolver times out and its late callback cannot launch a client"] = function()
  local on_dir
  local context = fixture({
    root_dir = function(_, callback)
      on_dir = callback
    end,
  }, { commands = { timeout_ms = 50 } })
  plain_buffer()
  Plugin.tag(35)
  Lsp.wait(function()
    return on_dir ~= nil
  end, "custom root resolver")
  Lsp.wait(function()
    return table.concat(context.messages, "\n"):find("timed out", 1, true) ~= nil
  end, "root resolver timeout")
  on_dir(vim.fn.tempname())
  vim.wait(60)
  equal(#context.transports, 0)
end

tests["asynchronous native root controls command-only startup"] = function()
  local on_dir
  local context = fixture({
    root_dir = function(_, callback)
      on_dir = callback
    end,
  })
  plain_buffer()
  Plugin.tag(35)
  Lsp.wait(function()
    return on_dir ~= nil
  end, "custom command root")
  equal(#context.transports, 0)
  local selected_root = vim.fs.normalize(vim.fn.tempname())
  on_dir(selected_root)
  local transport = transport_for(context)
  equal(transport.pending[1].params.rootUri, vim.uri_from_fname(selected_root))
  local client = initialized(context)
  equal(Plugin.status().session.root, selected_root)
  equal(next(client.attached_buffers), nil)
end

local function shutdown(transport)
  Lsp.wait(function()
    return vim.tbl_contains(transport.events, "shutdown")
  end, "native shutdown request")
  for id, request in pairs(transport.pending) do
    if request.method == "shutdown" then
      transport:reply(id, vim.NIL)
    end
  end
end

tests["selected summary mode overrides registered channels across restart"] = function()
  local registered = { inlayHints = true, codeLens = false }
  local context = fixture({
    settings = { fix = { messageSummary = { channels = vim.deepcopy(registered) } } },
  })
  local buffer = Lsp.buffer()
  local first = transport_for(context)
  equal(
    first.pending[1].params.initializationOptions.fix.messageSummary.channels,
    { inlayHints = false, codeLens = false }
  )
  local client = initialized(context, buffer)
  Plugin.summary("codelens")
  equal(client.settings.fix.messageSummary.channels, { inlayHints = false, codeLens = true })
  Plugin.restart()
  shutdown(first)
  local replacement = transport_for(context, 2)
  equal(
    replacement.pending[1].params.initializationOptions.fix.messageSummary.channels,
    { inlayHints = false, codeLens = true }
  )
  equal(vim.lsp.config.venue_reader.settings.fix.messageSummary.channels, registered)
  equal(table.concat(context.messages, "\n"):find("contradicts", 1, true), nil)
end

for kind, root_dir in pairs({
  string = custom_root,
  ["function"] = function(_, on_dir)
    on_dir(custom_root)
  end,
}) do
  tests["custom " .. kind .. " root does not attach an unnamed FIX buffer"] = function()
    local context = fixture({ root_dir = root_dir })
    local buffer = plain_buffer()
    vim.api.nvim_set_option_value("filetype", "fix", { buf = buffer })
    vim.wait(100)
    equal(#context.transports, 0)
    equal(#vim.lsp.get_clients({ bufnr = buffer, name = "venue_reader" }), 0)
  end
end

tests["settings registered after setup reach a FIX buffer opened before setup"] = function()
  local buffer = Lsp.buffer()
  local context = fixture()
  vim.lsp.config("venue_reader", { settings = { fix = { limits = { rangeLines = 43 } } } })
  local transport = transport_for(context)
  equal(transport.pending[1].params.initializationOptions.fix.limits.rangeLines, 43)
  local client = initialized(context, buffer)
  equal(client.settings.fix.limits.rangeLines, 43)
end

local function child()
  local process = MiniTest.new_child_neovim()
  process.start({ "-u", "NONE", "-i", "NONE" })
  MiniTest.finally(process.stop)
  process.lua_func(function(directory)
    vim.opt.runtimepath:prepend(directory)
  end, assert(vim.env.VENUE_READER_TEST_ROOT))
  return process
end

tests["status and health work before setup and after a rejected setup"] = function()
  local result = child().lua_func(function()
    local plugin = require("venue-reader")
    for _, name in ipairs({ "start", "ok", "info", "error", "warn" }) do
      rawset(vim.health, name, function() end)
    end
    local function probe()
      local status_ok, status = pcall(plugin.status)
      local health_ok, failure = pcall(require("venue-reader.health").check)
      return {
        status = status_ok and status.acquisition.state or tostring(status),
        health = health_ok or tostring(failure),
      }
    end
    local before = probe()
    vim.lsp.config("venue_reader", { handlers = { ["workspace/configuration"] = function() end } })
    local rejected = not pcall(plugin.setup, { treesitter = { enabled = false } })
    return { before = before, rejected = rejected, after = probe() }
  end)
  local idle = { status = "idle", health = true }
  equal(result, { before = idle, rejected = true, after = idle })
end

tests["setup after a module reload keeps native overrides"] = function()
  local result = child().lua_func(function()
    vim.lsp.config("venue_reader", {
      cmd = { "reload-native", "--stdio" },
      capabilities = { workspace = { workspaceEdit = { documentChanges = false } } },
    })
    local options = {
      server = { auto_install = false },
      treesitter = { enabled = false },
      summary = { mode = "off" },
    }
    require("venue-reader").setup(options)
    for name in pairs(package.loaded) do
      if name:match("^venue%-reader") then
        package.loaded[name] = nil
      end
    end
    vim.g.fix_plugin_owner = nil -- luacheck: ignore 122
    local success, failure = pcall(require("venue-reader").setup, options)
    local capabilities = vim.lsp.config.venue_reader.capabilities
    return {
      reloaded = success or tostring(failure),
      hooks = require("venue-reader.native").check(vim.lsp.config.venue_reader),
      acquisition = require("venue-reader").status().acquisition.state,
      document_changes = capabilities.workspace.workspaceEdit.documentChanges,
    }
  end)
  equal(
    result,
    { reloaded = true, hooks = true, acquisition = "external", document_changes = false }
  )
end

tests["removed options and required handler replacements fail clearly"] = function()
  MiniTest.expect.error(function()
    Plugin.setup({ settings = {} })
  end, "settings")
  MiniTest.expect.error(function()
    Plugin.setup({ runtime = {} })
  end, "runtime")
  vim.lsp.config("venue_reader", {
    handlers = { ["workspace/configuration"] = function() end },
  })
  MiniTest.expect.error(function()
    Plugin.setup({ treesitter = { enabled = false } })
  end, "workspace/configuration")
end

tests["native function transport reports its initialized version"] = function()
  local context = fixture()
  local buffer = Lsp.buffer()
  initialized(context, buffer)
  local status = Plugin.status(buffer)
  equal(status.session.version, release.series .. ".0")
  equal(status.session.argv, nil)
  assert(status.acquisition.state ~= "idle")
  assert(status.acquisition.error == nil)
end

tests["native transport with incompatible server version is stopped"] = function()
  local context = fixture()
  Lsp.buffer()
  local transport = transport_for(context)
  transport:reply(1, {
    capabilities = {},
    serverInfo = { name = "venue-reader", version = "999.0.0" },
  })
  Lsp.wait(function()
    return table.concat(context.messages, "\n"):find("version", 1, true) ~= nil
  end, "incompatible version diagnostic")
  Lsp.wait(function()
    return transport.closing
  end, "incompatible client stop")
end

tests["native argv bypasses discovery and preserves native command environment"] = function()
  local original_rpc = vim.lsp.rpc.start
  local transport = Transport.new()
  local observed
  rawset(vim.lsp.rpc, "start", function(command, dispatchers, options)
    observed = { command = command, options = options }
    return transport.command(dispatchers)
  end)
  MiniTest.finally(function()
    rawset(vim.lsp.rpc, "start", original_rpc)
    if transport.dispatchers then
      transport:exit(0, 0)
    end
  end)
  local working_directory = vim.fs.normalize(vim.uv.cwd())
  local context = fixture({
    cmd = { "native-wrapper", "--stdio" },
    cmd_cwd = working_directory,
    cmd_env = { NATIVE_CONFIGURATION_TEST = "yes" },
  })
  Lsp.buffer()
  Lsp.wait(function()
    return observed ~= nil
  end, "native argv invocation")
  equal(observed.command, { "native-wrapper", "--stdio" })
  equal(observed.options.cwd, working_directory)
  equal(observed.options.env.NATIVE_CONFIGURATION_TEST, "yes")
  context.transports[1] = transport
  local client = initialized(context)
  equal(Plugin.status(next(client.attached_buffers)).session.argv, observed.command)
end

tests["failing user before_init never sends initialize"] = function()
  local context = fixture({
    before_init = function()
      error("native before_init failed")
    end,
  })
  Lsp.buffer()
  local transport = transport_for(context)
  assert(
    vim.wait(1000, function()
      return transport.closing
    end, 10),
    vim.inspect({ events = transport.events, messages = context.messages })
  )
  assert(not vim.tbl_contains(transport.events, "initialize"))
  assert(table.concat(context.messages, "\n"):find("native before_init failed", 1, true))
end

tests["native transport without server version is stopped"] = function()
  local context = fixture()
  Lsp.buffer()
  local transport = transport_for(context)
  transport:reply(1, { capabilities = {} })
  Lsp.wait(function()
    return transport.closing
  end, "missing server version stop")
  assert(table.concat(context.messages, "\n"):find("version", 1, true))
end

tests["repeated unchanged summary configuration does not send another notification"] = function()
  local context = fixture()
  local buffer = Lsp.buffer()
  local client, transport = initialized(context, buffer)
  local function count()
    return #vim.tbl_filter(function(event)
      return event.method == "workspace/didChangeConfiguration"
    end, transport.notifications)
  end
  local before = count()
  Plugin.summary("codelens")
  equal(count(), before + 1)
  Plugin.summary("codelens")
  equal(count(), before + 1)
  equal(client.settings.fix.messageSummary.channels.codeLens, true)
end

local function runtime_fixture()
  local Server = require("venue-reader.server")
  local original_resolve, original_rpc = Server.resolve, vim.lsp.rpc.start
  local pending, transports, commands = {}, {}, {}
  rawset(Server, "resolve", function(options, callback)
    pending[#pending + 1] = { options = options, callback = callback }
  end)
  rawset(vim.lsp.rpc, "start", function(command, dispatchers)
    commands[#commands + 1] = vim.deepcopy(command)
    local transport = Transport.new()
    transports[#transports + 1] = transport
    return transport.command(dispatchers)
  end)
  MiniTest.finally(function()
    vim.lsp.enable("venue_reader", false)
    for _, transport in ipairs(transports) do
      transport:exit(0, 0)
    end
    vim.wait(30)
    rawset(Server, "resolve", original_resolve)
    rawset(vim.lsp.rpc, "start", original_rpc)
  end)
  vim.lsp.config("venue_reader", {
    root_dir = function(buffer, on_dir)
      on_dir(vim.fs.joinpath(vim.uv.cwd(), "runtime-root-" .. buffer))
    end,
  })
  local function setup(binary)
    Plugin.setup({
      server = { cmd = { binary, "--stdio" } },
      treesitter = { enabled = false },
      summary = { mode = "off" },
    })
  end
  setup("runtime-first")
  local function finish(index)
    local request = pending[index]
    request.callback(nil, vim.deepcopy(request.options.cmd), release.series .. ".0")
  end
  return { pending = pending, commands = commands, setup = setup, finish = finish }
end

tests["concurrent roots share a resolved runtime without consuming its argv"] = function()
  local context = runtime_fixture()
  Lsp.buffer()
  Lsp.buffer()
  Lsp.wait(function()
    return #context.pending == 2
  end, "parallel server discovery")
  context.finish(2)
  context.finish(1)
  Lsp.wait(function()
    return #context.commands == 2
  end, "parallel runtime startups")
  equal(context.commands, { { "runtime-first", "--stdio" }, { "runtime-first", "--stdio" } })
end

tests["old discovery completion cannot overwrite a newer runtime generation"] = function()
  local context = runtime_fixture()
  Lsp.buffer()
  Lsp.wait(function()
    return #context.pending == 1
  end, "initial discovery")
  context.setup("runtime-second")
  Lsp.buffer()
  Lsp.wait(function()
    return #context.pending >= 2
  end, "replacement discovery")
  context.finish(2)
  context.finish(1)
  Lsp.wait(function()
    return #context.commands == 1
  end, "replacement runtime startup")
  equal(context.commands[1], { "runtime-second", "--stdio" })
end

tests["runtime replaced after root delivery cannot launch its scheduled old command"] = function()
  local context = runtime_fixture()
  Lsp.buffer()
  Lsp.wait(function()
    return #context.pending == 1
  end, "initial discovery")
  context.finish(1)
  context.setup("runtime-second")
  vim.wait(60)
  equal(context.commands, {})
end

tests["filetype change during discovery prevents attachment"] = function()
  local context = runtime_fixture()
  local buffer = Lsp.buffer()
  Lsp.wait(function()
    return #context.pending == 1
  end, "initial discovery")
  vim.api.nvim_set_option_value("filetype", "text", { buf = buffer })
  context.finish(1)
  vim.wait(60)
  equal(context.commands, {})
  equal(#vim.lsp.get_clients({ bufnr = buffer, name = "venue_reader" }), 0)
end

tests["disable after root delivery prevents the scheduled transport startup"] = function()
  local context = runtime_fixture()
  Lsp.buffer()
  Lsp.wait(function()
    return #context.pending == 1
  end, "initial discovery")
  context.finish(1)
  vim.lsp.enable("venue_reader", false)
  vim.wait(60)
  equal(context.commands, {})
end

return tests

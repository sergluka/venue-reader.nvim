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
      vim.lsp.config["venue-reader"] = {} -- luacheck: ignore 122
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
    vim.lsp.enable("venue-reader", false)
    local clients = vim.lsp.get_clients({ name = "venue-reader", _uninitialized = true })
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
  vim.lsp.config("venue-reader", config)
  local setup_options = vim.tbl_deep_extend("force", {
    server = { cmd = { "/must-not-discover/native-command", "--stdio" }, update_version = false },
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
    client = vim.lsp.get_clients({ name = "venue-reader" })[1]
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
  equal(vim.lsp.config["venue-reader"].settings, settings)
  for _, mode in ipairs({ "front", "above", "hidden", "codelens", "off" }) do
    Plugin.summary(mode)
    equal(vim.lsp.config["venue-reader"].settings, settings)
    equal(client.settings.fix.messageSummary.template, settings.fix.messageSummary.template)
    equal(client.settings.fix.diagnostics, settings.fix.diagnostics)
    equal(client.settings.fix.limits, settings.fix.limits)
    equal(client.settings.unrelated, settings.unrelated)
    equal(configuration(transport, client), { client.settings.fix, settings.unrelated })
  end
end

tests["settings registered after setup reach initialization and native pulls"] = function()
  local context = fixture()
  vim.lsp.config("venue-reader", { settings = { fix = { limits = { rangeLines = 23 } } } })
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
  equal(vim.lsp.config["venue-reader"].settings.fix.limits.rangeLines, 31)
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
  equal(vim.lsp.config["venue-reader"].settings.fix.messageSummary.channels, registered)
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
    equal(#vim.lsp.get_clients({ bufnr = buffer, name = "venue-reader" }), 0)
  end
end

tests["settings registered after setup reach a FIX buffer opened before setup"] = function()
  local buffer = Lsp.buffer()
  local context = fixture()
  vim.lsp.config("venue-reader", { settings = { fix = { limits = { rangeLines = 43 } } } })
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

tests["opening a FIX file records the unavailable server in message history"] = function()
  local result = child().lua_func(function()
    rawset(vim, "notify", function() end)
    local plugin = require("venue-reader")
    local problem = "Could not fetch release metadata for this test"
    require("venue-reader.release").resolve = function(_, _, callback)
      callback(problem)
    end
    local exepath = vim.fn.exepath
    rawset(vim.fn, "exepath", function(name)
      return name == "venue-reader" and "" or exepath(name)
    end)
    plugin.setup({ treesitter = { enabled = false } })
    vim.cmd("filetype on")
    vim.cmd.edit({ args = { vim.fn.tempname() .. ".fix" } })
    assert(
      vim.wait(1000, function()
        local history = vim.api.nvim_exec2("messages", { output = true }).output
        return history:find("venue-reader: " .. problem, 1, true) ~= nil
      end),
      "Missing startup diagnostic in :messages"
    )
    return { plugin.status().acquisition.error, #vim.lsp.get_clients({ bufnr = 0 }) }
  end)
  equal(result, { "Could not fetch release metadata for this test", 0 })
end

tests["manual installation confirms a reused release once in message history"] = function()
  local count = child().lua_func(function()
    rawset(vim, "notify", function() end)
    local manifest = require("venue-reader.release")
    local target, system = manifest.platform()
    local directory = vim.fn.tempname()
    local stdpath = vim.fn.stdpath
    rawset(vim.fn, "stdpath", function(kind)
      return kind == "data" and directory or stdpath(kind)
    end)
    local binary = system == "Windows_NT" and "venue-reader.exe" or "venue-reader"
    local path = vim.fs.joinpath(directory, "venue-reader", manifest.version, target, binary)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile({}, path)
    rawset(vim, "system", function(command, options, callback)
      assert(vim.deep_equal(command, { path, "--version" }), vim.inspect(command))
      options.stdout(nil, "venue-reader " .. manifest.version .. "\n")
      callback({ code = 0 })
      return { kill = function() end }
    end)
    local plugin = require("venue-reader")
    plugin.setup({ server = { update_version = false }, treesitter = { enabled = false } })
    vim.cmd("VenueReader install server " .. manifest.version)
    assert(vim.wait(1000, function()
      return plugin.status().acquisition.state == "ready"
    end))
    local notice = ("venue-reader: Installed server %s at %s"):format(manifest.version, path)
    local history = vim.api.nvim_exec2("messages", { output = true }).output
    return vim.fn.count(vim.split(history, "\n", { plain = true }), notice)
  end)
  equal(count, 1)
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
        policy = status_ok and status.server_policy or nil,
        health = health_ok or tostring(failure),
      }
    end
    local before = probe()
    vim.lsp.config("venue-reader", { handlers = { ["workspace/configuration"] = function() end } })
    local rejected = not pcall(plugin.setup, { treesitter = { enabled = false } })
    return { before = before, rejected = rejected, after = probe() }
  end)
  local idle = { status = "idle", policy = { update_version = "latest" }, health = true }
  equal(result, { before = idle, rejected = true, after = idle })
end

local function health_probe()
  local process = child()
  process.lua_func(function()
    local reports
    for _, level in ipairs({ "start", "ok", "info", "error", "warn" }) do
      rawset(vim.health, level, function(message)
        if not message:find("\n", 1, true) then
          reports[#reports + 1] = { level, message }
        end
      end)
    end
    _G.health_report = function()
      reports = {}
      require("venue-reader.health").check()
      return reports
    end
  end)
  return process
end

for _, case in ipairs({
  { name = "default", message = "latest compatible stable release" },
  { name = "latest", selector = "latest", message = "latest compatible stable release" },
  { name = "pin", selector = release.version, message = "pinned to " .. release.version },
  { name = "disabled", selector = false, message = "installation and updates are disabled" },
  { name = "explicit", command = "server.cmd", message = "supplied by server.cmd" },
  { name = "native", command = "native_cmd", message = "supplied by native LSP cmd" },
}) do
  tests["health reports the configured " .. case.name .. " policy before discovery"] = function()
    local process = health_probe()
    local result = process.lua_func(function(config)
      local cmd = { "/user/server", "--stdio" }
      if config.command == "native_cmd" then
        vim.lsp.config("venue-reader", { cmd = cmd })
      end
      require("venue-reader").setup({
        server = {
          cmd = config.command == "server.cmd" and cmd or nil,
          update_version = config.selector,
        },
        treesitter = { enabled = false },
      })
      return {
        policy = require("venue-reader").status().server_policy,
        reports = _G.health_report(),
      }
    end, case)
    local expected = case.name == "default" and "latest" or case.selector or false
    equal(result.policy, { source = case.command, update_version = expected })
    local messages = vim.tbl_map(function(entry)
      return entry[2]
    end, result.reports)
    local text = table.concat(messages, "\n")
    assert(text:find(case.message, 1, true), text)
    equal(text:find("for a one-time install", 1, true) ~= nil, case.name == "disabled")
  end
end

tests["health warns when an automatic update fails and a PATH server is usable"] = function()
  local result = health_probe().lua_func(function()
    local plugin = require("venue-reader")
    local manifest = require("venue-reader.release")
    local complete_lookup
    manifest.resolve = function(_, _, callback)
      complete_lookup = callback
    end
    local exepath = vim.fn.exepath
    rawset(vim.fn, "exepath", function(name)
      return name == "venue-reader" and "/existing/server" or exepath(name)
    end)
    rawset(vim, "system", function(command, options, callback)
      assert(command[2] == "--version", vim.inspect(command))
      options.stdout(nil, "venue-reader " .. manifest.version .. "\n")
      callback({ code = 0 })
      return { kill = function() end }
    end)
    plugin.setup({ treesitter = { enabled = false } })
    plugin.restart()
    local discovering = _G.health_report()
    complete_lookup("release lookup offline", nil, true)
    assert(vim.wait(1000, function()
      return plugin.status().acquisition.state == "ready"
    end))
    return { discovering = discovering, ready = _G.health_report() }
  end)
  local function contains(entries, level, fragment)
    return vim.iter(entries):any(function(entry)
      return entry[1] == level and entry[2]:find(fragment, 1, true) ~= nil
    end)
  end
  assert(contains(result.discovering, "info", "latest compatible stable release"))
  assert(contains(result.discovering, "info", "discovering"))
  assert(contains(result.ready, "warn", "release lookup offline"))
  assert(contains(result.ready, "warn", release.version .. " (PATH)"))
end

tests["setup after a module reload keeps native overrides"] = function()
  local result = child().lua_func(function()
    vim.lsp.config("venue-reader", {
      cmd = { "reload-native", "--stdio" },
      capabilities = { workspace = { workspaceEdit = { documentChanges = false } } },
    })
    local options = {
      server = { update_version = false },
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
    local capabilities = vim.lsp.config["venue-reader"].capabilities
    return {
      reloaded = success or tostring(failure),
      hooks = require("venue-reader.native").check(vim.lsp.config["venue-reader"]),
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
  vim.lsp.config("venue-reader", {
    handlers = { ["workspace/configuration"] = function() end },
  })
  MiniTest.expect.error(function()
    Plugin.setup({ treesitter = { enabled = false } })
  end, "workspace/configuration")
end

tests["server policy rejects invalid configuration before enabling the client"] = function()
  for _, selector in ipairs({ true, "false", "", "v0.4.0", "0.4", "^0.4.0", {}, 0 }) do
    MiniTest.expect.error(function()
      Plugin.setup({ server = { update_version = selector } })
    end, "server.update_version")
  end
  MiniTest.expect.error(function()
    Plugin.setup({ server = { update_version = "999.10.0" } })
  end, "Unsupported server version")
end

for _, source in ipairs({ "server.cmd", "native cmd" }) do
  tests[source .. " rejects update targets on initial and repeated setup"] = function()
    local results = child().lua_func(function(command_source, pin)
      local plugin = require("venue-reader")
      local observed = { errors = {}, policies = {} }
      local command = { "/external/venue-reader", "--stdio" }
      if command_source == "native cmd" then
        vim.lsp.config("venue-reader", { cmd = command })
      end
      local function configure(selector)
        plugin.setup({
          server = {
            cmd = command_source == "server.cmd" and command or nil,
            update_version = selector,
          },
          treesitter = { enabled = false },
        })
      end
      local function reject(selector)
        local ok, failure = pcall(configure, selector)
        assert(not ok, "Conflicting selector accepted: " .. selector)
        observed.errors[#observed.errors + 1] = tostring(failure)
      end
      reject("latest")
      reject(pin)
      observed.enabled_before = vim.lsp.is_enabled("venue-reader")
      observed.command_before = vim.fn.exists(":VenueReader")
      local server = require("venue-reader.server")
      server.resolve = function(options)
        observed.policies[#observed.policies + 1] = options.update_version
      end
      local function record_policy()
        if command_source == "native cmd" then
          observed.policies[#observed.policies + 1] = plugin.status().acquisition.update_version
        else
          plugin.restart()
        end
      end
      configure(nil)
      record_policy()
      for _, target in ipairs({ "latest", pin }) do
        reject(target)
        record_policy()
      end
      configure(false)
      record_policy()
      return observed
    end, source, release.version)
    equal(results.enabled_before, false)
    equal(results.command_before, 0)
    equal(results.policies, { false, false, false, false })
    for _, message in ipairs(results.errors) do
      assert(message:find("update_version", 1, true), message)
      assert(message:find("cmd", 1, true), message)
    end
  end
end

tests["plugin command wrapper preserves managed defaults and explicit update targets"] = function()
  local observed = child().lua_func(function(version)
    local plugin = require("venue-reader")
    local result = { policies = {}, warnings = {} }
    rawset(vim, "notify", function(message)
      result.warnings[#result.warnings + 1] = message
    end)
    local server = require("venue-reader.server")
    server.resolve = function(options)
      result.policies[#result.policies + 1] = options.update_version
    end
    for _, config in ipairs({
      { auto_install = false },
      { auto_install = true },
      { update_version = "latest" },
      { update_version = version },
      {},
      { update_version = false },
      {},
      { cmd = { "/user/server" } },
      {},
    }) do
      plugin.setup({ server = config, treesitter = { enabled = false } })
      plugin.restart()
    end
    return result
  end, release.version)
  equal(
    observed.policies,
    { "latest", "latest", "latest", release.version, "latest", false, "latest", false, "latest" }
  )
  equal(#observed.warnings, 1)
  assert(observed.warnings[1]:find("server.auto_install was removed", 1, true))
end

tests["explicit install defaults to latest and rejects false before acquisition"] = function()
  local result = child().lua_func(function(pin)
    local plugin = require("venue-reader")
    local server = require("venue-reader.server")
    local observed = { targets = {} }
    rawset(vim, "notify", function(message)
      observed.message = message
    end)
    server.install = function(version)
      observed.targets[#observed.targets + 1] = version
    end
    server.resolve = function(options)
      observed.pin = options.update_version
    end
    plugin.setup({ server = { update_version = pin }, treesitter = { enabled = false } })
    vim.cmd("VenueReader install server")
    vim.cmd("VenueReader install server latest")
    vim.cmd("VenueReader install server " .. pin)
    vim.cmd("VenueReader install server false")
    plugin.restart()
    return observed
  end, release.version)
  equal(result.targets, { "latest", "latest", release.version })
  equal(result.pin, release.version)
  assert(result.message:find("exact server version", 1, true))
end

tests["native initialization accepts new minors and rejects new majors on restart"] = function()
  local context = fixture()
  local buffer = Lsp.buffer()
  local first = transport_for(context)
  local version = release.major .. ".987.0"
  first:reply(1, {
    capabilities = {},
    serverInfo = { name = "venue-reader", version = version },
  })
  Lsp.wait(function()
    local session = Plugin.status(buffer).session
    return session and session.version == version
  end, "running compatible minor")
  equal(Plugin.status(buffer).session.version, version)
  Plugin.restart()
  shutdown(first)
  local replacement = transport_for(context, 2)
  replacement:reply(1, {
    capabilities = {},
    serverInfo = { name = "venue-reader", version = (tonumber(release.major) + 1) .. ".0.0" },
  })
  Lsp.wait(function()
    return replacement.closing
  end, "new major rejected during restart")
  assert(Plugin.status().acquisition.error:find("major " .. release.major, 1, true))
end

tests["restart rechecks the same executable and keeps the running client on failure"] = function()
  local server_path = "version-changing-wrapper"
  local disk_version = release.version
  local original_system, original_rpc, original_notify = vim.system, vim.lsp.rpc.start, vim.notify
  local exepath, resolve_release = vim.fn.exepath, release.resolve
  local transports, messages = {}, {}
  rawset(vim.fn, "exepath", function(command)
    return command == "venue-reader" and server_path or exepath(command)
  end)
  release.resolve = function(_, _, callback)
    callback("Pinned release unavailable")
  end
  rawset(vim, "system", function(command, options, callback)
    if command[1] ~= server_path then
      return original_system(command, options, callback)
    end
    equal(command, { server_path, "--version" })
    options.stdout(nil, "venue-reader " .. disk_version .. "\n")
    callback({ code = 0 })
    return { kill = function() end }
  end)
  rawset(vim.lsp.rpc, "start", function(_, dispatchers)
    local transport = Transport.new()
    transports[#transports + 1] = transport
    return transport.command(dispatchers)
  end)
  rawset(vim, "notify", function(message)
    messages[#messages + 1] = tostring(message)
  end)
  MiniTest.finally(function()
    vim.lsp.enable("venue-reader", false)
    for _, transport in ipairs(transports) do
      transport:exit(0, 0)
    end
    vim.wait(30)
    rawset(vim, "notify", original_notify)
    rawset(vim, "system", original_system)
    rawset(vim.lsp.rpc, "start", original_rpc)
    rawset(vim.fn, "exepath", exepath)
    release.resolve = resolve_release
  end)
  local function pin(version)
    Plugin.setup({
      server = { update_version = version },
      treesitter = { enabled = false },
    })
  end
  pin(disk_version)
  local buffer = Lsp.buffer()
  local context = { transports = transports, messages = messages }
  local function initialize(index)
    local transport = transport_for(context, index)
    transport:reply(1, {
      capabilities = {},
      serverInfo = { name = "venue-reader", version = disk_version },
    })
    Lsp.wait(function()
      local session = Plugin.status(buffer).session
      return session and session.version == disk_version and session.source == "PATH"
    end, "reattachment to " .. disk_version)
    return transport
  end
  local first = initialize(1)
  disk_version = release.major .. ".987.0"
  Plugin.restart()
  Lsp.wait(function()
    return Plugin.status(buffer).acquisition.error == "Pinned release unavailable"
  end, "pinned version mismatch at unchanged path")
  equal(Plugin.status(buffer).session.version, release.version)
  equal(vim.tbl_contains(first.events, "shutdown"), false)
  pin(disk_version)
  Plugin.restart()
  shutdown(first)
  local second = initialize(2)
  disk_version = release.version
  pin(disk_version)
  Plugin.restart()
  shutdown(second)
  initialize(3)
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
    vim.lsp.enable("venue-reader", false)
    for _, transport in ipairs(transports) do
      transport:exit(0, 0)
    end
    vim.wait(30)
    rawset(Server, "resolve", original_resolve)
    rawset(vim.lsp.rpc, "start", original_rpc)
  end)
  vim.lsp.config("venue-reader", {
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
  equal(#vim.lsp.get_clients({ bufnr = buffer, name = "venue-reader" }), 0)
end

tests["disable after root delivery prevents the scheduled transport startup"] = function()
  local context = runtime_fixture()
  Lsp.buffer()
  Lsp.wait(function()
    return #context.pending == 1
  end, "initial discovery")
  context.finish(1)
  vim.lsp.enable("venue-reader", false)
  vim.wait(60)
  equal(context.commands, {})
end

return tests

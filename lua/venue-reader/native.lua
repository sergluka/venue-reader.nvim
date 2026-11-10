local M = {}

local Capabilities = require("venue-reader.capabilities")
local Commands = require("venue-reader.commands")
local Server = require("venue-reader.server")
local Summaries = require("venue-reader.summaries")
local Release = require("venue-reader.release")

local owner = tostring(M)
local original
local active
local summary

local function notify(message)
  vim.notify("venue-reader: " .. tostring(message), vim.log.levels.ERROR)
end

function M.managed(client)
  return client.config.venue_reader_owner == owner and not client.config.venue_reader_failure
end

local function callbacks(value, ...)
  for _, callback in ipairs(type(value) == "table" and value or { value }) do
    local success, failure = pcall(callback, ...)
    if not success then
      notify(failure)
    end
  end
end

local function prepared(settings, mode)
  return Summaries.settings(mode, settings or {})
end

local function update(client)
  local settings = client.settings
  local result = vim.deepcopy(settings)
  local managed_settings = Summaries.settings(summary, {}).fix.messageSummary
  result.fix = result.fix or {}
  result.fix.messageSummary =
    vim.tbl_deep_extend("force", result.fix.messageSummary or {}, managed_settings)
  if vim.deep_equal(settings, result) then
    client.config.settings = settings
    return
  end
  settings.fix = result.fix
  client.config.settings = settings
  if client.initialized then
    client:notify("workspace/didChangeConfiguration", { settings = settings })
  end
end

function M.check(config)
  local hooks = config.venue_reader_hooks or {}
  return config.venue_reader_owner == owner
    and config.handlers["workspace/configuration"] == Commands.configuration
    and config.handlers["textDocument/inlayHint"] == Summaries.handler
    and config.before_init == hooks.before_init
    and config.on_init == hooks.on_init
    and config.on_exit == hooks.on_exit
end

function M.resolve(buffer, command, valid, callback)
  local context = active
  if not command and not context.eligible(buffer) then
    if vim.api.nvim_buf_is_valid(buffer) and vim.bo[buffer].filetype == "fix" then
      vim.notify_once("venue-reader: use :file /path/log.fix to name the buffer")
    end
    return
  end
  local name = vim.api.nvim_buf_get_name(buffer)
  local captured_lifetime = context.lifetime(buffer)
  local function current()
    return context == active
      and (command or context.eligible(buffer))
      and context.lifetime(buffer) == captured_lifetime
      and valid()
      and vim.api.nvim_buf_is_valid(buffer)
      and vim.api.nvim_buf_get_name(buffer) == name
  end
  local delivered = false
  local function resolved(directory)
    if delivered or not current() then
      return
    end
    delivered = true
    if context.native_cmd then
      callback(nil, directory)
    else
      Server.resolve(context.server, function(err, argv, version)
        if not current() then
          return
        end
        if not err then
          context.launch = { argv = argv, version = version }
        end
        callback(err, directory)
      end)
    end
  end
  if type(context.root_dir) == "function" then
    local success, failure = pcall(context.root_dir, buffer, resolved)
    if not success and not delivered then
      callback(failure)
    end
  elseif context.root_dir then
    resolved(context.root_dir)
  else
    resolved(context.default_root(buffer))
  end
end

function M.prepare(callback)
  local context = active
  if context.native_cmd then
    callback()
    return
  end
  Server.resolve(context.server, function(err, argv, version)
    if context ~= active then
      return
    end
    if not err then
      context.launch = { argv = argv, version = version }
    end
    callback(err)
  end)
end

function M.acquisition()
  return active and active.native_cmd and { state = "external" } or Server.status()
end

function M.setup(options, eligible, default_root, lifetime)
  local config = vim.lsp.config.venue_reader or {}
  if config.venue_reader_owner == owner then
    assert(M.check(config), "Register structural LSP overrides before venue-reader.setup()")
  else
    -- A reloaded module finds the previous instance's hooks; reuse that user snapshot.
    original = vim.deepcopy(config.venue_reader_original or config)
  end
  for method, handler in pairs({
    ["workspace/configuration"] = Commands.configuration,
    ["textDocument/inlayHint"] = Summaries.handler,
  }) do
    local custom = (original.handlers or {})[method]
    assert(custom == nil or custom == handler, method .. " is required by venue-reader")
  end
  local user = original
  summary = vim.deepcopy(options.summary)
  local context = {
    server = vim.deepcopy(options.server),
    native_cmd = user.cmd,
    root_dir = user.root_dir,
    eligible = eligible,
    default_root = default_root,
    lifetime = lifetime,
  }
  if
    active
    and active.native_cmd == context.native_cmd
    and active.root_dir == context.root_dir
    and vim.deep_equal(active.server, context.server)
  then
    context = active
  end
  active = context
  local registered = vim.tbl_deep_extend("keep", vim.deepcopy(original), {
    filetypes = { "fix" },
    exit_timeout = 1000,
    capabilities = Capabilities,
  })
  registered.settings = config.settings or {}
  registered.venue_reader_owner = owner
  registered.venue_reader_original = vim.deepcopy(original)
  registered.handlers = registered.handlers or {}
  registered.handlers["workspace/configuration"] = Commands.configuration
  registered.handlers["textDocument/inlayHint"] = Summaries.handler
  registered.before_init = function(params, client_config)
    local initial = client_config.settings
    local success, failure = pcall(function()
      if user.before_init then
        user.before_init(params, client_config)
      end
      local result = prepared(client_config.settings, summary)
      -- Neovim captured this table before before_init was invoked.
      for key in pairs(initial) do
        initial[key] = nil
      end
      for key, value in pairs(result) do
        initial[key] = value
      end
      client_config.settings = initial
      Commands.before_init(params, client_config)
    end)
    if not success then
      client_config.venue_reader_failure = tostring(failure)
    end
  end
  registered.on_init = function(client, result)
    if context.native_cmd then
      local version = client.server_info and client.server_info.version
      local series = type(version) == "string" and version:match("^(%d+%.%d+)%.%d+$")
      if series ~= Release.series then
        client.config.venue_reader_failure = "Unsupported native server version: "
          .. tostring(version)
          .. "; expected "
          .. Release.series
          .. ".x"
        notify(client.config.venue_reader_failure)
        client:stop(true)
        return
      end
    end
    callbacks(user.on_init, client, result)
    update(client)
    vim.lsp.codelens.enable(summary.mode == "codelens", { client_id = client.id })
  end
  registered.on_exit = function(code, signal, client_id)
    Commands.closed(client_id)
    callbacks(user.on_exit, code, signal, client_id)
  end
  registered.root_dir = function(buffer, on_dir)
    M.resolve(buffer, false, function()
      return context == active and vim.lsp.is_enabled("venue_reader")
    end, function(err, directory)
      if err then
        notify(err)
      else
        on_dir(directory)
      end
    end)
  end
  registered.cmd = function(dispatchers, client_config)
    assert(
      client_config.venue_reader_command_only or vim.lsp.is_enabled("venue_reader"),
      "Venue Reader was disabled during startup"
    )
    local launch_context = client_config.venue_reader_started and active or context
    assert(launch_context == active, "Venue Reader startup configuration changed; retry startup")
    assert(M.check(client_config), "Register structural LSP overrides before venue-reader.setup()")
    local settings = client_config.settings
    -- client_config is a copy taken at enable time or the previous client's config on restart.
    local result = prepared((vim.lsp.config.venue_reader or {}).settings, summary)
    for key in pairs(settings) do
      settings[key] = nil
    end
    for key, value in pairs(result) do
      settings[key] = value
    end
    local command = launch_context.native_cmd
      or assert(launch_context.launch, "Runtime not ready; use :VenueReader restart").argv
    client_config.venue_reader_started = true
    client_config.venue_reader_argv = type(command) == "table" and vim.deepcopy(command) or nil
    client_config.venue_reader_transport = type(command) == "function" and "function" or "stdio"
    local rpc
    if type(command) == "function" then
      rpc = command(dispatchers, client_config)
    else
      rpc = vim.lsp.rpc.start(command, dispatchers, {
        cwd = client_config.cmd_cwd,
        env = client_config.cmd_env,
        detached = client_config.detached,
      })
    end
    local request = rpc.request
    rpc.request = function(method, ...)
      if method == "initialize" and client_config.venue_reader_failure then
        notify(client_config.venue_reader_failure)
        vim.schedule(function()
          rpc.terminate()
        end)
        return false
      end
      return request(method, ...)
    end
    return rpc
  end
  registered.venue_reader_hooks = {
    before_init = registered.before_init,
    on_init = registered.on_init,
    on_exit = registered.on_exit,
  }
  vim.lsp.config("venue_reader", registered)
  for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader", _uninitialized = true })) do
    if M.managed(client) then
      update(client)
    end
  end
end

return M

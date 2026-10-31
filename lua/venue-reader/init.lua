local M = {}
local Server = require("venue-reader.server")
local options
local sessions = {}
local generations = {}
local owned = {}
local owner_marker = tostring(M)

local function owner(client)
  return owned[client.id]
    or (
      client.config.venue_reader_owner == owner_marker and sessions[client.config.root_dir] or nil
    )
end
local defaults = { server = { auto_install = true }, settings = { fix = vim.empty_dict() } }

local function notify(message, level)
  vim.notify("venue-reader: " .. message, level or vim.log.levels.INFO)
end

local function eligible(buffer)
  return vim.api.nvim_buf_is_valid(buffer)
    and vim.api.nvim_buf_is_loaded(buffer)
    and vim.bo[buffer].buftype == ""
    and vim.bo[buffer].filetype == "fix"
    and vim.api.nvim_buf_get_name(buffer) ~= ""
end

local function root(buffer)
  local directory = vim.fs.dirname(vim.api.nvim_buf_get_name(buffer))
  local marker = vim.fs.find(".venue-reader.toml", { path = directory, upward = true })[1]
  return marker and vim.fs.dirname(marker) or directory
end

local function session_for(buffer)
  if not options or not eligible(buffer) then
    return
  end
  local directory = root(buffer)
  if not sessions[directory] then
    sessions[directory] =
      { root = directory, generation = 0, server = vim.deepcopy(options.server) }
  end
  return sessions[directory]
end

local function attached(session)
  local buffers = {}
  for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
    if owner(client) == session then
      for buffer in pairs(client.attached_buffers) do
        buffers[buffer] = true
      end
    end
  end
  return vim.tbl_keys(buffers)
end

local function remember_buffers(session, buffers)
  local saved = {}
  for _, buffer in ipairs(session.stopped_buffers or {}) do
    saved[buffer] = true
  end
  for _, buffer in ipairs(buffers) do
    saved[buffer] = true
  end
  session.stopped_buffers = vim.tbl_keys(saved)
end

local function report(session)
  notify(("Session %s; affected buffers: %s"):format(session.root, vim.inspect(attached(session))))
end

local function activate(buffer)
  if not eligible(buffer) then
    return
  end
  -- The native FileType callback does not run again after async acquisition or rename.
  local config = vim.lsp.config.venue_reader
  config.root_dir(buffer, function(directory)
    if not eligible(buffer) or root(buffer) ~= directory then
      return
    end
    local resolved = vim.deepcopy(config)
    resolved.root_dir = directory
    vim.lsp.start(resolved, { bufnr = buffer, reuse_client = resolved.reuse_client })
  end)
end

local function resume_restart(session)
  if not session.restart or next(session.transports or {}) then
    return
  end
  local waiting, generation = session.restart, session.generation
  vim.schedule(function()
    if session.restart ~= waiting or session.generation ~= generation then
      return
    end
    session.restart, session.stopped_buffers = nil, nil
    session.suppressed = false
    for _, buffer in ipairs(waiting) do
      if eligible(buffer) and root(buffer) == session.root then
        activate(buffer)
      end
    end
  end)
end

function M.start(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  local session = session_for(buffer)
  if not session then
    notify("Name a FIX buffer with :file /path/log.fix before starting", vim.log.levels.WARN)
    return
  end
  session.suppressed = false
  session.failure = nil
  report(session)
  activate(buffer)
end

function M.stop(buffer)
  local session = session_for(buffer or vim.api.nvim_get_current_buf())
  if not session then
    return
  end
  report(session)
  remember_buffers(session, attached(session))
  session.suppressed = true
  session.generation = session.generation + 1
  session.restart = nil
  for transport in pairs(session.transports or {}) do
    if transport.client then
      transport.client:stop(1000)
    else
      transport.rpc.terminate()
    end
  end
end

function M.restart(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  local session = session_for(buffer)
  if not session then
    return M.start(buffer)
  end
  remember_buffers(session, attached(session))
  local buffers = vim.deepcopy(session.stopped_buffers)
  if not vim.tbl_contains(buffers, buffer) then
    table.insert(buffers, buffer)
  end
  M.stop(buffer)
  session.server = vim.deepcopy(options.server)
  session.argv = nil
  session.restart = buffers
  resume_restart(session)
end

function M.status(buffer)
  local session = session_for(buffer or vim.api.nvim_get_current_buf())
  return {
    session = session and {
      root = session.root,
      argv = session.argv,
      version = session.version,
      suppressed = session.suppressed or false,
      failure = session.failure,
      buffers = attached(session),
    },
    acquisition = Server.status(),
    annotations = "not implemented",
    treesitter = "not managed",
  }
end

function M.install()
  Server.resolve(vim.tbl_extend("force", options.server, { auto_install = true }), function(err)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
      activate(buffer)
    end
  end, true)
end

local function settings(value)
  local result = vim.deepcopy(value)
  if next(result.fix or {}) == nil then
    result.fix = vim.empty_dict()
  end
  return result
end

function M.setup(value)
  assert(vim.fn.has("nvim-0.12") == 1, "venue-reader requires Neovim >=0.12")
  value = value or {}
  assert(value.summary == nil, "Summary modes are not implemented yet")
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(defaults), value)
  assert(type(candidate.server.auto_install) == "boolean", "server.auto_install must be boolean")
  if candidate.server.cmd then
    assert(
      type(candidate.server.cmd) == "table" and #candidate.server.cmd > 0,
      "server.cmd must be an argv list"
    )
    for _, argument in ipairs(candidate.server.cmd) do
      assert(type(argument) == "string" and argument ~= "", "server.cmd arguments must be strings")
    end
  end
  candidate.settings = settings(candidate.settings)
  local changed = options and not vim.deep_equal(options.settings, candidate.settings)
  options = candidate
  if changed then
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
      if owner(client) then
        client.settings = vim.deepcopy(options.settings)
        client:notify("workspace/didChangeConfiguration", { settings = client.settings })
      end
    end
  end
  vim.filetype.add({ extension = { fix = "fix" } })
  vim.lsp.config.venue_reader = { -- luacheck: ignore 122
    venue_reader_owner = owner_marker,
    filetypes = { "fix" },
    settings = options.settings,
    exit_timeout = 1000,
    root_dir = function(buffer, on_dir)
      if not eligible(buffer) then
        if vim.api.nvim_buf_is_valid(buffer) and vim.bo[buffer].filetype == "fix" then
          vim.notify_once("venue-reader: use :file /path/log.fix to name the buffer")
        end
        return
      end
      local session = session_for(buffer)
      if session.suppressed then
        return
      end
      local generation, lifetime = session.generation, generations[buffer]
      Server.resolve(session.server, function(err, argv, version)
        if
          not eligible(buffer)
          or generations[buffer] ~= lifetime
          or root(buffer) ~= session.root
          or session.generation ~= generation
          or session.suppressed
        then
          return
        end
        if err then
          if session.failure ~= err then
            notify(err, vim.log.levels.ERROR)
          end
          session.failure = err
          return
        end
        session.argv, session.version, session.failure = argv, version, nil
        on_dir(session.root)
      end)
    end,
    cmd = function(dispatchers, config)
      local session = sessions[config.root_dir]
      if not session or session.suppressed or not session.argv then
        vim.schedule(function()
          dispatchers.on_exit(0, 0)
        end)
        return {
          request = function()
            return false
          end,
          notify = function()
            return false
          end,
          is_closing = function()
            return true
          end,
          terminate = function() end,
        }
      end
      local transport = {}
      session.transports = session.transports or {}
      session.transports[transport] = true
      local wrapped = vim.tbl_extend("force", dispatchers, {
        on_exit = function(code, signal)
          if transport.client then
            remember_buffers(session, vim.tbl_keys(transport.client.attached_buffers))
            owned[transport.client.id] = nil
          end
          session.transports[transport] = nil
          if not session.suppressed then
            session.suppressed = true
            session.generation = session.generation + 1
            if code ~= 0 or (signal ~= 0 and signal ~= 15) then
              session.failure = (
                "Server exited (%d, signal %d); use :VenueReader restart. " .. "Log: %s"
              ):format(code, signal, vim.lsp.log.get_filename())
              vim.schedule(function()
                notify(session.failure, vim.log.levels.ERROR)
              end)
            end
          end
          dispatchers.on_exit(code, signal)
          resume_restart(session)
        end,
      })
      session.mark_initialized = function(client)
        transport.client = client
      end
      local ok, rpc = pcall(vim.lsp.rpc.start, session.argv, wrapped)
      if not ok then
        session.transports[transport] = nil
        error(rpc)
      end
      transport.rpc = rpc
      return rpc
    end,
    reuse_client = function(client, config)
      return owner(client) == sessions[config.root_dir] and not client:is_stopped()
    end,
    handlers = {
      ["workspace/inlayHint/refresh"] = function()
        return vim.NIL
      end,
      ["workspace/semanticTokens/refresh"] = function()
        return vim.NIL
      end,
    },
    on_init = function(client)
      local session = sessions[client.config.root_dir]
      owned[client.id] = session
      if session.mark_initialized then
        session.mark_initialized(client)
      end
      client.venue_reader_inlay_provider = client.server_capabilities.inlayHintProvider
      client.server_capabilities.inlayHintProvider = nil
      vim.lsp.semantic_tokens.enable(false, { client_id = client.id })
      vim.lsp.codelens.enable(false, { client_id = client.id })
      if not client.server_capabilities.hoverProvider then
        notify("Server does not advertise hover; check binary compatibility", vim.log.levels.WARN)
      end
    end,
  }
  local group = vim.api.nvim_create_augroup("venue-reader", { clear = true })
  vim.api.nvim_create_autocmd("BufFilePre", {
    group = group,
    callback = function(event)
      generations[event.buf] = (generations[event.buf] or 0) + 1
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = event.buf })) do
        if owner(client) then
          vim.lsp.buf_detach_client(event.buf, client.id)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePost", {
    group = group,
    callback = function(event)
      activate(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      generations[event.buf] = nil
    end,
  })
  vim.api.nvim_create_user_command("VenueReader", function(command)
    local action = command.fargs[1]
    if action == "status" then
      notify(vim.inspect(M.status()))
    elseif action == "install" and command.fargs[2] == "server" then
      M.install()
    elseif action == "start" or action == "stop" or action == "restart" then
      M[action]()
    else
      notify("Use start, stop, restart, status or install server", vim.log.levels.ERROR)
    end
  end, {
    nargs = "+",
    force = true,
    complete = function()
      return { "start", "stop", "restart", "status", "install server" }
    end,
  })
  vim.lsp.enable("venue_reader")
end

return M

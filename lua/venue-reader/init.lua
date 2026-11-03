local M = {}

local Commands = require("venue-reader.commands")
local Highlights = require("venue-reader.highlights")
local Server = require("venue-reader.server")
local Summaries = require("venue-reader.summaries")
local Yank = require("venue-reader.yank")

local options
local ready
local generation = 0
local lifetimes = {}
local owner_marker = tostring(M)
local defaults = {
  server = { auto_install = true },
  commands = { timeout_ms = 5000 },
  settings = { fix = vim.empty_dict() },
  summary = { mode = "front", highlight = "VenueReaderSummary" },
}

local function managed(client)
  return client.config.venue_reader_owner == owner_marker
end

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
  return vim.fs.root(directory, ".venue-reader.toml") or directory
end

local function context_root(buffer)
  if eligible(buffer) then
    return root(buffer)
  end
  local directory = vim.fn.getcwd()
  return vim.fs.root(directory, ".venue-reader.toml") or directory
end

local function selected_client(buffer)
  for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader", bufnr = buffer })) do
    if managed(client) and not client:is_stopped() then
      return client
    end
  end
  local directory = context_root(buffer)
  for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
    if managed(client) and not client:is_stopped() and client.config.root_dir == directory then
      return client
    end
  end
end

local function acquire(buffer, document_required, callback)
  if not vim.api.nvim_buf_is_valid(buffer) then
    callback("The command buffer is no longer available")
    return
  end
  local directory, captured = context_root(buffer), generation
  local function current()
    return generation == captured
      and vim.api.nvim_buf_is_valid(buffer)
      and context_root(buffer) == directory
  end
  local client = selected_client(buffer)
  if document_required then
    if not eligible(buffer) or not client or not vim.lsp.buf_is_attached(buffer, client.id) then
      callback("Open a named FIX buffer and wait for its native LSP attachment")
    else
      callback(nil, client, current)
    end
    return
  end
  if client then
    callback(nil, client, current)
    return
  end
  Server.resolve(options.server, function(err, argv, version)
    if not current() then
      callback("Command context changed during server discovery")
      return
    end
    if err then
      callback(err)
      return
    end
    ready = { argv = argv, version = version }
    local config = vim.deepcopy(vim.lsp.config.venue_reader)
    config.root_dir = directory
    local client_id = vim.lsp.start(config, {
      bufnr = buffer,
      attach = false,
      reuse_client = function(existing, candidate)
        return managed(existing)
          and not existing:is_stopped()
          and existing.name == candidate.name
          and existing.config.root_dir == candidate.root_dir
      end,
    })
    if not client_id then
      callback("Native LSP startup failed")
      return
    end
    callback(nil, vim.lsp.get_client_by_id(client_id), current)
  end)
end

local function activate(buffer)
  if not eligible(buffer) or not vim.lsp.is_enabled("venue_reader") then
    return
  end
  local config = vim.lsp.config.venue_reader
  config.root_dir(buffer, function(directory)
    if not eligible(buffer) or root(buffer) ~= directory then
      return
    end
    local resolved = vim.deepcopy(config)
    resolved.root_dir = directory
    vim.lsp.start(resolved, { bufnr = buffer })
  end)
end

function M.start()
  vim.cmd("lsp enable venue_reader")
end

function M.stop()
  vim.cmd("lsp stop venue_reader")
end

function M.restart()
  Server.resolve(options.server, function(err, argv, version)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    ready = { argv = argv, version = version }
    if #vim.lsp.get_clients({ name = "venue_reader" }) == 0 then
      M.start()
    else
      vim.cmd("lsp restart venue_reader")
    end
  end)
end

function M.status(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  local client = selected_client(buffer)
  return {
    enabled = vim.lsp.is_enabled("venue_reader"),
    session = client and {
      root = client.config.root_dir,
      argv = client.config.venue_reader_argv,
      version = client.server_info and client.server_info.version,
      buffers = vim.tbl_keys(client.attached_buffers),
    },
    acquisition = Server.status(),
    annotations = Summaries.status(buffer, client and client.id),
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

function M.summary(mode)
  local updated = vim.deepcopy(options)
  updated.summary.mode = mode
  updated.settings.fix.messageSummary.channels = nil
  local changed = M.setup(updated)
  if not changed then
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
      if managed(client) then
        for buffer in pairs(client.attached_buffers) do
          Summaries.attach(client, buffer)
        end
      end
    end
  end
end

function M.yank(value)
  return Yank.run(value)
end

function M.operator()
  return Yank.operator()
end

function M.dictionary(name)
  return Commands.dictionary(name)
end

function M.settings()
  return Commands.settings()
end

function M.tag(number, value)
  return Commands.tag(number, value)
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
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(defaults), value)
  assert(type(candidate.server.auto_install) == "boolean", "server.auto_install must be boolean")
  assert(type(candidate.commands) == "table", "commands must be a table")
  local timeout = candidate.commands.timeout_ms
  assert(
    type(timeout) == "number" and timeout > 0 and timeout < math.huge and timeout % 1 == 0,
    "commands.timeout_ms must be a finite positive integer"
  )
  if candidate.server.cmd then
    assert(
      vim.islist(candidate.server.cmd) and #candidate.server.cmd > 0,
      "server.cmd must be an argv list"
    )
    for _, argument in ipairs(candidate.server.cmd) do
      assert(type(argument) == "string" and argument ~= "", "server.cmd arguments must be strings")
    end
  end
  candidate.settings = settings(Summaries.settings(candidate.summary, candidate.settings))
  Highlights.setup()
  local mode_changed = Summaries.configure(candidate.summary, managed)
  local changed = options and not vim.deep_equal(options.settings, candidate.settings)
  generation = generation + 1
  options = candidate
  Commands.setup(options.commands, acquire, managed)
  if changed then
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
      if managed(client) then
        client.settings = vim.deepcopy(options.settings)
        client.config.settings = vim.deepcopy(options.settings)
        client:notify("workspace/didChangeConfiguration", { settings = client.settings })
      end
    end
  end
  if mode_changed then
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
      if managed(client) then
        for buffer in pairs(client.attached_buffers) do
          Summaries.attach(client, buffer)
        end
      end
    end
  end
  vim.filetype.add({ extension = { fix = "fix" } })
  vim.lsp.config.venue_reader = { -- luacheck: ignore 122
    venue_reader_owner = owner_marker,
    filetypes = { "fix" },
    settings = options.settings,
    exit_timeout = 1000,
    before_init = Commands.before_init,
    handlers = {
      ["textDocument/inlayHint"] = Summaries.handler,
      ["workspace/configuration"] = Commands.configuration,
    },
    on_exit = function(_, _, client_id)
      Commands.closed(client_id)
    end,
    on_init = function(client)
      if not vim.deep_equal(client.settings, options.settings) then
        client.settings = vim.deepcopy(options.settings)
        client.config.settings = vim.deepcopy(options.settings)
        client:notify("workspace/didChangeConfiguration", { settings = client.settings })
      end
      vim.lsp.codelens.enable(options.summary.mode == "codelens", { client_id = client.id })
    end,
    root_dir = function(buffer, on_dir)
      if not eligible(buffer) then
        if vim.api.nvim_buf_is_valid(buffer) and vim.bo[buffer].filetype == "fix" then
          vim.notify_once("venue-reader: use :file /path/log.fix to name the buffer")
        end
        return
      end
      local directory = root(buffer)
      local captured_generation, lifetime = generation, lifetimes[buffer]
      Server.resolve(options.server, function(err, argv, version)
        if
          not eligible(buffer)
          or lifetimes[buffer] ~= lifetime
          or root(buffer) ~= directory
          or generation ~= captured_generation
          or not vim.lsp.is_enabled("venue_reader")
        then
          return
        end
        if err then
          notify(err, vim.log.levels.ERROR)
          return
        end
        ready = { argv = argv, version = version }
        on_dir(directory)
      end)
    end,
    cmd = function(dispatchers, config)
      config.venue_reader_argv = vim.deepcopy(assert(ready, "Server discovery is not ready").argv)
      return vim.lsp.rpc.start(config.venue_reader_argv, dispatchers)
    end,
  }
  local group = vim.api.nvim_create_augroup("venue-reader", { clear = true })
  vim.api.nvim_create_autocmd("BufFilePre", {
    group = group,
    callback = function(event)
      lifetimes[event.buf] = (lifetimes[event.buf] or 0) + 1
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = event.buf })) do
        if managed(client) then
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
      lifetimes[event.buf] = nil
    end,
  })
  vim.keymap.set("n", "<Plug>(VenueReaderYank)", M.operator, {
    expr = true,
    desc = "Decode a FIX selection to a register",
  })
  vim.keymap.set(
    "x",
    "<Plug>(VenueReaderYank)",
    "<Cmd>lua require('venue-reader').yank({ mode = 'visual', mapping = true })<CR>",
    { desc = "Decode the FIX selection to a register" }
  )
  vim.api.nvim_create_user_command("VenueReader", function(command)
    local success, failure = pcall(function()
      local arguments = command.fargs
      local action = arguments[1]
      assert(action == "yank" or command.range == 0, "Only yank accepts a line range")
      if action == "yank" then
        assert(#arguments <= 2, "Use yank [register]")
        local selection = { register = arguments[2] }
        if command.range > 0 then
          selection.mode, selection.first, selection.last = "line", command.line1, command.line2
        end
        M.yank(selection)
      elseif action == "dictionary" then
        assert(#arguments <= 2, "Use dictionary [name]")
        M.dictionary(arguments[2])
      elseif action == "tag" then
        assert(#arguments >= 2 and #arguments <= 3, "Use tag <number> [value]")
        M.tag(arguments[2], arguments[3])
      elseif action == "summary" then
        assert(#arguments == 2, "Use summary front|above|codelens|off")
        M.summary(arguments[2])
      elseif action == "install" then
        assert(#arguments == 2 and arguments[2] == "server", "Use install server")
        M.install()
      elseif action == "status" then
        assert(#arguments == 1, "Use status")
        notify(vim.inspect(M.status()))
      elseif
        action == "start"
        or action == "stop"
        or action == "restart"
        or action == "settings"
      then
        assert(#arguments == 1, action .. " takes no arguments")
        M[action]()
      else
        error(
          "Use start, stop, restart, status, summary, yank, dictionary, settings, tag"
            .. " or install server"
        )
      end
    end)
    if not success then
      notify(tostring(failure), vim.log.levels.ERROR)
    end
  end, {
    nargs = "+",
    range = true,
    force = true,
    complete = function()
      return {
        "start",
        "stop",
        "restart",
        "status",
        "install server",
        "summary front",
        "summary above",
        "summary codelens",
        "summary off",
        "yank",
        "dictionary",
        "settings",
        "tag",
      }
    end,
  })
  vim.lsp.enable("venue_reader")
  return mode_changed
end

return M

-- TODO: Remove this compatibility guard after 2027-02-05.
if vim.g.fix_plugin_owner == "fix.nvim" then
  vim.notify_once(
    "venue-reader.nvim is disabled because fix.nvim is already loaded.",
    vim.log.levels.WARN
  )
  return { setup = function() end }
end
vim.g.fix_plugin_owner = "venue-reader.nvim" -- luacheck: ignore 122

local M = {}

local Native = require("venue-reader.native")
local Commands = require("venue-reader.commands")
local Highlights = require("venue-reader.highlights")
local Server = require("venue-reader.server")
local Summaries = require("venue-reader.summaries")
local Treesitter = require("venue-reader.treesitter")
local Yank = require("venue-reader.yank")

local options
local generation = 0
local lifetimes = {}
local command_clients = {}

local defaults = {
  server = { auto_install = true },
  commands = { timeout_ms = 5000 },
  symbols = { enabled = true, timeout_ms = 30000 },
  treesitter = { enabled = true, auto_install = true },
  summary = { mode = "front", semantic_highlighting = true },
}

local function managed(client)
  return Native.managed(client)
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
  for _, client in ipairs(vim.lsp.get_clients({ name = "venue-reader", bufnr = buffer })) do
    if managed(client) and not client:is_stopped() then
      return client
    end
  end
  local known = command_clients[buffer]
  local client = known and vim.lsp.get_client_by_id(known.id)
  if
    client
    and managed(client)
    and not client:is_stopped()
    and known.name == vim.api.nvim_buf_get_name(buffer)
    and known.directory == vim.fn.getcwd()
  then
    return client
  end
end

local function acquire(buffer, document_required, callback, valid)
  if not vim.api.nvim_buf_is_valid(buffer) then
    callback("The command buffer is no longer available")
    return
  end
  local captured, name, directory = generation, vim.api.nvim_buf_get_name(buffer), vim.fn.getcwd()
  local function current()
    return generation == captured
      and vim.api.nvim_buf_is_valid(buffer)
      and vim.api.nvim_buf_get_name(buffer) == name
      and vim.fn.getcwd() == directory
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
  local config = vim.deepcopy(vim.lsp.config["venue-reader"])
  config.venue_reader_command_only = true
  Native.resolve(buffer, true, function()
    return current() and valid()
  end, function(err, resolved_root)
    if not current() or not valid() then
      return
    end
    if err then
      callback(err)
      return
    end
    config.root_dir = resolved_root
    local success, client_id = pcall(vim.lsp.start, config, {
      bufnr = buffer,
      attach = false,
      reuse_client = function(existing, candidate)
        return managed(existing)
          and not existing:is_stopped()
          and existing.name == candidate.name
          and existing.config.root_dir == candidate.root_dir
      end,
    })
    if not success or not client_id then
      callback(success and "Native LSP startup failed" or client_id)
      return
    end
    command_clients[buffer] = { id = client_id, name = name, directory = directory }
    callback(nil, vim.lsp.get_client_by_id(client_id), current)
  end)
end

local function activate(buffer)
  if not eligible(buffer) or not vim.lsp.is_enabled("venue-reader") then
    return
  end
  local config = vim.lsp.config["venue-reader"]
  config.root_dir(buffer, function(directory)
    if not eligible(buffer) then
      return
    end
    local resolved = vim.deepcopy(config)
    resolved.root_dir = directory
    vim.lsp.start(resolved, { bufnr = buffer })
  end)
end

function M.start()
  vim.cmd("lsp enable venue-reader")
end

function M.stop()
  vim.cmd("lsp stop venue-reader")
end

function M.restart()
  Native.prepare(function(err)
    if err then
      notify(err, vim.log.levels.ERROR)
    elseif #vim.lsp.get_clients({ name = "venue-reader" }) == 0 then
      M.start()
    else
      vim.cmd("lsp restart venue-reader")
    end
  end)
end

function M.status(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  local client = selected_client(buffer)
  return {
    enabled = vim.lsp.is_enabled("venue-reader"),
    session = client and {
      root = client.config.root_dir,
      argv = client.config.venue_reader_argv,
      transport = client.config.venue_reader_transport,
      version = client.server_info and client.server_info.version,
      buffers = vim.tbl_keys(client.attached_buffers),
    },
    symbols = { enabled = not options or options.symbols.enabled },
    acquisition = Native.acquisition(),
    annotations = Summaries.status(buffer, client and client.id),
    treesitter = Treesitter.status(buffer),
  }
end

function M.install(target)
  target = target or "server"
  assert(target == "server" or target == "grammar", "Use install server|grammar")
  if target == "grammar" then
    return Treesitter.install()
  end
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

function M.current_summary(value)
  return Summaries.current_summary(value)
end

function M.summary(mode)
  local updated = vim.deepcopy(options)
  updated.summary.mode = mode
  local changed = M.setup(updated)
  if not changed then
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue-reader" })) do
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

function M.symbols(value)
  assert(
    not options or options.symbols.enabled,
    "Symbol picker is disabled (symbols.enabled = false)"
  )
  local opts = vim.tbl_extend("force", {}, options and options.symbols or {}, value or {})
  local buffer = opts.bufnr or vim.api.nvim_get_current_buf()
  local client = selected_client(buffer)
  assert(
    eligible(buffer) and client,
    "Open a named FIX buffer with an attached Venue Reader client"
  )
  return require("venue-reader.symbols").open(client, buffer, opts)
end

function M.textobject(kind)
  return Treesitter.textobject(kind)
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

function M.setup(value)
  assert(vim.fn.has("nvim-0.12") == 1, "venue-reader requires Neovim >=0.12")
  value = value or {}
  assert(value.runtime == nil, "Use server instead of runtime")
  assert(value.settings == nil, "Use vim.lsp.config('venue-reader', { settings = ... })")
  local candidate = vim.tbl_deep_extend("force", vim.deepcopy(defaults), value)
  assert(type(candidate.symbols) == "table", "symbols must be a table")
  assert(type(candidate.symbols.enabled) == "boolean", "symbols.enabled must be boolean")
  local symbol_timeout = candidate.symbols.timeout_ms
  assert(
    type(symbol_timeout) == "number"
      and symbol_timeout >= 0
      and symbol_timeout < math.huge
      and symbol_timeout % 1 == 0,
    "symbols.timeout_ms must be a finite non-negative integer"
  )
  assert(type(candidate.server.auto_install) == "boolean", "server.auto_install must be boolean")
  assert(type(candidate.treesitter) == "table", "treesitter must be a table")
  assert(
    type(candidate.treesitter.enabled) == "boolean"
      or type(candidate.treesitter.enabled) == "function",
    "treesitter.enabled must be boolean or a function"
  )
  assert(
    type(candidate.treesitter.auto_install) == "boolean",
    "treesitter.auto_install must be boolean"
  )
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
  Summaries.settings(candidate.summary, {})
  Highlights.setup()
  local mode_changed = Summaries.configure(candidate.summary, managed)
  generation = generation + 1
  options = candidate
  Commands.setup(options.commands, acquire, managed)
  Native.setup(options, eligible, context_root, function(buffer)
    return lifetimes[buffer]
  end)
  if mode_changed then
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue-reader" })) do
      if managed(client) then
        for buffer in pairs(client.attached_buffers) do
          Summaries.attach(client, buffer)
        end
      end
    end
  end
  vim.filetype.add({ extension = { fix = "fix" } })
  local group = vim.api.nvim_create_augroup("venue-reader", { clear = true })
  vim.api.nvim_create_autocmd("LspAttach", {
    group = group,
    callback = function(event)
      local client = vim.lsp.get_client_by_id(event.data.client_id)
      if client and client.name == "venue-reader" and not Native.check(client.config) then
        notify(
          "Required adapter hooks were replaced; register structural overrides before setup",
          vim.log.levels.ERROR
        )
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufFilePre", {
    group = group,
    callback = function(event)
      lifetimes[event.buf] = (lifetimes[event.buf] or 0) + 1
      command_clients[event.buf] = nil
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
      command_clients[event.buf] = nil
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
  for _, kind in ipairs({ "Tag", "Value", "Field", "Message", "Comment" }) do
    vim.keymap.set({ "x", "o" }, "<Plug>(VenueReader" .. kind .. ")", function()
      M.textobject(kind:lower())
    end, { desc = "Select FIX " .. kind:lower() })
  end
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
        assert(#arguments == 2, "Use summary front|above|hidden|codelens|off")
        M.summary(arguments[2])
      elseif action == "install" then
        assert(#arguments == 2, "Use install server|grammar")
        M.install(arguments[2])
      elseif action == "status" then
        assert(#arguments == 1, "Use status")
        notify(vim.inspect(M.status()))
      elseif
        action == "start"
        or action == "stop"
        or action == "restart"
        or action == "settings"
        or action == "symbols"
      then
        assert(#arguments == 1, action .. " takes no arguments")
        M[action]()
      else
        error(
          "Use start, stop, restart, status, summary"
            .. (options.symbols.enabled and ", symbols" or "")
            .. ", yank, dictionary, settings, tag"
            .. " or install server|grammar"
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
      local commands = {
        "start",
        "stop",
        "restart",
        "status",
        "install server",
        "install grammar",
        "summary front",
        "summary above",
        "summary hidden",
        "summary codelens",
        "summary off",
        "yank",
        "dictionary",
        "settings",
        "tag",
      }
      if options.symbols.enabled then
        commands[#commands + 1] = "symbols"
      end
      return commands
    end,
  })
  vim.lsp.enable("venue-reader")
  Treesitter.setup(options.treesitter)
  return mode_changed
end

return M

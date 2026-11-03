local M = {}

local directory = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local options = { enabled = true, auto_install = true }
local buffers = {}
local acquisition = { state = "unchecked" }
local recipe
local external_recipe
local captures = { tag = true, value = true, field = true, message = true, comment = true }

local function available(module)
  local path = module:gsub("%.", "/")
  return package.loaded[module] ~= nil
    or package.preload[module] ~= nil
    or #vim.api.nvim_get_runtime_file("lua/" .. path .. ".lua", false) > 0
    or #vim.api.nvim_get_runtime_file("lua/" .. path .. "/init.lua", false) > 0
end

local function normal_fix(buffer)
  return vim.api.nvim_buf_is_valid(buffer)
    and vim.api.nvim_buf_is_loaded(buffer)
    and vim.bo[buffer].buftype == ""
    and vim.bo[buffer].filetype == "fix"
end

local function eligible(buffer)
  if not normal_fix(buffer) or vim.b[buffer].venue_reader_treesitter == false then
    return false
  end
  if type(options.enabled) == "function" then
    local success, enabled = pcall(options.enabled, buffer)
    if not success then
      return false, "Tree-sitter predicate failed: " .. tostring(enabled)
    end
    return enabled == true
  end
  return options.enabled
end

local function warning(message, once)
  local notify = once and vim.notify_once or vim.notify
  notify("venue-reader: " .. message, vim.log.levels.WARN)
end

local function fail(message)
  message = tostring(message)
  if acquisition.state ~= "failed" or acquisition.error ~= message then
    warning(message .. "; use :VenueReader install grammar to retry")
  end
  acquisition = { state = "failed", error = message }
end

local function parser_file()
  return #vim.api.nvim_get_runtime_file("parser/fix.*", false) > 0
end

local function load_parser()
  local success, loaded, reason = pcall(vim.treesitter.language.add, "fix")
  if not success or not loaded then
    if parser_file() then
      fail(
        "Cannot load the FIX parser: "
          .. tostring(success and reason or loaded)
          .. ". Repair the parser manually and restart Neovim"
      )
    else
      acquisition = { state = "missing" }
    end
    return false
  end
  local compatible, error = pcall(function()
    assert(vim.treesitter.query.get("fix", "highlights"), "FIX highlights query is missing")
  end)
  if not compatible then
    fail(
      "Incompatible FIX parser or queries: "
        .. tostring(error)
        .. ". Repair them manually and restart Neovim"
    )
    return false
  end
  acquisition = { state = "ready" }
  return true
end

local function register()
  local parsers = require("nvim-treesitter.parsers")
  if not recipe then
    local manifest =
      vim.json.decode(table.concat(vim.fn.readfile(directory .. "/grammar.json"), "\n"))
    recipe = { install_info = { url = manifest.repository, revision = manifest.commit } }
  end
  if parsers.fix and parsers.fix ~= recipe and parsers.fix ~= external_recipe then
    external_recipe = parsers.fix
  elseif not parsers.fix then
    parsers.fix = external_recipe or recipe
  end
end

local function stop(buffer, buffer_state)
  if buffer_state and buffer_state.started and vim.api.nvim_buf_is_loaded(buffer) then
    pcall(vim.treesitter.stop, buffer)
    buffer_state.started = false
  end
end

local function activate(buffer)
  local buffer_state = buffers[buffer]
  if not normal_fix(buffer) then
    stop(buffer, buffer_state)
    buffers[buffer] = nil
    return
  end
  local allowed, error = eligible(buffer)
  if not allowed then
    stop(buffer, buffer_state)
    if error then
      warning(error, true)
    end
    return
  end
  if buffer_state and (buffer_state.observed or buffer_state.error) then
    return
  end
  if not buffer_state then
    buffer_state = {}
    buffers[buffer] = buffer_state
  end
  if vim.b[buffer].ts_highlight then
    buffer_state.observed = true
    return
  end
  if acquisition.state ~= "ready" then
    return
  end
  local success, reason = pcall(vim.treesitter.start, buffer, "fix")
  buffer_state.observed = success
  buffer_state.error = not success and tostring(reason) or nil
  buffer_state.started = success
  if not success then
    warning("Cannot start FIX highlighting: " .. tostring(reason), true)
  end
end

local function activate_all()
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    activate(buffer)
  end
end

local function acquire(retry)
  if acquisition.state == "installing" then
    return
  end
  if acquisition.state == "failed" and not retry then
    return
  end
  if retry then
    acquisition = { state = "unchecked" }
  end
  if acquisition.state == "ready" or load_parser() then
    activate_all()
    return
  end
  if acquisition.state == "failed" or (not options.auto_install and not retry) then
    return
  end
  acquisition = { state = "installing" }
  local success, error = pcall(function()
    local loaded, manager = pcall(require, "nvim-treesitter")
    assert(loaded, "nvim-treesitter main is unavailable; install or load it first")
    assert(type(manager.install) == "function", "nvim-treesitter main with install() is required")
    register()
    manager.install({ "fix" }):await(function(err, installed)
      vim.schedule(function()
        if err or not installed then
          fail("FIX grammar installation failed: " .. tostring(err or "see :TSLog for details"))
        else
          -- Neovim may have cached the install directory before it existed.
          vim.api.nvim_set_option_value("runtimepath", vim.o.runtimepath, {})
          if load_parser() then
            activate_all()
          elseif acquisition.state ~= "failed" then
            fail(
              "The installer finished without a loadable FIX parser. Check :TSLog and repair"
                .. " query-only or incomplete installations manually"
            )
          end
        end
      end)
    end)
  end)
  if not success then
    fail("FIX grammar installation unavailable: " .. tostring(error))
  end
end

local function enter(buffer)
  activate(buffer)
  if eligible(buffer) and not (buffers[buffer] or {}).observed then
    acquire(false)
  end
end

function M.setup(value)
  options = value
  local group = vim.api.nvim_create_augroup("venue-reader.treesitter", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "TSUpdate",
    callback = function()
      local success, error = pcall(register)
      if not success then
        fail("Cannot register the FIX parser: " .. tostring(error))
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "FileType", "BufReadPost" }, {
    group = group,
    callback = function(event)
      enter(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(event)
      if not eligible(event.buf) then
        stop(event.buf, buffers[event.buf])
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    callback = function(event)
      buffers[event.buf] = nil
    end,
  })
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    enter(buffer)
  end
end

function M.install()
  for _, buffer_state in pairs(buffers) do
    buffer_state.error = nil
  end
  acquire(true)
end

function M.textobject(kind)
  assert(captures[kind], "Unknown Tree-sitter textobject: " .. tostring(kind))
  local buffer = vim.api.nvim_get_current_buf()
  if not eligible(buffer) then
    warning("Tree-sitter textobjects are disabled for this buffer", true)
    return false
  end
  if
    acquisition.state ~= "ready"
    and (acquisition.state == "installing" or acquisition.state == "failed" or not load_parser())
  then
    warning(
      "A compatible FIX parser is required for textobjects; use :VenueReader install grammar",
      true
    )
    return false
  end
  local loaded, selection = pcall(require, "nvim-treesitter-textobjects.select")
  if not loaded or type(selection.select_textobject) ~= "function" then
    warning(
      "FIX textobjects require nvim-treesitter-textobjects main; install or load it first",
      true
    )
    return false
  end
  local success, error = pcall(selection.select_textobject, "@" .. kind, "textobjects")
  if not success then
    warning("FIX textobject selection failed: " .. tostring(error), true)
  end
  return success
end

function M.status(buffer)
  local result = vim.deepcopy(acquisition)
  result.parser_available = acquisition.state == "ready" or parser_file()
  result.manager_available = available("nvim-treesitter")
  result.textobjects_available = available("nvim-treesitter-textobjects.select")
  if buffer ~= false then
    buffer = buffer or vim.api.nvim_get_current_buf()
    result.eligible = eligible(buffer)
    result.started = (buffers[buffer] or {}).started == true
    result.buffer_error = (buffers[buffer] or {}).error
    result.highlighted = vim.api.nvim_buf_is_valid(buffer) and vim.b[buffer].ts_highlight == true
  end
  return result
end

return M

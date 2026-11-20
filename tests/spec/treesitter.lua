local MiniTest = require("mini.test")
local tests = MiniTest.new_set()
local equal = MiniTest.expect.equality
local root = assert(vim.env.VENUE_READER_TEST_ROOT)

local function child(options)
  local process = MiniTest.new_child_neovim()
  process.start({ "-u", "NONE", "-i", "NONE" })
  MiniTest.finally(process.stop)
  process.lua_func(function(directory, value)
    vim.opt.runtimepath:prepend(directory)
    package.path = directory .. "/?.lua;" .. directory .. "/?/init.lua;" .. package.path
    require("tests.support.treesitter").init(directory, value)
    vim.cmd("filetype plugin on")
  end, root, options or {})
  return process
end

local function setup(process, options)
  process.lua_func(function(value)
    require("venue-reader.treesitter").setup(value)
  end, options or { enabled = true, auto_install = true })
end

local function buffer(process, lines)
  return process.lua_func(function(value)
    return require("tests.support.treesitter").buffer(value)
  end, lines)
end

local function status(process, target)
  return process.lua_func(function(value)
    return require("venue-reader.treesitter").status(value)
  end, target)
end

local function finish(process, failure, success, parser)
  process.lua_func(function(value)
    require("tests.support.treesitter").finish(value.failure, value.success, value.parser)
  end, { failure = failure, success = success, parser = parser })
end

local function await_state(process, expected)
  process.lua_func(function(value)
    require("tests.support.treesitter").wait(function()
      return require("venue-reader.treesitter").status().state == value
    end, "grammar state " .. value)
  end, expected)
end

tests["reuses a real parser for unnamed FIX syntax without a manager"] = function()
  local process = child({ parser = true })
  setup(process)
  local target = buffer(process)
  local current = status(process, target)
  equal(current.state, "ready")
  equal(current.eligible, true)
  equal(current.highlighted, true)
  equal(current.manager_available, false)
  equal(process.api.nvim_buf_get_name(target), "")
  equal(process.lua_get("package.loaded['nvim-treesitter'] == nil"), true)
end

tests["global status probes never load optional modules or parse a buffer"] = function()
  local process = child({ manager = true })
  setup(process, { enabled = false, auto_install = true })
  local current = status(process, false)
  equal(current.eligible, nil)
  equal(process.lua_get("package.loaded['nvim-treesitter'] == nil"), true)
  equal(process.lua_get("package.loaded['nvim-treesitter-textobjects.select'] == nil"), true)
  equal(process.lua_get("require('tests.support.treesitter').calls"), 0)
end

tests["one shared install survives setup changes and explicit retry joins it"] = function()
  local process = child({ manager = true })
  setup(process)
  local first, second = buffer(process), buffer(process)
  equal(status(process, first).state, "installing")
  process.lua_func(function()
    local adapter = require("venue-reader.treesitter")
    adapter.setup({
      enabled = function()
        return true
      end,
      auto_install = true,
    })
    adapter.install()
    adapter.install()
  end)
  equal(process.lua_get("require('tests.support.treesitter').calls"), 1)
  finish(process, nil, true, true)
  await_state(process, "ready")
  equal(status(process, first).highlighted, true)
  equal(status(process, second).highlighted, true)
end

tests["installation discovers a newly created site already on runtimepath"] = function()
  local process = child({ manager = true })
  local site = process.lua_func(function()
    local directory = vim.fn.stdpath("data") .. "/site"
    assert(vim.fn.isdirectory(directory) == 0)
    -- mini.test starts with --clean; restore the normal site before the first lookup.
    vim.opt.runtimepath:prepend(directory)
    return directory
  end)
  assert(vim.fs.relpath(assert(vim.env.XDG_DATA_HOME), site), "Unexpected test site: " .. site)
  MiniTest.finally(function()
    process.stop()
    vim.fn.delete(site, "rf")
  end)
  setup(process)
  local target = buffer(process)
  equal(status(process, target).state, "installing")
  process.lua_func(function(directory)
    assert(#vim.api.nvim_get_runtime_file("parser/fix.*", false) == 0)
    vim.fn.mkdir(directory .. "/parser", "p")
    local prepared = require("tests.support.treesitter").root
      .. "/.test-deps/treesitter/runtime/parser/fix.so"
    assert(vim.uv.fs_copyfile(prepared, directory .. "/parser/fix.so"))
  end, site)
  finish(process, nil, true, false)
  await_state(process, "ready")
  equal(status(process, target).highlighted, true)
end

tests["failure warns once and explicit retry activates already open buffers"] = function()
  local process = child({ manager = true })
  setup(process)
  local first, second = buffer(process), buffer(process)
  finish(process, "build tools unavailable", false, false)
  await_state(process, "failed")
  setup(process)
  buffer(process)
  equal(process.lua_get("require('tests.support.treesitter').calls"), 1)
  equal(process.lua_get("#require('tests.support.treesitter').messages"), 1)
  equal(status(process, first).highlighted, false)
  process.lua_func(function()
    require("venue-reader.treesitter").install()
  end)
  equal(process.lua_get("require('tests.support.treesitter').calls"), 2)
  finish(process, nil, true, true)
  await_state(process, "ready")
  equal(status(process, first).highlighted, true)
  equal(status(process, second).highlighted, true)
end

tests["manager success without a loadable parser stays failed"] = function()
  local process = child({ manager = true })
  setup(process)
  local target = buffer(process)
  finish(process, nil, true, false)
  await_state(process, "failed")
  equal(status(process, target).highlighted, false)
  assert(status(process, target).error)
end

tests["late manager loading requires explicit retry"] = function()
  local process = child()
  setup(process)
  local target = buffer(process)
  await_state(process, "failed")
  process.lua_func(function(directory)
    require("tests.support.treesitter").init(directory, { manager = true })
  end, root)
  setup(process)
  equal(process.lua_get("require('tests.support.treesitter').calls"), 0)
  process.lua_func(function()
    require("venue-reader.treesitter").install()
  end)
  finish(process, nil, true, true)
  await_state(process, "ready")
  equal(status(process, target).highlighted, true)
end

tests["completion rechecks deletion filetype and explicit buffer opt out"] = function()
  local process = child({ manager = true })
  setup(process)
  local deleted, changed, disabled = buffer(process), buffer(process), buffer(process)
  process.api.nvim_buf_delete(deleted, { force = true })
  process.api.nvim_set_option_value("filetype", "text", { buf = changed })
  process.api.nvim_buf_set_var(disabled, "venue_reader_treesitter", false)
  finish(process, nil, true, true)
  await_state(process, "ready")
  equal(status(process, changed).highlighted, false)
  equal(status(process, disabled).highlighted, false)
end

tests["predicate stops owned syntax and excludes textobjects without scanning"] = function()
  local process = child({ parser = true, textobjects = true })
  process.lua_func(function()
    require("venue-reader.treesitter").setup({
      enabled = function(target)
        return not vim.b[target].large_file
      end,
      auto_install = true,
    })
  end)
  local target = buffer(process)
  equal(status(process, target).highlighted, true)
  process.api.nvim_buf_set_var(target, "large_file", true)
  process.api.nvim_exec_autocmds("BufEnter", { buffer = target })
  equal(status(process, target).highlighted, false)
  process.lua_func(function()
    require("venue-reader.treesitter").textobject("field")
  end)
  equal(process.lua_get("package.loaded['nvim-treesitter-textobjects.select'] == nil"), true)
  equal(process.api.nvim_get_mode().mode, "n")
end

tests["disabled buffers do not trigger automatic acquisition"] = function()
  local process = child({ manager = true })
  setup(process, { enabled = false, auto_install = true })
  local first = buffer(process)
  setup(process, { enabled = true, auto_install = false })
  equal(process.lua_get("require('tests.support.treesitter').calls"), 0)
  equal(status(process, first).highlighted, false)
  process.lua_func(function()
    require("venue-reader.treesitter").install()
  end)
  finish(process, nil, true, true)
  await_state(process, "ready")
  equal(status(process, first).highlighted, true)
end

tests["initial external highlighting is reused and preserved on disable"] = function()
  local process = child({ parser = true })
  local target = buffer(process)
  process.lua_func(function()
    vim.treesitter.start(0, "fix")
    _G.external_highlighter = vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()]
  end)
  setup(process)
  equal(
    process.lua_get(
      "external_highlighter == vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()]"
    ),
    true
  )
  equal(status(process, target).started, false)
  setup(process, { enabled = false, auto_install = true })
  equal(status(process, target).highlighted, true)
end

tests["accepted ownership limit stops a later external replacement"] = function()
  local process = child({ parser = true })
  setup(process)
  local target = buffer(process)
  process.lua_func(function()
    local active_buffer = vim.api.nvim_get_current_buf()
    local original = vim.treesitter.highlighter.active[active_buffer]
    vim.treesitter.stop(active_buffer)
    vim.treesitter.start(active_buffer, "fix")
    assert(original ~= vim.treesitter.highlighter.active[active_buffer])
  end)
  setup(process, { enabled = false, auto_install = true })
  equal(status(process, target).highlighted, false)
end

tests["native stop survives entry setup rename and retry until a new FIX episode"] = function()
  local process = child({ parser = true })
  setup(process)
  local target = buffer(process)
  process.lua_func(function()
    vim.treesitter.stop(0)
    vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. ".fix")
    vim.api.nvim_exec_autocmds("BufEnter", { buffer = 0 })
    require("venue-reader.treesitter").install()
  end)
  setup(process)
  equal(status(process, target).highlighted, false)
  process.api.nvim_set_option_value("filetype", "text", { buf = target })
  process.api.nvim_set_option_value("filetype", "fix", { buf = target })
  equal(status(process, target).highlighted, true)
end

tests["unload and reload starts a new loaded FIX episode"] = function()
  local process = child({ parser = true })
  setup(process)
  local target = buffer(process)
  process.lua_func(function()
    vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. ".fix")
    vim.cmd("silent write")
    vim.treesitter.stop(0)
  end)
  equal(status(process, target).highlighted, false)
  buffer(process)
  process.api.nvim_buf_delete(target, { unload = true })
  equal(process.api.nvim_buf_is_loaded(target), false)
  process.api.nvim_set_current_buf(target)
  equal(status(process, target).highlighted, true)
end

tests["accepted ownership limit covers an earlier FileType replacement"] = function()
  local process = child({ parser = true })
  process.lua_func(function()
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "lua",
      callback = function(event)
        vim.treesitter.stop(event.buf)
        vim.treesitter.start(event.buf, "lua")
      end,
    })
  end)
  setup(process)
  local target = buffer(process)
  process.api.nvim_set_option_value("filetype", "lua", { buf = target })
  equal(status(process, target).highlighted, false)
  equal(status(process, target).eligible, false)
end

for _, order in ipairs({ "before", "after" }) do
  tests["owner grammar recipe survives manager reload with handler " .. order] = function()
    local process = child({ manager = true })
    local register = function()
      process.lua_func(function()
        local recipe =
          { install_info = { url = "https://example.invalid/custom-fix", revision = "owner" } }
        require("nvim-treesitter.parsers").fix = recipe
        vim.api.nvim_create_autocmd("User", {
          pattern = "TSUpdate",
          callback = function()
            require("nvim-treesitter.parsers").fix = recipe
          end,
        })
      end)
    end
    if order == "before" then
      register()
    end
    setup(process)
    if order == "after" then
      register()
    end
    buffer(process)
    equal(
      process.lua_get("require('tests.support.treesitter').recipe.install_info.revision"),
      "owner"
    )
    equal(process.lua_get("require('tests.support.treesitter').calls"), 1)
  end
end

tests["real textobjects select tag value field message and comment"] = function()
  local process = child({ parser = true, textobjects = true })
  setup(process)
  local message = "8=FIX.4.4|35=D|58=café|"
  buffer(process, { message, "# synthetic comment" })
  local cases = {
    { "tag", 1, 10, "35" },
    { "value", 1, 13, "D" },
    { "field", 1, 12, "35=D" },
    { "value", 1, 18, "café" },
    { "message", 1, 12, message },
    { "comment", 2, 4, "# synthetic comment" },
  }
  for _, case in ipairs(cases) do
    process.type_keys("<Esc>")
    process.api.nvim_win_set_cursor(0, { case[2], case[3] })
    process.lua_func(function(kind)
      require("venue-reader.treesitter").textobject(kind)
    end, case[1])
    process.type_keys('"ay')
    equal(process.fn.getreg("a"), case[4])
  end
end

tests["selection honors user's whitespace and linewise settings"] = function()
  local process = child({ parser = true, textobjects = true })
  setup(process)
  local message = "35=D |58=note|"
  buffer(process, { message })
  process.lua_func(function()
    require("nvim-treesitter-textobjects").setup({
      select = { include_surrounding_whitespace = true },
    })
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    require("venue-reader.treesitter").textobject("field")
  end)
  process.type_keys('"ay')
  equal(process.fn.getreg("a"), "35=D ")
  process.lua_func(function()
    require("nvim-treesitter-textobjects").setup({
      select = { selection_modes = { ["@field"] = "V" } },
    })
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    require("venue-reader.treesitter").textobject("field")
  end)
  process.type_keys('"ay')
  equal(process.fn.getreg("a"), message .. "\n")
  equal(process.fn.getregtype("a"), "V")
end

tests["SOH defaults conceal the normal cursor line and reveal it while editing"] = function()
  local process = child({ parser = true })
  setup(process)
  local message = "8=FIX.4.4\00135=0\001"
  buffer(process, { message })
  equal(process.api.nvim_get_option_value("conceallevel", { win = 0 }), 2)
  equal(process.api.nvim_get_option_value("concealcursor", { win = 0 }), "nc")
  process.cmd("redraw!")
  assert(table.concat(process.get_screenshot().text[1]):find("8=FIX.4.4|35=0|", 1, true))

  process.type_keys(":")
  equal(process.api.nvim_get_mode().mode, "c")
  assert(table.concat(process.get_screenshot().text[1]):find("8=FIX.4.4|35=0|", 1, true))
  process.type_keys("<Esc>")
  process.type_keys("i")
  equal(process.api.nvim_get_mode().mode, "i")
  assert(table.concat(process.get_screenshot().text[1]):find("8=FIX.4.4^A35=0^A", 1, true))
  process.type_keys("<Esc>", "v")
  equal(process.api.nvim_get_mode().mode, "v")
  assert(table.concat(process.get_screenshot().text[1]):find("8=FIX.4.4^A35=0^A", 1, true))
  process.type_keys("<Esc>")
  assert(table.concat(process.get_screenshot().text[1]):find("8=FIX.4.4|35=0|", 1, true))
  equal(process.api.nvim_buf_get_lines(0, 0, -1, false), { message })
end

tests["SOH defaults preserve local overrides across focus and repeated setup"] = function()
  local process = child({ parser = true })
  setup(process)
  buffer(process)
  local windows = process.lua_func(function()
    local first = vim.api.nvim_get_current_win()
    vim.cmd("split")
    local second = vim.api.nvim_get_current_win()
    vim.api.nvim_set_option_value("conceallevel", 0, { win = first, scope = "local" })
    vim.api.nvim_set_option_value("concealcursor", "", { win = first, scope = "local" })
    vim.api.nvim_set_option_value("conceallevel", 1, { win = second, scope = "local" })
    vim.api.nvim_set_option_value("concealcursor", "v", { win = second, scope = "local" })
    vim.api.nvim_set_current_win(first)
    vim.api.nvim_set_current_win(second)
    return { first, second }
  end)
  setup(process)
  equal(process.api.nvim_get_option_value("conceallevel", { win = windows[1] }), 0)
  equal(process.api.nvim_get_option_value("concealcursor", { win = windows[1] }), "")
  equal(process.api.nvim_get_option_value("conceallevel", { win = windows[2] }), 1)
  equal(process.api.nvim_get_option_value("concealcursor", { win = windows[2] }), "v")
end

tests["SOH defaults allow native after ftplugin overrides"] = function()
  local process = child({ parser = true })
  local directory = process.lua_func(function()
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory .. "/after/ftplugin", "p")
    vim.fn.writefile(
      { "vim.opt_local.conceallevel = 1", 'vim.opt_local.concealcursor = "i"' },
      directory .. "/after/ftplugin/fix.lua"
    )
    vim.opt.runtimepath:append(directory .. "/after")
    return directory
  end)
  MiniTest.finally(function()
    vim.fn.delete(directory, "rf")
  end)
  setup(process)
  buffer(process)
  setup(process)
  equal(process.api.nvim_get_option_value("conceallevel", { win = 0 }), 1)
  equal(process.api.nvim_get_option_value("concealcursor", { win = 0 }), "i")
end

tests["SOH defaults stay with FIX buffers and do not change another filetype"] = function()
  local process = child({ parser = true })
  setup(process)
  local other = process.lua_func(function()
    local target = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(target)
    vim.api.nvim_set_option_value("filetype", "text", { buf = target })
    vim.api.nvim_set_option_value("conceallevel", 1, { win = 0, scope = "local" })
    vim.api.nvim_set_option_value("concealcursor", "v", { win = 0, scope = "local" })
    return target
  end)
  local target = buffer(process)
  equal(process.api.nvim_get_option_value("conceallevel", { win = 0 }), 2)
  equal(process.api.nvim_get_option_value("concealcursor", { win = 0 }), "nc")
  process.cmd("split")
  equal(process.api.nvim_get_option_value("conceallevel", { win = 0 }), 2)
  equal(process.api.nvim_get_option_value("concealcursor", { win = 0 }), "nc")
  process.cmd("close")
  process.api.nvim_set_current_buf(other)
  equal(process.api.nvim_get_option_value("conceallevel", { win = 0 }), 1)
  equal(process.api.nvim_get_option_value("concealcursor", { win = 0 }), "v")
  process.api.nvim_set_current_buf(target)
  equal(process.api.nvim_get_option_value("conceallevel", { win = 0 }), 2)
  equal(process.api.nvim_get_option_value("concealcursor", { win = 0 }), "nc")
  process.api.nvim_set_option_value("filetype", "text", { buf = target })
  equal(process.api.nvim_get_option_value("conceallevel", { win = 0 }), 0)
  equal(process.api.nvim_get_option_value("concealcursor", { win = 0 }), "")
end

tests["SOH conceal is window-local and leaves original bytes unchanged"] = function()
  local process = child({ parser = true })
  setup(process)
  local message = "8=FIX.4.4\00135=0\001"
  buffer(process, { message })
  local windows = process.lua_func(function()
    vim.api.nvim_set_option_value("laststatus", 0, {})
    vim.api.nvim_set_option_value("showtabline", 0, {})
    vim.api.nvim_set_option_value("conceallevel", 0, { win = 0 })
    vim.api.nvim_set_option_value("concealcursor", "nvic", { win = 0 })
    local raw = vim.api.nvim_get_current_win()
    vim.cmd("split")
    vim.api.nvim_set_option_value("conceallevel", 2, { win = 0 })
    vim.api.nvim_set_option_value("concealcursor", "nvic", { win = 0 })
    vim.cmd("redraw!")
    return { vim.api.nvim_win_get_position(0)[1] + 1, vim.api.nvim_win_get_position(raw)[1] + 1 }
  end)
  local screenshot = process.get_screenshot()
  assert(table.concat(screenshot.text[windows[1]]):find("8=FIX.4.4|35=0|", 1, true))
  assert(table.concat(screenshot.text[windows[2]]):find("8=FIX.4.4^A35=0^A", 1, true))
  equal(process.api.nvim_buf_get_lines(0, 0, -1, false), { message })
end

tests["missing textobjects preserves highlighting and LSP-independent setup"] = function()
  local process = child({ parser = true })
  setup(process)
  local target = buffer(process)
  process.lua_func(function()
    require("venue-reader.treesitter").textobject("field")
  end)
  equal(status(process, target).highlighted, true)
  equal(status(process, target).textobjects_available, false)
  equal(process.api.nvim_get_mode().mode, "n")
end

tests["public Plug textobject works as a native operator motion"] = function()
  local process = child({ parser = true, textobjects = true })
  process.lua_func(function()
    require("venue-reader").setup({
      server = { update_version = false },
      summary = { mode = "off" },
    })
    vim.keymap.set("o", "if", "<Plug>(VenueReaderField)")
  end)
  buffer(process, { "8=FIX.4.4|35=D|" })
  process.api.nvim_win_set_cursor(0, { 1, 13 })
  process.type_keys('"ayif')
  equal(process.fn.getreg("a"), "35=D")
  equal(process.fn.getregtype("a"), "v")
end

tests["an invalid existing parser is not silently replaced"] = function()
  local process = child({ manager = true })
  process.lua_func(function()
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory .. "/parser", "p")
    vim.fn.writefile({ "not a shared library" }, directory .. "/parser/fix.so", "b")
    vim.opt.runtimepath:prepend(directory)
  end)
  setup(process)
  local target = buffer(process)
  equal(status(process, target).state, "failed")
  equal(process.lua_get("require('tests.support.treesitter').calls"), 0)
  equal(status(process, target).highlighted, false)
end

tests["native semantic price and group styling stay visible over real syntax"] = function()
  local process = child({ parser = true })
  local result = process.lua_func(function(binary)
    vim.api.nvim_set_option_value("termguicolors", true, {})
    vim.api.nvim_set_option_value("signcolumn", "no", { win = 0 })
    vim.api.nvim_set_hl(0, "@normal.fix", { fg = 0xAA0000 })
    vim.api.nvim_set_hl(0, "@lsp.type.price.fix", { fg = 0x00FF00 })
    vim.api.nvim_set_hl(0, "@lsp.typemod.group.group1a.fix", { bg = 0x002200 })
    require("venue-reader").setup({
      server = { cmd = { binary, "--stdio" } },
      summary = { mode = "off" },
    })
    local message = "8=FIX.4.4|35=W|268=2|269=0|270=123.45|271=100|269=1|270=124.45|271=200|"
    local fixture = require("tests.support.treesitter")
    local target = fixture.buffer({ message }, vim.fn.tempname() .. ".fix")
    local column = assert(message:find("123.45", 1, true)) - 1
    fixture.wait(function()
      vim.cmd("redraw!")
      local tokens = vim.lsp.semantic_tokens.get_at_pos(target, 0, column) or {}
      local price, group = false, false
      for _, token in ipairs(tokens) do
        price = price or token.type == "price"
        group = group or (token.type == "group" and token.modifiers.group1a)
      end
      return price and group
    end, "native price/group tokens with Tree-sitter active")
    assert(vim.b[target].ts_highlight == true)
    vim.lsp.inlay_hint.enable(false, { bufnr = target })
    local active = assert(vim.lsp.get_clients({ bufnr = target, name = "venue-reader" })[1])
    local namespace = vim.api.nvim_create_namespace("nvim.lsp.semantic_tokens:" .. active.id)
    local styles = {}
    for _, mark in
      ipairs(vim.api.nvim_buf_get_extmarks(target, namespace, 0, -1, { details = true }))
    do
      local details = mark[4]
      if
        mark[2] == 0
        and mark[3] <= column
        and details.end_row == 0
        and details.end_col > column
      then
        styles[details.hl_group] = details.priority
      end
    end
    assert(styles["@lsp.type.price.fix"] > vim.hl.priorities.treesitter)
    assert(styles["@lsp.typemod.group.group1a.fix"] > vim.hl.priorities.treesitter)
    vim.cmd("redraw!")
    local combined = vim.fn.screenattr(1, column + 1)
    vim.treesitter.stop(target)
    vim.cmd("redraw!")
    return { combined, vim.fn.screenattr(1, column + 1), vim.b[target].ts_highlight == true }
  end, assert(vim.env.VENUE_READER_TEST_SERVER))
  assert(result[1] ~= 0, "Expected visible semantic styling")
  equal(result[1], result[2])
  equal(result[3], false)
end

tests["public setup rejects invalid Tree-sitter option types"] = function()
  local process = child()
  for _, options in ipairs({ { enabled = "yes" }, { auto_install = "yes" }, false }) do
    local accepted = process.lua_func(function(value)
      return pcall(require("venue-reader").setup, { treesitter = value })
    end, options)
    equal(accepted, false)
  end
end

tests["real LSP hover and decoded yank work while grammar is pending and failed"] = function()
  local process = child({ manager = true })
  process.lua_func(function(binary)
    local reports = {}
    local handler = function(err, result, context, value)
      if not err and result then
        reports[result.uri] = true
      end
      return vim.lsp.handlers["textDocument/publishDiagnostics"](err, result, context, value)
    end
    vim.lsp.config("venue-reader", { handlers = { ["textDocument/publishDiagnostics"] = handler } })
    require("venue-reader").setup({
      server = { cmd = { binary, "--stdio" } },
      summary = { mode = "off" },
    })
    local fixture = require("tests.support.treesitter")
    local target = fixture.buffer(nil, vim.fn.tempname() .. ".fix")
    fixture.wait(function()
      local active = vim.lsp.get_clients({ bufnr = target, name = "venue-reader" })[1]
      return active and active.initialized and reports[vim.uri_from_bufnr(target)]
    end, "LSP document readiness while grammar pending")
  end, assert(vim.env.VENUE_READER_TEST_SERVER))
  equal(status(process).state, "installing")
  for _, state in ipairs({ "pending", "failed" }) do
    if state == "failed" then
      finish(process, "synthetic compiler failure", false, false)
      await_state(process, "failed")
    end
    process.lua_func(function()
      local target = vim.api.nvim_get_current_buf()
      local active = assert(vim.lsp.get_clients({ bufnr = target, name = "venue-reader" })[1])
      local response = assert(active:request_sync("textDocument/hover", {
        textDocument = { uri = vim.uri_from_bufnr(target) },
        position = { line = 0, character = 12 },
      }, 3000, target))
      assert(
        response.result and response.result.contents.value:find("Heartbeat", 1, true),
        vim.inspect(response)
      )
      vim.fn.setreg("a", "before")
      require("venue-reader").yank({ register = "a", mode = "line" })
      local fixture = require("tests.support.treesitter")
      local success = vim.wait(3000, function()
        return vim.fn.getreg("a"):find("Heartbeat", 1, true) ~= nil
      end, 10)
      assert(
        success,
        "decoded yank while grammar unavailable: "
          .. vim.inspect(fixture.messages)
          .. "; register="
          .. vim.fn.getreg("a")
      )
    end)
  end
end

tests["invalid textobjects query does not disable native highlighting"] = function()
  local process = child({ parser = true, textobjects = true })
  process.lua_func(function()
    vim.treesitter.query.set("fix", "highlights", "(tag) @comment")
    vim.treesitter.query.set("fix", "textobjects", "(missing_node) @field")
  end)
  setup(process)
  local target = buffer(process)
  equal(status(process, target).state, "ready")
  equal(status(process, target).highlighted, true)
  equal(
    process.lua_func(function()
      return require("venue-reader.treesitter").textobject("field")
    end),
    false
  )
  equal(status(process, target).state, "ready")
  equal(status(process, target).highlighted, true)
end

tests["compatibility check uses the effective native highlights query"] = function()
  local process = child({ parser = true })
  process.lua_func(function()
    vim.treesitter.query.set("fix", "highlights", "(missing_node) @comment")
  end)
  setup(process)
  local target = buffer(process)
  equal(status(process, target).state, "failed")
  equal(status(process, target).highlighted, false)
end

return tests

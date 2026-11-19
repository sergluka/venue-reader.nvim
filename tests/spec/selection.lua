local MiniTest = require("mini.test")

local tests = MiniTest.new_set()
local equal = MiniTest.expect.equality

local function child(lines)
  local process = MiniTest.new_child_neovim()
  process.start({ "-u", "NONE", "-i", "NONE" })
  MiniTest.finally(process.stop)
  process.lua_func(function(directory, input_lines)
    vim.opt.runtimepath:prepend(directory)
    _G.Selection = require("venue-reader.selection")
    vim.api.nvim_set_option_value("clipboard", "", {})
    vim.api.nvim_set_var("clipboard", {
      name = "test",
      copy = { ["+"] = function() end, ["*"] = function() end },
      paste = {
        ["+"] = function()
          return { {}, "v" }
        end,
        ["*"] = function()
          return { {}, "v" }
        end,
      },
    })
    vim.api.nvim_set_option_value("virtualedit", "block", {})
    vim.api.nvim_buf_set_lines(0, 0, -1, false, input_lines)
    _G.texts = function(ranges, encoding)
      local result = {}
      for _, range in ipairs(ranges) do
        local first, last = range.start, range["end"]
        local first_text = vim.api.nvim_buf_get_lines(0, first.line, first.line + 1, true)[1]
        local last_text = vim.api.nvim_buf_get_lines(0, last.line, last.line + 1, true)[1]
        result[#result + 1] = vim.api.nvim_buf_get_text(
          0,
          first.line,
          vim.str_byteindex(first_text, encoding, first.character, false),
          last.line,
          vim.str_byteindex(last_text, encoding, last.character, false),
          {}
        )
      end
      return result
    end
    _G.capture = function(options, encoding)
      _G.saved = _G.Selection.capture(options)
      _G.ranges = _G.Selection.ranges(_G.saved, encoding or "utf-8")
      return _G.texts(_G.ranges, encoding or "utf-8")
    end
    _G.operator = function(kind)
      _G.capture({ mode = kind, operator = true })
    end
    vim.api.nvim_set_option_value("operatorfunc", "v:lua.operator", { scope = "global" })
    _G.state = function()
      return {
        cursor = vim.fn.getpos("."),
        view = vim.fn.winsaveview(),
        anchor = vim.fn.getpos("v"),
        first = vim.fn.getpos("'<"),
        last = vim.fn.getpos("'>"),
        operator_first = vim.fn.getpos("'["),
        operator_last = vim.fn.getpos("']"),
        local_virtualedit = vim.api.nvim_get_option_value(
          "virtualedit",
          { win = 0, scope = "local" }
        ),
        global_virtualedit = vim.go.virtualedit,
        selection = vim.o.selection,
        tabstop = vim.bo.tabstop,
        vartabstop = vim.bo.vartabstop,
      }
    end
  end, assert(vim.env.VENUE_READER_TEST_ROOT), lines)
  return process
end

local function visual_oracle(process, keys, encoding)
  process.type_keys("<Esc>", keys)
  local before = process.lua_get("state()")
  local selected = process.lua_get("capture({mode='visual'}, ...)", { encoding or "utf-8" })
  equal(process.lua_get("state()"), before)
  process.type_keys('"ay')
  local native = process.fn.getreginfo("a").regcontents
  if process.lua_get("saved.kind") == "block" then
    local actual = {}
    for index, row in ipairs(native) do
      actual[index] = row:gsub(" +$", "")
    end
    local expected = {}
    for index, rows in ipairs(selected) do
      equal(#rows, 1)
      expected[index] = rows[1]
    end
    equal(expected, actual)
  else
    equal(selected, { native })
  end
end

tests["cursor and Ex line ranges stay sparse and use negotiated offsets"] = function()
  local process = child({ "A😀éZ", "", "tail" })
  process.api.nvim_win_set_cursor(0, { 1, 5 })
  for encoding, column in pairs({ ["utf-8"] = 5, ["utf-16"] = 3, ["utf-32"] = 2 }) do
    process.lua("capture(nil, ...)", { encoding })
    equal(process.lua_get("ranges"), {
      { start = { line = 0, character = column }, ["end"] = { line = 0, character = column } },
    })
  end
  equal(process.lua_get("capture({mode='line',first=2,last=1})"), { { "A😀éZ", "" } })
  equal(
    process.lua_get("{#ranges,saved.row_count,saved.line_count,saved.kind}"),
    { 1, 2, 3, "line" }
  )
end

tests["character selections agree with native yank in both directions and encodings"] = function()
  local process = child({ "A😀éZ", "uvwxyz", "" })
  for _, selection in ipairs({ "inclusive", "exclusive" }) do
    process.o.selection = selection
    for _, encoding in ipairs({ "utf-8", "utf-16", "utf-32" }) do
      for _, keys in ipairs({ "gg0vll", "gg03lvhh", "gg0lv", "gg0lvj0", "gg0vj0" }) do
        visual_oracle(process, keys, encoding)
      end
    end
  end
end

tests["line selections preserve empty boundary rows and reverse direction"] = function()
  local process = child({ "", "middle", "" })
  visual_oracle(process, "ggVjj")
  visual_oracle(process, "GVkk")
end

tests["native operator handles counts motions text objects and dollar"] = function()
  local process = child({
    "alpha bravo charlie",
    "second row",
    "",
    "fourth",
    "fifth",
    "sixth",
    "seventh",
    "eighth",
  })
  for _, selection in ipairs({ "inclusive", "exclusive" }) do
    process.o.selection = selection
    for _, motion in ipairs({ "2l", "iw", "$", "j", "2j" }) do
      process.type_keys("<Esc>", "gg0g@" .. motion)
      local selected = process.lua_get("texts(ranges,'utf-8')")
      process.type_keys('gg0"ay' .. motion)
      equal(selected, { process.fn.getreginfo("a").regcontents })
    end
    process.type_keys("gg02g@3j")
    equal(process.lua_get("{saved.kind,saved.row_count,#ranges}"), { "line", 7, 1 })
    local selected = process.lua_get("texts(ranges,'utf-8')")
    process.type_keys('gg02"ay3j')
    equal(selected, { process.fn.getreginfo("a").regcontents })
  end
end

tests["block selections agree with native yank including exclusive and short rows"] = function()
  local process = child({ "abcdefghijk", "xy", "", "ABCDEFGHIJK" })
  for _, selection in ipairs({ "inclusive", "exclusive" }) do
    process.o.selection = selection
    for _, keys in ipairs({ "gg02l<C-v>jjjlll", "G05l<C-v>kkkhhh", "gg0<C-v>jjj" }) do
      visual_oracle(process, keys)
    end
  end
end

tests["Visual dollar preserves every physical EOL including longer middle rows"] = function()
  local process =
    child({ "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abc", "", "0123456789ABCDEFGHIJKLM" })
  for _, selection in ipairs({ "inclusive", "exclusive" }) do
    process.o.selection = selection
    for _, keys in ipairs({
      "gg09l<C-v>j$",
      "gg09l<C-v>jj$",
      "gg09l<C-v>jjj$",
      "4G09l<C-v>kk$",
      "gg03l<C-v>jjj$",
    }) do
      visual_oracle(process, keys)
      equal(process.lua_get("saved.maxcol"), true)
    end
  end
end

tests["block operators keep native cell offsets after Visual mode exits"] = function()
  local process = child({ "abcdefghijk", "xy", "", "ABCDEFGHIJK" })
  for _, keys in ipairs({ "gg02l<C-v>jjjlll", "G05l<C-v>kkkhhh" }) do
    process.type_keys("<Esc>", keys, "g@")
    local selected = process.lua_get("texts(ranges,'utf-8')")
    process.type_keys(keys, '"ay')
    local native = process.fn.getreginfo("a").regcontents
    for index, row in ipairs(native) do
      equal(selected[index], { (row:gsub(" +$", "")) })
    end
  end
end

tests["block dollar operator agrees with native yank on unequal row lengths"] = function()
  local process = child({ "abcde", "abcdefghijklmnopqrstuvwxyz", "", "xyz" })
  for _, keys in ipairs({ "gg0l<C-v>jjj$", "G0l<C-v>kkk$" }) do
    process.type_keys("<Esc>", keys, "g@")
    local selected = process.lua_get("texts(ranges,'utf-8')")
    process.type_keys(keys, '"ay')
    local native = process.fn.getreginfo("a").regcontents
    for index, row in ipairs(native) do
      equal(selected[index], { (row:gsub(" +$", "")) })
    end
  end
end

tests["partial tabs and wide glyphs include source bytes without virtual padding"] = function()
  local process = child({ "abcd", "a\tZ", "界Z", "éZ", "", "x" })
  process.o.tabstop = 4
  process.type_keys("gg0l<C-v>jjjjjl")
  equal(
    process.lua_get("capture({mode='visual'})"),
    { { "bc" }, { "\t" }, { "界Z" }, { "Z" }, { "" }, { "" } }
  )
  process.type_keys('"ay')
  equal(process.fn.getreginfo("a").regcontents, { "bc", "  ", " Z", "Z ", "  ", "  " })
  process.type_keys("gg0l<C-v>jjjjjlg@")
  equal(
    process.lua_get("texts(ranges,'utf-8')"),
    { { "bc" }, { "\t" }, { "界Z" }, { "Z" }, { "" }, { "" } }
  )
end

tests["captured state invalidates on source URI or geometry options changes"] = function()
  local process = child({ "one", "two" })
  process.lua("capture()")
  equal(process.lua_get("Selection.valid(saved)"), true)
  process.api.nvim_win_set_cursor(0, { 2, 0 })
  equal(process.lua_get("Selection.valid(saved)"), true)
  process.o.selection = "exclusive"
  equal(process.lua_get("Selection.valid(saved)"), false)
  process.lua_func(function()
    _G.capture()
    vim.api.nvim_set_option_value("tabstop", 3, { buf = 0 })
  end)
  equal(process.lua_get("Selection.valid(saved)"), false)
  process.lua_func(function()
    _G.capture()
    vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. ".fix")
  end)
  equal(process.lua_get("Selection.valid(saved)"), false)
  process.lua_func(function()
    _G.capture()
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "changed" })
  end)
  equal(process.lua_get("Selection.valid(saved)"), false)
end

return tests

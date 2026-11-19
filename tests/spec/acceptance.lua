local MiniTest = require("mini.test")

local tests = MiniTest.new_set()
local equal = MiniTest.expect.equality
local root = assert(vim.env.VENUE_READER_TEST_ROOT)

local function child(parser)
  local process = MiniTest.new_child_neovim()
  process.start({ "-u", "NONE", "-i", "NONE" })
  MiniTest.finally(process.stop)
  process.lua_func(function(directory, binary, enabled)
    vim.opt.runtimepath:prepend(directory)
    package.path = directory .. "/?.lua;" .. directory .. "/?/init.lua;" .. package.path
    require("tests.support.acceptance").setup(directory, binary, enabled)
  end, root, assert(vim.env.VENUE_READER_TEST_SERVER), parser)
  return process
end

local function save(process, label)
  local screenshot = process.get_screenshot()
  local directory = vim.env.VENUE_READER_ACCEPTANCE_OUTPUT
  if directory and directory ~= "" then
    vim.fn.mkdir(directory, "p")
    local metadata = process.lua_func(function()
      local windows = {}
      for _, window in ipairs(vim.api.nvim_list_wins()) do
        windows[#windows + 1] = {
          width = vim.api.nvim_win_get_width(window),
          height = vim.api.nvim_win_get_height(window),
          wrap = vim.api.nvim_get_option_value("wrap", { win = window }),
        }
      end
      return { nvim = vim.version(), windows = windows, status = require("venue-reader").status() }
    end)
    local version = metadata.nvim.major .. "." .. metadata.nvim.minor .. "." .. metadata.nvim.patch
    vim.fn.writefile(
      { vim.json.encode({ screenshot = screenshot, metadata = metadata }) },
      directory .. "/" .. version .. "-" .. label .. ".json"
    )
  end
  return table.concat(
    vim.tbl_map(function(line)
      return table.concat(line)
    end, screenshot.text),
    "\n"
  )
end

tests["published server combined naming splits modes yank rename and restart"] = function()
  local process = child(false)
  local result = process.lua_func(function()
    local fixture = require("tests.support.acceptance")
    local plugin = require("venue-reader")
    local message = "8=FIX.4.4|35=0|58=Привет 東京|"
    local first = fixture.buffer({ message })
    assert(#vim.lsp.get_clients({ bufnr = first, name = "venue-reader" }) == 0)
    vim.cmd("file " .. vim.fn.fnameescape(vim.fn.tempname() .. ".fix"))
    local initial = fixture.ready(first)
    local first_name = vim.api.nvim_buf_get_name(first)
    local second =
      fixture.buffer({ "8=FIX.4.4|35=1|" }, vim.fs.dirname(first_name) .. "/second.fix")
    assert(fixture.ready(second).id == initial.id)
    vim.api.nvim_set_current_buf(first)
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(0, second)
    vim.cmd("wincmd p")
    vim.api.nvim_win_set_buf(0, first)
    fixture.mode(first, "above")
    vim.api.nvim_buf_set_lines(
      first,
      0,
      1,
      false,
      { "8=FIX.4.4|35=0|58=Обновлено 東京|" }
    )
    fixture.mode(first, "codelens")
    fixture.mode(first, "off")
    fixture.mode(first, "front")
    vim.fn.setreg("a", "before")
    plugin.yank({ register = "a", mode = "line" })
    fixture.wait(function()
      return vim.fn.getreg("a"):find("Heartbeat", 1, true) ~= nil
    end, "decoded yank after mode and Unicode edit")
    local response = assert(initial:request_sync("workspace/executeCommand", {
      command = "fix.describeOverrides",
      arguments = { vim.uri_from_bufnr(first) },
    }, 3000, first))
    assert(response.result and not response.err, vim.inspect(response))
    vim.cmd("file " .. vim.fn.fnameescape(vim.fn.tempname() .. ".fix"))
    assert(fixture.ready(first).id == initial.id)
    plugin.restart()
    fixture.wait(function()
      local current = vim.lsp.get_clients({ bufnr = first, name = "venue-reader" })[1]
      return current and current.id ~= initial.id
    end, "native restarted client")
    local replacement = fixture.ready(first)
    assert(fixture.ready(second).id == replacement.id)
    local raw = vim.api.nvim_buf_get_lines(first, 0, -1, false)
    vim.cmd("only")
    vim.api.nvim_buf_delete(first, { force = true })
    vim.api.nvim_set_current_buf(second)
    assert(fixture.ready(second).id == replacement.id)
    vim.api.nvim_buf_delete(second, { force = true })
    local reopened = fixture.buffer(raw, first_name)
    fixture.ready(reopened)
    fixture.mode(reopened, "front")
    return { vim.fn.getreg("a"), raw, vim.fn.filereadable(first_name) }
  end)
  assert(result[1]:find("Обновлено 東京", 1, true))
  equal(result[2], { "8=FIX.4.4|35=0|58=Обновлено 東京|" })
  equal(result[3], 0)
  save(process, "combined-final-front")
end

for _, parser in ipairs({ false, true }) do
  tests["published real visual modes with syntax=" .. tostring(parser)] = function()
    local process = child(parser)
    local message =
      "8=FIX.4.4|35=W|268=2|269=0|270=123.45|271=100|269=1|270=124.45|271=200|58=東京|"
    process.lua_func(function(line)
      local fixture = require("tests.support.acceptance")
      local buffer = fixture.buffer({ line }, vim.fn.tempname() .. ".fix")
      fixture.ready(buffer)
      vim.api.nvim_set_option_value("signcolumn", "no", { win = 0 })
      vim.api.nvim_set_option_value("laststatus", 0, {})
    end, message)
    for _, mode in ipairs({ "front", "above", "codelens", "off" }) do
      process.lua_func(function(selected)
        require("tests.support.acceptance").mode(vim.api.nvim_get_current_buf(), selected)
      end, mode)
      local text = save(process, mode .. "-syntax-" .. tostring(parser))
      assert(text:find("FIX.4.4", 1, true), text)
      equal(process.api.nvim_buf_get_lines(0, 0, -1, false), { message })
      equal(process.lua_get("vim.b.ts_highlight == true"), parser)
    end
  end
end

return tests

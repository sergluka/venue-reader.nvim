local root = assert(vim.env.VENUE_READER_TEST_ROOT)
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/.test-deps/mini.test")
vim.opt.runtimepath:prepend(root .. "/.test-deps/snacks.nvim")
local snacks = require("snacks")
snacks.setup({ picker = { enabled = true, ui_select = false } })
-- Headless script execution does not emit UIEnter.
snacks.picker.setup()
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
vim.lsp.log.set_level("ERROR")
vim.api.nvim_set_option_value("more", false, {})

local MiniTest = require("mini.test")
local reporter = MiniTest.gen_reporter.stdout()
local report_path = vim.env.VENUE_READER_CASE_REPORT
if report_path then
  local cases, skips = {}, {}
  local stdout_start, stdout_finish, skip = reporter.start, reporter.finish, MiniTest.skip
  reporter.start = function(collected)
    cases = collected
    stdout_start(collected)
  end
  MiniTest.skip = function(reason)
    skips[MiniTest.current.case] = reason or "Skip test"
    skip(reason)
  end
  reporter.finish = function()
    local results = {}
    local valid = #cases > 0
    for _, case in ipairs(cases) do
      local name = table.concat(vim.list_slice(case.desc, 2), " | ")
      local reason = skips[case]
      local passed = case.exec and vim.startswith(case.exec.state, "Pass")
      local status = passed and "passed" or "failed"
      if reason and passed then
        status = "skipped"
        if vim.env.CI == "true" then
          valid = false
          io.stderr:write("Unexpected skip: " .. name .. ": " .. reason .. "\n")
        end
      end
      table.insert(results, { name = name, status = status, reason = reason })
    end
    vim.fn.writefile({ vim.json.encode(results) }, report_path)
    if not valid then
      vim.cmd("cquit 1")
    end
    stdout_finish()
  end
end
MiniTest.setup({
  collect = {
    find_files = function()
      return vim.list_slice(arg)
    end,
  },
  execute = { reporter = reporter },
})
MiniTest.run()
assert(
  vim.wait(55000, function()
    return not MiniTest.is_executing()
  end, 10),
  "mini.test timed out"
)

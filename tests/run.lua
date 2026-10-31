local root = assert(vim.env.VENUE_READER_TEST_ROOT)
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/.test-deps/mini.test")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
vim.lsp.log.set_level("ERROR")
vim.api.nvim_set_option_value("more", false, {})

local MiniTest = require("mini.test")
MiniTest.setup({
  collect = {
    find_files = function()
      return vim.list_slice(arg)
    end,
  },
  execute = { reporter = MiniTest.gen_reporter.stdout() },
})
MiniTest.run()
assert(
  vim.wait(55000, function()
    return not MiniTest.is_executing()
  end, 10),
  "mini.test timed out"
)

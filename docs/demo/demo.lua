local plugin = vim.fs.normalize(vim.fn.expand("<sfile>:p:h") .. "/../..")
local deps = plugin .. "/.test-deps"
for _, path in ipairs({
  plugin,
  deps .. "/snacks.nvim",
  deps .. "/nvim-treesitter-textobjects",
  deps .. "/treesitter/runtime",
}) do
  vim.opt.runtimepath:prepend(path)
end

vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.cursorline = true
vim.opt.wrap = true
vim.opt.shortmess:append("I")
vim.opt.fillchars = { eob = " " }
vim.opt.showtabline = 0
vim.opt.swapfile = false
vim.opt.laststatus = 3
vim.opt.statusline = "  %t %m%=%l:%c  "
vim.opt.background = "dark"
vim.opt.winborder = "rounded"
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/tokyonight.nvim")

if #vim.api.nvim_get_runtime_file("colors/tokyonight.lua", false) > 0 then
  vim.cmd.colorscheme("tokyonight-night")
else
  vim.cmd.colorscheme("default")
end
vim.diagnostic.config({ virtual_text = true, signs = false })

require("snacks").setup({ picker = { enabled = true } })

vim.lsp.config("venue-reader", {
  cmd = { vim.fs.dirname(plugin) .. "/venue-reader/target/debug/venue-reader", "--stdio" },
  settings = {
    fix = { inlayHints = { tagNames = { enabled = true }, enumValues = { enabled = true } } },
  },
})

require("venue-reader").setup({
  summary = { mode = "above" },
  treesitter = { auto_install = false },
})
vim.keymap.set("n", "]]", function()
  require("nvim-treesitter-textobjects.move").goto_next_start("@field", "textobjects")
end)

vim.keymap.set("n", "[[", function()
  require("nvim-treesitter-textobjects.move").goto_previous_start("@field", "textobjects")
end)

vim.filetype.add({ filename = { ["orders.fix"] = "text" } })

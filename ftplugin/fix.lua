vim.api.nvim_set_option_value("conceallevel", 2, { scope = "local" })
vim.api.nvim_set_option_value("concealcursor", "nc", { scope = "local" })

local undo = "setlocal conceallevel< concealcursor<"
vim.api.nvim_buf_set_var(
  0,
  "undo_ftplugin",
  vim.b.undo_ftplugin and (vim.b.undo_ftplugin .. " | " .. undo) or undo
)

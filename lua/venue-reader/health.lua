local M = {}
function M.check()
  vim.health.start("Venue Reader")
  if vim.fn.has("nvim-0.12") == 1 then
    vim.health.ok("Neovim >=0.12")
  else
    vim.health.error("Neovim >=0.12 is required")
  end
  local status = require("venue-reader").status()
  if status.acquisition.error then
    vim.health.error(status.acquisition.error)
  elseif status.acquisition.state == "ready" then
    vim.health.ok("Compatible server " .. status.acquisition.version)
  else
    vim.health.info("Server discovery starts with a named FIX buffer or install server")
  end
  if status.session and status.session.failure then
    vim.health.error(status.session.failure)
  end
  vim.health.info(vim.inspect(status))
  vim.health.info("Tree-sitter is optional; custom annotations are not implemented yet")
end
return M

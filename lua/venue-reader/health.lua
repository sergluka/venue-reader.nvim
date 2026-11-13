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
  elseif status.acquisition.state == "external" then
    vim.health.info("Server transport is configured through native LSP cmd")
  elseif status.acquisition.state == "ready" then
    vim.health.ok("Compatible server " .. status.acquisition.version)
  else
    vim.health.info("Server discovery starts with a named FIX buffer or install server")
  end
  if status.session and status.session.failure then
    vim.health.error(status.session.failure)
  end
  if status.annotations.problem then
    vim.health.warn(status.annotations.problem)
  end
  status.treesitter = require("venue-reader.treesitter").status(false)
  if status.treesitter.error then
    vim.health.warn(status.treesitter.error)
  end
  vim.health.info(vim.inspect(status))
  vim.health.info("Tree-sitter is optional; summaries adapt native LSP responses")
  if not status.symbols.enabled then
    vim.health.info("Optional symbol picker is disabled")
  elseif #vim.api.nvim_get_runtime_file("lua/snacks/init.lua", false) > 0 then
    vim.health.ok("Snacks is available for :VenueReader symbols")
  else
    vim.health.info("Optional snacks.nvim enables :VenueReader symbols")
  end
end
return M

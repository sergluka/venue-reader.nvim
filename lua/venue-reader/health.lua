local M = {}

local function server_health(status)
  local policy = status.server_policy
  if policy.source then
    local source = policy.source == "native_cmd" and "native LSP cmd" or policy.source
    vim.health.info("Server supplied by " .. source .. "; manage its executable externally")
  elseif policy.update_version == "latest" then
    vim.health.info("Automatic server updates track the latest compatible stable release")
  elseif policy.update_version then
    vim.health.info("Server installation and updates are pinned to " .. policy.update_version)
  else
    vim.health.info(
      "Automatic server installation and updates are disabled. Use :VenueReader install server"
        .. ' for a one-time install or server.update_version = "latest" for automatic updates.'
    )
  end

  local acquisition, session = status.acquisition, status.session
  if
    session
    and session.version
    and (session.version ~= acquisition.version or session.source ~= acquisition.source)
  then
    vim.health.info(("Running server %s (%s)"):format(session.version, session.source))
  end
  if acquisition.error then
    vim.health.error(acquisition.error)
  elseif acquisition.state == "ready" then
    if acquisition.update_error then
      vim.health.warn(acquisition.reason)
    else
      vim.health.ok(
        "Compatible server " .. acquisition.version .. " (" .. acquisition.source .. ")"
      )
    end
  elseif acquisition.state == "idle" then
    vim.health.info("Open a named FIX buffer to start server discovery")
  elseif acquisition.state ~= "external" then
    vim.health.info("Server acquisition: " .. acquisition.state)
  end
end

function M.check()
  vim.health.start("Venue Reader")
  if vim.fn.has("nvim-0.12") == 1 then
    vim.health.ok("Neovim >=0.12")
  else
    vim.health.error("Neovim >=0.12 is required")
  end
  local status = require("venue-reader").status()
  server_health(status)
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

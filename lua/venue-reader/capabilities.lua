return {
  workspace = {
    -- Neovim 0.12.0-0.12.6 omits this capability: https://github.com/neovim/neovim/pull/42453
    workspaceEdit = { documentChanges = true },
  },
  experimental = {
    venueReader = { summaryTokens = 1 },
  },
}

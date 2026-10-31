# venue-reader.nvim

## Architecture

- The plugin is a thin adapter for the Venue Reader server, with small helpers.
- Delegate all functionality Neovim already provides through its built-in LSP
  client to Neovim. Do not reimplement or duplicate native LSP functionality.
- Add plugin code only for adaptation or helpers that native Neovim LSP does not
  provide. Verify the native APIs before introducing a custom mechanism.
- Keep protocol analysis and interpretation in the server.

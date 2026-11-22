# venue-reader.nvim

A Neovim plugin for the [Venue Reader language server](https://github.com/sergluka/venue-reader). Requires Neovim 0.12+.
See the [editor compatibility matrix](https://github.com/sergluka/venue-reader/wiki/Editor-Compatibility) for available features by editor.

The plugin reuses or installs the server, renders message summaries, and adds
decoded yank and dictionary helpers. Hover, diagnostics, code actions, document
symbols, field hints and semantic highlighting use Neovim's native LSP support.
With optional Snacks, browse and search FIX messages, groups, and fields in a
tree, even while the list is still loading.
Optional Tree-sitter adds base highlighting, SOH conceal and structural selection
and navigation.

<https://github.com/user-attachments/assets/0abff0c6-b02d-4b9d-b65b-abcfed46b0c6>

## Installation

Choose one installation method below.

### LazyVim

Create `lua/plugins/venue-reader.lua`. Register native server settings before setup:

```lua
-- lua/plugins/venue-reader.lua
return {
  {
    "sergluka/venue-reader.nvim",
    dependencies = { -- optional
      { "folke/snacks.nvim", opts = { picker = { enabled = true } } },
      { "nvim-treesitter/nvim-treesitter", branch = "main" },
      { "nvim-treesitter/nvim-treesitter-textobjects", branch = "main" },
    },
    opts = {
      -- plugin settings
    },
    config = function(_, opts)
      vim.lsp.config("venue-reader", {
        -- server settings
      })
      require("venue-reader").setup(opts)
    end,
  },
}
```

The optional Tree-sitter dependencies use `main` APIs; ensure your LazyVim
configuration uses those APIs. The inner spec also works with standalone
lazy.nvim. Remove `dependencies` if you do not need them.

To disable the picker command, set `opts = { symbols = { enabled = false } }`.
All native LSP features, including document symbols, work without Snacks.

### Native Neovim package manager

Add to `init.lua`:

```lua
-- init.lua
vim.pack.add({
  {
    src = "https://github.com/sergluka/venue-reader.nvim",
  },
})

vim.lsp.config("venue-reader", {
  -- server settings
})

require("venue-reader").setup({
  -- plugin settings
})
```

Update with `:lua vim.pack.update({ "venue-reader.nvim" })`.

### After installation

Open a named FIX buffer to start the language server.

The manifest includes Linux x86_64 (glibc >=2.35), macOS Intel and Apple Silicon,
and Windows x86_64 archives.
Installation tools and manual/offline setup are described in
[Installation](https://github.com/sergluka/venue-reader.nvim/wiki/Installation)
and `:help venue-reader-setup`.

## Configuration

Call `setup()` without arguments to use the [plugin defaults](https://github.com/sergluka/venue-reader.nvim/wiki/Configuration#native-settings-and-adapter-options).
Use `vim.lsp.config()` for server settings and `setup()` options for plugin
behavior such as summary placement.

```lua
vim.lsp.config("venue-reader", {
  settings = { fix = {
    inlayHints = {
      tagNames = { enabled = true },
      enumValues = { enabled = true },
    },
  } },
})
require("venue-reader").setup({ summary = { mode = "above" } })
```

For an existing binary or offline use:

```lua
require("venue-reader").setup({
  server = {
    cmd = { "/absolute/path/to/venue-reader", "--stdio" },
  },
  treesitter = { enabled = false },
})
```

The executable in `server.cmd` must support `--version`. Native `cmd` takes
precedence. Register native `cmd`, `root_dir` and callbacks before setup. The
adapter preserves them and composes required hooks. Project/modeline settings
keep precedence.

Changes to `vim.lsp.config` settings apply to new clients; use
`:VenueReader restart` or explicitly update an attached client's settings and
send `workspace/didChangeConfiguration`. Repeated setup changes adapter options,
including only the three summary keys it manages. See
[plugin configuration](https://github.com/sergluka/venue-reader.nvim/wiki/Configuration),
`:help venue-reader-setup` and the server's
[settings reference](https://github.com/sergluka/venue-reader/wiki/Configuration-Reference).

### Server updates

Without an explicit command, the plugin follows the latest stable server release
within the supported major. It reuses a suitable installed binary or downloads
the release when needed. Set `server.update_version` to an exact version such as
`"0.4.0"` to pin a release, or to `false` to disable automatic downloads.
Choose a stable version from the [server releases](https://github.com/sergluka/venue-reader/releases).

With `server.cmd` or native LSP `cmd`, omit `server.update_version` or set it to
`false`. To download a managed release manually, use `:VenueReader install server [version]`.

If a latest-release update fails, the plugin can use a compatible installed
binary. Check `:VenueReader status` for the reason. See
[Server updates](https://github.com/sergluka/venue-reader.nvim/wiki/Configuration#server-updates)
for the full option table.

## Quick start

Open a `*.fix` file, or use `:set ft=fix`. LSP attachment requires a normal buffer
with a name; `:file /path/log.fix` assigns one without saving. Buffers share a
client under the nearest `.venue-reader.toml` root, otherwise their directory,
unless native `root_dir` supplies another rule.

Use native LSP interfaces, for example `:lua vim.lsp.buf.hover()` and
`:lua vim.lsp.buf.document_symbol()`. The plugin sets no user keybindings.
For movement between FIX messages and fields, see the
[suggested Tree-sitter keybindings](https://github.com/sergluka/venue-reader.nvim/wiki/Tree-sitter#suggested-navigation-mappings).

Decode the field under the cursor with `:VenueReader yank`, or lines with
`:10,20VenueReader yank a`, then paste normally.

The `<Plug>(VenueReaderYank)` mapping uses Neovim's native operator support for
motions, textobjects, counts and repeat. See the mapping example, register
behavior and character/line/block selections in
[Commands](https://github.com/sergluka/venue-reader.nvim/wiki/Commands)
and `:help venue-reader-commands`.

## Commands

| Command | Purpose |
| --- | --- |
| `:VenueReader status` | Inspect server, annotations and optional grammar state |
| `:checkhealth venue-reader` | Check requirements and current state |
| `:VenueReader restart` | Restart the configured transport through native LSP |
| `:VenueReader install server [version]` | Install a managed release once (default `latest`) |
| `:VenueReader install grammar` | Retry optional FIX parser acquisition |
| `:VenueReader dictionary` | Choose a server dictionary with `vim.ui.select` |
| `:VenueReader settings` | Preview effective settings, sources and warnings |
| `:VenueReader tag 54 1` | Look up `Side(54) = 1` |
| `:VenueReader symbols` | Search and select arriving document symbols with Snacks |

## Symbol picker

With `folke/snacks.nvim`, run `:VenueReader symbols` to browse the hierarchy of
FIX messages, groups and fields. Search includes results as they arrive. See
`:help venue-reader-symbols` for options.

With Snacks installed and the picker enabled, this optional FIX-buffer mapping
opens the symbol tree:

```lua
-- ~/.config/nvim/ftplugin/fix.lua
vim.keymap.set("n", "<localleader><localleader>", "<cmd>VenueReader symbols<cr>", {
  buffer = true,
  desc = "Venue Reader symbols",
})
```

## Summaries

Choose a mode with `:VenueReader summary above`, or set `summary.mode`.

| Mode | Display |
| --- | --- |
| `front` (default) | Inline before the raw message |
| `above` | Virtual line above the message |
| `hidden` | Hide inline annotations and keep the cached summary available through `current_summary()` |
| `codelens` | Native CodeLens above the message |
| `off` | No summary |

Use the cached current message summary in another UI component:

```lua
-- A winbar expression; the plugin does not own your winbar settings.
vim.wo.winbar = [[%!luaeval('require("venue-reader").current_summary({ format = "statusline", details = false })')]]
```

Set `details = false` to omit automatically appended details in any format.
An explicit `{details}` in the template is retained. Older servers return the
full summary.

`current_summary()` returns plain text; `format = "chunks"` returns native virtual
text chunks. The accessor also works alongside front/above modes and sends no
requests on cursor movement. See `:help venue-reader-current-summary`.

See [Summaries](https://github.com/sergluka/venue-reader.nvim/wiki/Summaries)
or `:help venue-reader-modes`.

## Highlights

Front and above summaries use server semantic types over the
`VenueReaderSummary` base group, which can supply a background. Set
`summary.semantic_highlighting = false` for uniform base styling. Native CodeLens
uses `LspCodeLens` and native field hints use `LspInlayHint`. Semantic highlights
can alternate backgrounds for repeating-group entries while preserving field
foregrounds.

![Repeating-group entries use alternating backgrounds at each nesting level.](docs/group-colours.svg)

See [Highlights](https://github.com/sergluka/venue-reader.nvim/wiki/Highlights)
or `:help venue-reader-styling`.

## Optional syntax and documentation

If a working FIX Tree-sitter parser is already installed, the plugin uses it
without downloading or rebuilding it. Otherwise installation can use
nvim-treesitter `main`; a missing manager, toolchain or failed download leaves
LSP available. Tree-sitter does not decode messages or extend server limits.

See [Tree-sitter](https://github.com/sergluka/venue-reader.nvim/wiki/Tree-sitter)
and `:help venue-reader-treesitter` for SOH conceal, selection, explicit
field/message navigation mappings and large-file policy.

Start with `:help venue-reader` for the full offline guide, including setup,
commands, annotations, syntax, troubleshooting and development. The
[help index](doc/venue-reader.txt) links its topic files.

See the [plugin wiki](https://github.com/sergluka/venue-reader.nvim/wiki/Home) for the online guide.

Development commands and platform acceptance status are in
[Contributing](https://github.com/sergluka/venue-reader.nvim/wiki/Contributing),
`:help venue-reader-development` and [tests/ACCEPTANCE.md](tests/ACCEPTANCE.md).

From the plugin checkout, run `make dev SERVER_DIR=/path/to/server-checkout`.
Any directory layout is supported with an explicit server path; plain `make dev`
can detect supported layouts automatically. See `:help venue-reader-dev-launcher`.

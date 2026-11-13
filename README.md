# venue-reader.nvim

An optional Neovim adapter for the [Venue Reader language server](https://github.com/sergluka/venue-reader).
Requires Neovim 0.12+. The server also works with Neovim's native LSP client
without this plugin.

The plugin reuses or installs the server, renders message summaries and adds
decoded yank and dictionary helpers. Hover, diagnostics, code actions, document
symbols, field hints and semantic highlighting use Neovim's native LSP support.
With optional Snacks, browse and search FIX messages, groups, and fields in a
tree, even while the list is still loading.
Optional Tree-sitter adds base highlighting, SOH conceal and structural selection
and navigation. It is not required for LSP features.

## Installation

Choose one method. The repository is currently private; GitHub access is required.
This development branch requires a compatible local server through `server.cmd`
or native `cmd`.
The pinned release does not yet support structured summaries; automatic
installation reports this until a compatible release is pinned.

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
    opts = {}, -- adapter options
    config = function(_, opts)
      vim.lsp.config("venue_reader", { settings = { fix = {} } })
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
require("venue-reader").setup()
```

Update with `:lua vim.pack.update({ "venue-reader.nvim" })`.

Without native `cmd`, server discovery starts with a named FIX buffer. It reuses
a compatible `server.cmd`, PATH binary or managed installation, in that order. Otherwise it installs
the [pinned server](lua/venue-reader/release.json) asynchronously, checking SHA-256.
An invalid explicit command reports an error. Compatible installations are reused
without automatic upgrades or PATH changes.

Linux automatic artifacts require x86_64/glibc >=2.35. macOS and Windows artifacts
are listed in the manifest, but native validation there remains outstanding.
Installation tools and manual/offline setup are described in
[Installation](https://github.com/sergluka/venue-reader.nvim/wiki/Installation)
and `:help venue-reader-setup`.

## Configuration

Defaults work with `setup()`. Server settings belong to native LSP configuration;
summary placement belongs to the adapter:

```lua
vim.lsp.config("venue_reader", {
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
    auto_install = false,
  },
  treesitter = { enabled = false },
})
```

`server.cmd` is an argv list; its executable must support `--version`. Native
`cmd` takes precedence and bypasses acquisition. Configure native `cmd`, `root_dir`
and callbacks before setup; the adapter preserves them and composes required
hooks. Project/modeline settings keep precedence.

Changes to `vim.lsp.config` settings apply to new clients; use
`:VenueReader restart` or explicitly update an attached client's settings and
send `workspace/didChangeConfiguration`. Repeated setup changes adapter options,
including only the three summary keys it manages. See
[plugin configuration](https://github.com/sergluka/venue-reader.nvim/wiki/Configuration),
`:help venue-reader-setup` and the server's
[settings reference](https://github.com/sergluka/venue-reader/wiki/Configuration-Reference).

## First use

Open a `*.fix` file, or use `:set ft=fix`. LSP attachment requires a normal buffer
with a name; `:file /path/log.fix` assigns one without saving. Buffers share a
client under the nearest `.venue-reader.toml` root, otherwise their directory,
unless native `root_dir` supplies another rule.

Use native LSP interfaces, for example `:lua vim.lsp.buf.hover()` and
`:lua vim.lsp.buf.document_symbol()`. The plugin sets no user keybindings.

| Command | Purpose |
| --- | --- |
| `:VenueReader status` | Inspect server, annotations and optional grammar state |
| `:checkhealth venue-reader` | Check requirements and current state |
| `:VenueReader restart` | Restart the configured transport through native LSP |
| `:VenueReader install server` | Retry server discovery/installation |
| `:VenueReader install grammar` | Retry optional FIX parser acquisition |
| `:VenueReader dictionary` | Choose a server dictionary with `vim.ui.select` |
| `:VenueReader settings` | Preview effective settings, sources and warnings |
| `:VenueReader tag 54 1` | Look up `Side(54) = 1` |
| `:VenueReader symbols` | Search and select arriving document symbols with Snacks |

The optional symbol picker requires `folke/snacks.nvim`. It shows `Loading symbols…`
while receiving results, with a percentage when the server supplies one. Search applies to received
symbols; the server's depth and item limits still apply. A truncation marker is
filtered like any other entry. Closing or selecting cancels remaining work;
editing the source clears old locations and restarts after a short pause.
Native `vim.lsp.buf.document_symbol()` and `Snacks.picker.lsp_symbols()` remain
available independently. `require("venue-reader").symbols()` returns a Snacks
picker and defaults to `tree = true`, `keep_parents = true`, and all FIX symbol
kinds (`filter = { fix = true }`).
Use `filter = { fix = { "Object", "Field", "Array" } }` to select kinds.
See `:help venue-reader-symbols` for options.

With Snacks installed and the picker enabled, this optional FIX-buffer mapping
opens the symbol tree:

```lua
-- ~/.config/nvim/ftplugin/fix.lua
vim.keymap.set("n", "<localleader><localleader>", "<cmd>VenueReader symbols<cr>", {
  buffer = true,
  desc = "Venue Reader symbols",
})
```

`<localleader>` uses `vim.g.maplocalleader` (for example, `,,` when it is `,`).

Decode the field under the cursor with `:VenueReader yank`, or lines with
`:10,20VenueReader yank a`, then paste normally with `p`/`P`. For a decoded
Normal/Visual operator, add:

```lua
vim.keymap.set({ "n", "x" }, "<leader>y", "<Plug>(VenueReaderYank)")
```

Motions, textobjects, counts and repeat use Neovim's native operator support.
Register behavior and character/line/block selections are documented in
[Commands](https://github.com/sergluka/venue-reader.nvim/wiki/Commands)
and `:help venue-reader-commands`.

## Summaries and highlighting

Choose a mode with `:VenueReader summary above`, or set `summary.mode`:

| Mode | Display | Styling |
| --- | --- | --- |
| `front` (default) | Inline before the raw message | `VenueReaderSummary` |
| `above` | Virtual line above the message | Same custom styling as front |
| `hidden` | No annotation; summary available to UI components | Same semantic data |
| `codelens` | Native CodeLens above the message | `LspCodeLens` |
| `off` | No summary | Other LSP features remain available |

The server supplies the same summary text/details through either channel.
Front/above parts use the server semantic types over the `VenueReaderSummary`
base group, which can supply a background. Set
`summary.semantic_highlighting = false` for uniform base styling. Native field
hints use `LspInlayHint`; semantic highlights can alternate backgrounds for
repeating-group entries while preserving field foregrounds.

Use the cached current message summary in another UI component:

```lua
-- A winbar expression; the plugin does not own your winbar settings.
vim.wo.winbar = '%!v:lua.require("venue-reader").current_summary({format="statusline"})'
```

`current_summary()` returns plain text; `format = "chunks"` returns native virtual
text chunks. The accessor also works alongside front/above modes and sends no
requests on cursor movement. See `:help venue-reader-current-summary`.

![Repeating-group entries use alternating backgrounds at each nesting level.](docs/group-colours.svg)

The plugin respects server processing limits. Oversized native inlay requests can
omit summaries and field hints; CodeLens and semantic responses have separate
limits. The plugin does not split requests, scan FIX text or recover omitted
results. See [Summaries](https://github.com/sergluka/venue-reader.nvim/wiki/Summaries)
and [Highlights](https://github.com/sergluka/venue-reader.nvim/wiki/Highlights),
or `:help venue-reader-modes` and `:help venue-reader-styling`.

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

The wiki is prepared in the sibling `venue-reader.nvim.wiki` repository.
Its [online pages](https://github.com/sergluka/venue-reader.nvim/wiki/Home) will
become available after publication, when the project is public. Until then,
read that checkout locally or use the bundled help.

Development commands and platform acceptance status are in
[Contributing](https://github.com/sergluka/venue-reader.nvim/wiki/Contributing),
`:help venue-reader-development` and [tests/ACCEPTANCE.md](tests/ACCEPTANCE.md).

From the plugin checkout, run `make dev SERVER_DIR=/path/to/server-checkout`.
Any directory layout is supported with an explicit server path; plain `make dev`
can detect supported layouts automatically. See `:help venue-reader-dev-launcher`.

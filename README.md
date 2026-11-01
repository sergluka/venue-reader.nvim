# venue-reader.nvim

Server: [Venue Reader](https://github.com/sergluka/venue-reader).

An optional Neovim wrapper and adapter for Venue Reader. The server also works
with Neovim's native LSP client without this plugin. Requires Neovim 0.12+.

Server discovery, installation and LSP lifecycle are available. Native hover,
diagnostics, code actions, links, selections and document symbols use Neovim's
standard LSP interfaces. Front/above summary rendering and native CodeLens are
available. Native field hints and semantic highlight defaults are included.
Decoded yank and optional grammar management are still TODO.

## Development

The headless tests use [mini.test](https://github.com/nvim-mini/mini.test) and
Neovim's built-in LSP client, including the plugin lifecycle.
The real-server suite checks a named, unsaved FIX buffer against the published
Venue Reader binary. The transport suite controls responses explicitly to test
ordering, cancellation, startup failure and server exit.

Use Neovim 0.12+, Make, Git, StyLua and Luacheck. Preparation uses `curl` and `tar`
(`unzip` for Windows archives). Tested tool versions and pinned server release
identifiers are recorded in [tests/dependencies.json](tests/dependencies.json) and
[lua/venue-reader/release.json](lua/venue-reader/release.json).
Python is not required. mini.test is a development-only dependency, pinned to
v0.18.0 commit `35c67cb7f2dc697ed0c7c06400fcf29a8a521d7d`.

From this repository, prepare mini.test and the pinned server once:

```sh
make prepare
```

Preparation clones the pinned mini.test release into `.test-deps/mini.test`.
It also selects a platform archive for server v0.1.0, verifies its pinned
SHA-256 and stores the binary and notices in the ignored `.test-deps/` directory.
It does not change PATH. Once mini.test is prepared, supply a release archive
to prepare the server without downloading:

```sh
make prepare ARCHIVE=/path/to/venue-reader-x86_64-unknown-linux-gnu.tar.gz
```

After preparation, checks and tests run without network access:

```sh
make lint
make test
make test SUITE=real_server
make test SUITE=transport
make test SUITE=dependencies
make test SUITE=lifecycle
make test SUITE=installation
make test SUITE=summaries
make test SUITE=highlights
```

`transport` and `dependencies` need no server binary; `make prepare-tests` prepares
mini.test alone. The installation suite needs the prepared Linux release archive
for its offline fixtures. Normal tests verify the framework revision and never
download from the network.
Tests isolate Neovim configuration, data, state and working directory in a
temporary directory. mini.test runs the cases, reports results and returns a
nonzero exit status on failure. Its finalizers clean up clients and buffers.
The startup-failure case
intentionally produces a server-exit warning with code 7.

For local server development, pass an explicit override:

```sh
make test SUITE=real_server SERVER=/absolute/path/to/venue-reader
```

The runner labels overrides separately; their results are not release-artifact
evidence. `make test NVIM=/path/to/nvim` selects another Neovim executable. The prepared
release archive and extracted binary are rechecked before release tests.

Format changed files with `make format`. The Makefile only coordinates standard
commands; tests can also be launched directly:

```sh
nvim --headless -u NONE -i NONE -l scripts/test.lua transport
nvim --headless -u NONE -i NONE -l scripts/prepare.lua /path/to/release-archive.tar.gz
```

Local validation currently covers Linux x86_64 with Neovim 0.12.5. The manifest
also identifies macOS and Windows artifacts; native tests on those platforms and
the minimum supported Neovim remain outstanding.

## Installation

Add this repository to your plugin manager, then call setup. No other Neovim
plugin is required. Server discovery starts when a named FIX buffer is opened.

```lua
require("venue-reader").setup()
```

Discovery reuses a compatible explicit command, PATH executable or managed
installation, in that order. Stable server versions `>=0.1.0,<0.2.0` are accepted.
An invalid explicit command produces an error; it is never silently replaced.
If none is found, the plugin asynchronously installs pinned v0.1.0 under
`stdpath("data")/venue-reader/`, verifying SHA-256 before extraction. Compatible
installations are reused without automatic upgrades or PATH changes.

Automatic installation uses curl, tar and sha256sum on Linux; curl, tar and
shasum on macOS; curl.exe, tar.exe and certutil.exe on Windows. Missing tools or
unsupported targets report a manual installation path. Linux automatic artifacts
require x86_64/glibc >=2.35. macOS x86_64/aarch64 and Windows x86_64 artifacts are
listed in the manifest; native validation there remains outstanding.

## Configuration

For an existing binary or offline use:

```lua
require("venue-reader").setup({
  server = {
    cmd = { "/absolute/path/to/venue-reader", "--stdio" },
    auto_install = false,
  },
  summary = { mode = "front", highlight = "VenueReaderSummary" },
  settings = { fix = {} },
})
```

`server.cmd` is an argv list, without shell parsing. Its executable must support
`--version`. Repeated setup is safe; settings update live, while executable
changes require `:VenueReader restart`. Server settings retain project/modeline
precedence. Empty `settings.fix` is sent as a JSON object.

## Usage

Open a `*.fix` file, or use `:set ft=fix`. A buffer must have an explicit name;
`:file /path/log.fix` assigns one without saving, and `:saveas` also works.
Renaming closes the old server document before opening the new one. The project
root is the nearest parent containing `.venue-reader.toml`, otherwise the file's
directory. Buffers in the same managed session share a client.

- `:VenueReader start` delegates to `:lsp enable venue_reader`.
- `:VenueReader stop` delegates to `:lsp stop venue_reader`.
- `:VenueReader restart` resolves the executable, then delegates to native restart
  (or enable when no client is running).
- `:VenueReader summary front|above|codelens|off` selects the session summary mode.
- `:VenueReader status` shows session, binary, version, acquisition and failure state.
- `:VenueReader install server` explicitly retries discovery/installation.
- `:checkhealth venue-reader` reports version requirements and current state.

Equivalent Lua functions are `start`, `stop`, `restart`, `status`, `install` and
`summary(mode)`.
The helpers use native command scope: they target all clients named
`venue_reader`, including different roots. Native restart preserves attached
buffers. Stop terminates current clients; use `:lsp disable venue_reader` to
prevent future automatic attachment, and `:lsp enable venue_reader` to resume.
After a crash, native Neovim reports the exit; enable attaches eligible buffers
again. There is no separate plugin suppression or automatic recovery loop.
Other clients' diagnostics/providers are preserved. No default mappings are added.

## Summary modes

The server generates the same summary text/details for each channel; the mode
changes placement and styling. One summary backend is active at a time.

| Mode | Display | Styling and limits |
| --- | --- | --- |
| `front` (default) | Inline before the raw message | `VenueReaderSummary`; native inlay request range limit |
| `above` | Virtual line above the raw message | Same content and custom highlight as front |
| `codelens` | Native CodeLens above the message | Native `LspCodeLens` styling and document cap |
| `off` | No summary | Native fields and other features remain available |

```vim
VenueReader summary above
VenueReader summary codelens
VenueReader summary off
```

```lua
require("venue-reader").summary("front")
```

Custom modes use one configurable summary highlight. Server label parts/padding
are preserved, without inferred route or main/detail colours. Above separates
summaries from raw fields but consumes vertical space; front shifts raw text
horizontally. Neither changes buffer bytes or copied text. CodeLens uses Neovim's
renderer; custom highlight/placement settings do not apply to it.

Neovim sends requests and handles refresh, field hints and semantic highlighting.
The plugin intercepts only its client's summary hints (`data.kind = "summary"`)
and draws them with owned extmarks. It does not split ranges, raise limits, scan
FIX messages or schedule viewport requests. Display metadata comes in the initial
inlay response, with no per-message metadata requests.

Selecting front/above enables native inlay hints on attached FIX buffers. This
native gate is buffer-wide, so other clients' field hints also become enabled and
continue to render natively. An explicit native disable is respected until the
next managed attachment (including rename/restart) or explicit mode activation:

```lua
vim.lsp.inlay_hint.enable(false, { bufnr = 0 })
```

CodeLens mode opts into native CodeLens. Native disable is reported without an
automatic fallback. Mode changes set `fix.messageSummary.channels.inlayHints`
and `codeLens`; contradictory explicit setup values are rejected. Project/modeline
settings keep their higher priority. Status/health report effective conflicts and
sources rather than overriding them. After correcting a blocking override, select
the desired mode again to reactivate its backend. A coalesced document configuration lookup
uses `fix.describeOverrides`; no request is made per summary/message.

Native inlay requests currently cover the whole buffer in tested Neovim0.12.5.
When the document exceeds effective `limits.rangeLines` (2000 by default), the
server returns no inlay hints: both custom summaries and field hints can be absent.
Native CodeLens has its own `limits.codeLensLines` (20000 by default). Status/health
show effective limits and document size; until configuration is ready they report
pending. There is no cap increase, range splitting or automatic mode fallback.

Editing hides old custom summaries until a current response arrives. Tailing a
log can therefore briefly hide summaries on each append. Initial native LSP
requests may report that document configuration is not ready; subsequent native
server refresh supplies current data. The plugin adds no retry loop.

## Field hints and semantic colours

Neovim renders tag names, enum labels and group paths as native inlay hints.
Configure their server output through the existing settings:

```lua
require("venue-reader").setup({
  settings = { fix = {
    inlayHints = {
      tagNames = { enabled = true },
      enumValues = { enabled = true },
      groupPaths = { enabled = true },
    },
    semanticTokens = { enabled = true },
  } },
})
```

Group paths require tag-name hints; disabling tag names also removes group paths.
Project/modeline settings keep their normal precedence. Field settings apply to
the server session; the native inlay enable gate is buffer-wide. In codelens/off
summary mode, enable field hints explicitly if needed:

```lua
vim.lsp.inlay_hint.enable(true, { bufnr = 0 })
```

All native inlay labels use `LspInlayHint`. Group backgrounds colour source text,
not individual virtual labels. The plugin adds these filetype-scoped defaults:

| Semantic highlight | Default |
| --- | --- |
| `@lsp.type.price.fix`, `@lsp.type.quantity.fix`, `@lsp.type.money.fix` | Link to `@number` |
| `@lsp.type.timestamp.fix` | Link to `@string` |
| `@lsp.typemod.group.group1a.fix`, `group1b.fix` | Background from `DiffAdd`, `DiffChange` |
| `@lsp.typemod.group.group2a.fix`, `group2b.fix` | Background from `DiffDelete`, `DiffText` |
| `@lsp.typemod.group.group3a.fix`, `group3b.fix` | Background from `Pmenu`, `Folded` |

### Repeating-group hierarchy and alternating colours

The server supplies a custom semantic token type `group` for a whole-entry
background overlay. Its modifier `group1a`, for example, selects a nesting level
and one of two alternating colours. Neovim combines these into the highlight
name `@lsp.typemod.group.group1a.fix`; `.fix` scopes it to the FIX filetype.

| Nesting level | Colour pair | Adjacent entries in one group |
| --- | --- | --- |
| 1 (outermost) | `group1a` / `group1b` | `1a → 1b → 1a → …` |
| 2 | `group2a` / `group2b` | `2a → 2b → 2a → …` |
| 3 and deeper | `group3a` / `group3b` | `3a → 3b → 3a → …` |

At each level, odd-numbered entries use `a` and even-numbered entries use `b`.
These interleaved colours distinguish neighbouring entries; `a` and `b` do not
identify different group types. Each group starts its own alternation at `a`,
including a nested group under a new parent entry.

![Three FIX group entries alternate green, blue, green. Nested entries use a separate colour pair at each level, restarting at a under a new parent.](docs/group-colours.svg)

The first example shows three entries in `NoMDEntries(268)` within one synthetic
message. The second shows the nesting hierarchy schematically. Colours are
illustrative; themes may give the pairs different or identical backgrounds.

Background defaults use only the source theme group's RGB/terminal background,
leaving field foregrounds intact. Source `reverse`/`standout` attributes are not
interpreted: only explicit `bg`/`ctermbg` values are copied. A missing background
leaves that overlay unstyled, even if the source uses a reversed foreground.
Existing theme/user definitions win. Defaults are reapplied after `ColorScheme`;
theme-derived backgrounds are recalculated when the scheme clears highlights.
Colours are shared by FIX buffers, rather than configured per buffer/window.

Customize them through standard Neovim highlights, in your `ColorScheme` callback
for persistence across theme changes:

```lua
vim.api.nvim_set_hl(0, "@lsp.type.price.fix", { link = "@number" })
vim.api.nvim_set_hl(0, "@lsp.typemod.group.group1a.fix", { bg = "#203028" })
```

After setup, use `{}` for an overlay highlight to clear its background; a later
setup or colour-scheme reset can restore defaults for empty groups. Avoid setting
backgrounds on generic `@lsp.mod.group1a.fix` groups: both the overlay and individual
source fields carry group identity. Semantic rendering, encoding,
refresh and limits remain native/server-owned. No Tree-sitter grammar is required;
when present, its base highlighting follows Neovim's normal priority rules.
Full/delta semantic responses cover the server's bounded prefix
(`limits.semanticTokensFullLines`, default 2000 lines); the plugin does not fetch
additional ranges to extend it.

## Tree-sitter and command adapters

TODO: Optional grammar installation, syntax/textobjects and decoded yank.
Tree-sitter is not required for server startup or lifecycle commands.

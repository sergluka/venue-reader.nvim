# Integration acceptance

Run the tests against the published server selected by
[lua/venue-reader/release.json](../lua/venue-reader/release.json), with dependency
pins from [tests/dependencies.json](dependencies.json). `SERVER` overrides are
labelled separately and do not establish release-artifact acceptance.

## Local checks

```sh
make prepare
make lint
make test
make test NVIM=/absolute/path/to/minimum-supported/nvim
```

Capture the combined workflow and rendering evidence explicitly:

```sh
VENUE_READER_ACCEPTANCE_OUTPUT=/absolute/path/to/evidence make test SUITE=acceptance
```

Large-log checks are opt-in and have an independent timeout:

```sh
make stress
```

The stress runner uses the verified published server and isolated XDG directories
for 10,000 and 100,000 synthetic lines. Results default to `.test-deps/stress/`;
set `VENUE_READER_ACCEPTANCE_OUTPUT` to select another directory. Request metadata
and post-GC Lua samples are observations, not a portable RSS budget or a claim
that native requests are always viewport-bounded.

The runner prints elapsed time, including preparation verification and child
execution. Record it alongside the exit status. Normal tests are offline and
retain their existing 60-second child / 55-second mini.test limits. Preparation
requires the documented development tools. Record the plugin commit/dirty state,
OS/architecture, exact Neovim/server/dependency versions and artifact checksums
with each acceptance run. Reuse the documented isolated grammar smoke for an
actual optional-parser installation check.

## Progressive document symbols

`make test SUITE=symbols` uses Python 3 to run a controlled stdio LSP peer and the
pinned Snacks sources prepared by `make prepare-tests`. The headless runner
initializes Snacks and its picker explicitly without replacing `vim.ui.select`.
It checks the real picker and native transport, including early selection, live queries,
ordinary marker filtering, cancellation, edits, failures and progress routing.
The public command is also checked through a managed native client. A fresh
Neovim without Snacks verifies setup, disabling/re-enabling the picker command,
and native LSP document symbols while the picker is disabled.

Cursor-selection cases cover nested full ranges, late batches, manual input,
source edits, and UTF-16 positions. The real-server suite also opens the public
picker from tag and value positions near the end of a 300-line synthetic file
and verifies that the corresponding field is selected.

## Native macOS checks — NOT RUN

These are placeholders for execution on native macOS, separately for each claimed
architecture. Linux test results and archive checksums do not establish this row.
Uncomment and run only on the target host with the development tools installed.

```sh
# TODO: record macOS version, architecture, Neovim version and artifact digests.
# nvim --headless -u NONE -i NONE -l scripts/prepare.lua
# nvim --headless -u NONE -i NONE -l scripts/test.lua
# TODO: verify fresh managed-server installation in isolated XDG directories.
# TODO: record front/above/CodeLens, decoded yank and Unicode smoke evidence.
# TODO: verify LSP with the optional grammar absent or failing to install.
```

## Native Windows checks — NOT RUN

These are placeholders for native Windows execution; they are not enabled tests
or a support claim. Use PowerShell with the documented tools available on PATH.

```powershell
# TODO: record Windows version, architecture, Neovim version and artifact digests.
# nvim --headless -u NONE -i NONE -l scripts/prepare.lua
# nvim --headless -u NONE -i NONE -l scripts/test.lua
# TODO: verify fresh managed-server installation in isolated application directories.
# TODO: record front/above/CodeLens, decoded yank and Unicode smoke evidence.
# TODO: verify LSP with the optional grammar absent or failing to install.
```

For either platform, keep the native smoke isolated from personal configuration.
Record failed or blocked checks explicitly, including missing toolchains; do not
turn a placeholder into a pass. A parser build failure must leave LSP usable.

# venue-reader.nvim

Server: [Venue Reader](https://github.com/sergluka/venue-reader).

This repository has been initialized. Plugin functionality is not implemented yet.

## Development

The headless tests use [mini.test](https://github.com/nvim-mini/mini.test) and
Neovim's built-in LSP client, independently of the future plugin lifecycle.
The real-server suite checks a named, unsaved FIX buffer against the published
Venue Reader binary. The transport suite controls responses explicitly to test
ordering, cancellation, startup failure and server exit.

Use Neovim 0.12+, Make, Git, StyLua and Luacheck. Preparation uses `curl` and `tar`
(`unzip` for Windows archives). Tested tool versions and pinned server release
identifiers are recorded in [tests/dependencies.json](tests/dependencies.json).
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
```

`transport` and `dependencies` need no server binary; `make prepare-tests` prepares
mini.test alone. Normal tests verify the framework revision and never download.
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

## Overview

TODO: Describe implemented capabilities and the relationship to the server.

## Installation

TODO: Add tested installation instructions and requirements.

## Configuration

TODO: Document supported settings and provide working examples.

## Summary modes

TODO: Explain implemented modes and their differences with examples.

## Usage

TODO: Document implemented commands and workflows.

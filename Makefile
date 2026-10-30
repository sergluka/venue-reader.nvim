NVIM ?= nvim
export VENUE_READER_TEST_SERVER = $(SERVER)
export VENUE_READER_TEST_ARCHIVE = $(ARCHIVE)
export VENUE_READER_TEST_SUITE = $(SUITE)
export NVIM_LOG_FILE = $(CURDIR)/.test-deps/nvim.log

.PHONY: test prepare prepare-tests lint format
test:
	@mkdir -p .test-deps
	"$(NVIM)" --headless -u NONE -i NONE -l scripts/test.lua

prepare:
	@mkdir -p .test-deps
	"$(NVIM)" --headless -u NONE -i NONE -l scripts/prepare.lua

prepare-tests:
	@mkdir -p .test-deps
	"$(NVIM)" --headless -u NONE -i NONE -l scripts/prepare.lua --tests-only

lint:
	stylua --check lua tests scripts
	luacheck lua tests scripts

format:
	stylua lua tests scripts

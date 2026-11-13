local root = assert(vim.env.VENUE_READER_TEST_ROOT)
vim.opt.runtimepath:prepend(root)
local Plugin = require("venue-reader")
assert(#vim.api.nvim_get_runtime_file("lua/snacks/init.lua", false) == 0)
vim.lsp.config("venue_reader", {
  cmd = { "python3", root .. "/tests/support/symbol_server.py" },
})
local settings = {
  treesitter = { enabled = false },
  summary = { mode = "off" },
}
Plugin.setup(settings)
assert(vim.tbl_contains(vim.fn.getcompletion("VenueReader ", "cmdline"), "symbols"))
assert(not package.loaded.snacks and not package.loaded["venue-reader.symbols"])

settings.symbols = { enabled = false }
Plugin.setup(settings)
assert(not vim.tbl_contains(vim.fn.getcompletion("VenueReader ", "cmdline"), "symbols"))
local success, failure = pcall(Plugin.symbols, { enabled = true })
assert(not success and tostring(failure):find("disabled", 1, true))
local message
rawset(vim, "notify", function(value)
  message = value
end)
vim.cmd("VenueReader symbols")
assert(message and message:find("disabled", 1, true))
assert(not package.loaded.snacks and not package.loaded["venue-reader.symbols"])

vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. ".fix")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "8=FIX.4.4|35=0|" })
vim.api.nvim_set_option_value("filetype", "fix", { buf = 0 })
local buffer = vim.api.nvim_get_current_buf()
local client
assert(vim.wait(5000, function()
  client = vim.lsp.get_clients({ name = "venue_reader", bufnr = buffer })[1]
  return client and client.initialized
end, 10))
local result
vim.lsp.buf.document_symbol({
  on_list = function(list)
    result = list.items
  end,
})
local state = client:request_sync("test/state", {}, 5000, buffer)
local request = assert(state.result.requests[1])
local range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 9 } }
client:request_sync("test/final", {
  request = request.id,
  result = { { name = "BeginString", kind = 8, range = range, selectionRange = range } },
}, 5000, buffer)
assert(vim.wait(5000, function()
  return result and #result == 1
end, 10))
assert(result[1].text:find("BeginString", 1, true))
assert(not package.loaded.snacks and not package.loaded["venue-reader.symbols"])
settings.symbols.enabled = true
Plugin.setup(settings)
assert(vim.tbl_contains(vim.fn.getcompletion("VenueReader ", "cmdline"), "symbols"))
assert(not package.loaded.snacks and not package.loaded["venue-reader.symbols"])
vim.lsp.enable("venue_reader", false)
client:stop(true)

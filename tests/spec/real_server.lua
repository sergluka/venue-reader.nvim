local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local equal = MiniTest.expect.equality
local tests = MiniTest.new_set()

tests["released server opens and decodes an unsaved named buffer"] = function()
  local binary =
    assert(vim.env.VENUE_READER_TEST_SERVER, "VENUE_READER_TEST_SERVER must name a prepared binary")
  assert(vim.fn.executable(binary) == 1, "Server binary is not executable: " .. binary)
  local buffer = Lsp.buffer({ "8=FIX.4.4|35=0|" })
  local uri = vim.uri_from_bufnr(buffer)
  assert(vim.fn.filereadable(vim.api.nvim_buf_get_name(buffer)) == 0)
  local diagnostics
  local client = Lsp.start({
    name = "venue-reader-harness",
    cmd = { binary, "--stdio" },
    root_dir = vim.uv.cwd(),
    settings = { fix = vim.empty_dict() },
    handlers = {
      ["textDocument/publishDiagnostics"] = function(response_error, result)
        assert(not response_error)
        if result.uri == uri then
          diagnostics = result
        end
      end,
    },
  }, buffer)
  Lsp.ready(client, buffer)
  equal("venue-reader", client.server_info.name)
  if vim.env.VENUE_READER_TEST_RELEASE == "1" then
    equal("0.1.0", client.server_info.version)
  end
  Lsp.wait(function()
    return diagnostics ~= nil
  end, "document diagnostics after configuration")
  local configuration = Lsp.request(client, "workspace/executeCommand", {
    command = "fix.describeOverrides",
    arguments = { uri },
  }, buffer)
  assert(configuration.effective["limits.rangeLines"] > 0)
  local hover = Lsp.request(client, "textDocument/hover", {
    textDocument = { uri = uri },
    position = { line = 0, character = 12 },
  }, buffer)
  assert(
    hover and hover.contents and hover.contents.value:find("Heartbeat", 1, true),
    vim.inspect(hover)
  )
end

return tests

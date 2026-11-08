local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local release = require("venue-reader.release")
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
    equal(release.version, client.server_info.version)
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

tests["plugin default summaries and native mode transitions use the released server"] = function()
  local Plugin = require("venue-reader")
  Plugin.setup({ server = { cmd = { assert(vim.env.VENUE_READER_TEST_SERVER), "--stdio" } } })
  MiniTest.finally(function()
    vim.lsp.enable("venue_reader", false)
  end)
  local buffer = Lsp.buffer()
  vim.api.nvim_set_current_buf(buffer)
  local namespace = vim.api.nvim_create_namespace("venue-reader.summary")
  Lsp.wait(function()
    vim.cmd("redraw!")
    return #vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, {}) > 0
  end, "default front from release")
  equal(Plugin.status(buffer).annotations.mode, "front")
  Plugin.summary("above")
  Lsp.wait(function()
    vim.cmd("redraw!")
    local marks = vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })
    return marks[1] and marks[1][4].virt_lines_above
  end, "above from release")
  Plugin.summary("codelens")
  Lsp.wait(function()
    return #vim.lsp.codelens.get({ bufnr = buffer }) > 0
  end, "native CodeLens from release")
  equal(#vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, {}), 0)
  Plugin.summary("off")
  equal(Plugin.status(buffer).annotations.mode, "off")
end

tests["local server supplies colored cached hidden summaries in one native response"] = function()
  local plugin = require("venue-reader")
  local binary = assert(vim.env.VENUE_READER_TEST_SERVER)
  plugin.setup({
    server = { cmd = { binary, "--stdio" } },
    treesitter = { enabled = false },
    summary = { mode = "hidden" },
    settings = {
      fix = {
        messageSummary = {
          template = '{34?:"?"} {35.valueName} {43="Y"?"[POSS DUP]"}',
          details = false,
        },
      },
    },
  })
  MiniTest.finally(function()
    vim.lsp.enable("venue_reader", false)
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
      client:stop(true)
    end
  end)
  local buffer = Lsp.buffer({ "8=FIX.4.4|35=0|34=42|43=Y|" })
  vim.api.nvim_set_current_buf(buffer)
  Lsp.wait(function()
    return plugin.current_summary() == "42 Heartbeat [POSS DUP]"
  end, "structured summary from actual server")
  local chunks = plugin.current_summary({ format = "chunks" })
  equal(chunks[1][1], "42")
  assert(
    vim.tbl_contains(chunks[1][2], "@lsp.type.number")
      or vim.tbl_contains(chunks[1][2], "@lsp.type.number.fix")
  )
  equal(chunks[2][2], { "VenueReaderSummary" })
  equal(chunks[#chunks][1], "[POSS DUP]")
  assert(vim.tbl_contains(chunks[#chunks][2], "@lsp.type.flag.fix"))
  local namespace = vim.api.nvim_create_namespace("venue-reader.summary")
  vim.cmd("redraw!")
  equal(vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, {}), {})
  local client = vim.lsp.get_clients({ name = "venue_reader", bufnr = buffer })[1]
  local requests = vim.deepcopy(client.requests)
  equal(plugin.current_summary(), "42 Heartbeat [POSS DUP]")
  equal(client.requests, requests)
end

return tests

local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local release = require("venue-reader.release")
local equal = MiniTest.expect.equality
local tests = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.lsp.config["venue-reader"] = {} -- luacheck: ignore 122
    end,
  },
})

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

local function code_actions(capabilities)
  local diagnostics = {}
  local original_select = vim.ui.select
  vim.lsp.config("venue-reader", {
    capabilities = capabilities,
    handlers = {
      ["textDocument/publishDiagnostics"] = function(err, result, context)
        if not err and result then
          diagnostics[result.uri] = result
        end
        return vim.lsp.handlers["textDocument/publishDiagnostics"](err, result, context)
      end,
    },
  })
  require("venue-reader").setup({
    server = { cmd = { assert(vim.env.VENUE_READER_TEST_SERVER), "--stdio" } },
  })
  MiniTest.finally(function()
    rawset(vim.ui, "select", original_select)
    vim.lsp.enable("venue-reader", false)
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue-reader" })) do
      client:stop(true)
    end
    Lsp.wait(function()
      return #vim.lsp.get_clients({ name = "venue-reader" }) == 0
    end, "code-action client cleanup")
  end)
  local buffer = Lsp.buffer()
  local uri = vim.uri_from_bufnr(buffer)
  vim.api.nvim_set_current_buf(buffer)
  local client
  Lsp.wait(function()
    client = vim.lsp.get_clients({ name = "venue-reader", bufnr = buffer })[1]
    return client and client.initialized and diagnostics[uri] ~= nil
  end, "code-action document configuration")
  local function current_diagnostics()
    Lsp.wait(function()
      return diagnostics[uri].version == vim.lsp.util.buf_versions[buffer]
    end, "diagnostics for the current document version")
    return diagnostics[uri].diagnostics
  end
  local function select_action()
    local choice, select
    rawset(vim.ui, "select", function(items, options, callback)
      equal(options.kind, "codeaction")
      equal(#items, 1)
      choice, select = items[1], callback
    end)
    vim.lsp.buf.code_action({ context = { only = { "quickfix" } } })
    Lsp.wait(function()
      return choice ~= nil
    end, "native code-action picker")
    return choice,
      function(selected)
        select(selected)
        Lsp.wait(function()
          return next(client.requests) == nil
        end, "native action resolution and application")
      end
  end
  return buffer, client, current_diagnostics, select_action
end

tests["plugin defaults offer and apply a native integrity quick fix"] = function()
  local buffer, client, diagnostics, select_action = code_actions()
  equal(client:supports_method("textDocument/codeAction", buffer), true)
  equal(client.capabilities.workspace.workspaceEdit.documentChanges, true)
  local initial_codes = vim.tbl_map(function(diagnostic)
    return diagnostic.code
  end, diagnostics())
  assert(vim.list_contains(initial_codes, "bodyLength"))
  assert(vim.list_contains(initial_codes, "checkSum"))
  local choice, select = select_action()
  equal(choice.action.kind, "quickfix")
  equal(choice.action.edit.documentChanges[1].textDocument.version, 0)
  select(choice)
  equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { "8=FIX.4.4|9=5|35=0|10=163|" })
  for _, diagnostic in ipairs(diagnostics()) do
    assert(
      diagnostic.code ~= "bodyLength" and diagnostic.code ~= "checkSum",
      vim.inspect(diagnostic)
    )
  end
end

tests["native code actions reject stale edits from positive document versions"] = function()
  local buffer, _, diagnostics, select_action = code_actions()
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "8=FIX.4.4|35=0|34=1|" })
  diagnostics()
  local choice, select = select_action()
  local version = choice.action.edit.documentChanges[1].textDocument.version
  assert(version > 0)
  local newer = { "8=FIX.4.4|35=1|112=synthetic|" }
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, newer)
  diagnostics()
  assert(vim.lsp.util.buf_versions[buffer] > version)
  select(choice)
  equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), newer)
end

tests["explicit documentChanges refusal keeps the real server provider disabled"] = function()
  local buffer, client =
    code_actions({ workspace = { workspaceEdit = { documentChanges = false } } })
  equal(client.capabilities.workspace.workspaceEdit.documentChanges, false)
  equal(client:supports_method("textDocument/codeAction", buffer), false)
  equal(client.server_capabilities.codeActionProvider, nil)
end

tests["plugin default summaries and native mode transitions use the released server"] = function()
  local Plugin = require("venue-reader")
  Plugin.setup({ server = { cmd = { assert(vim.env.VENUE_READER_TEST_SERVER), "--stdio" } } })
  MiniTest.finally(function()
    vim.lsp.enable("venue-reader", false)
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
  vim.lsp.config("venue-reader", {
    settings = {
      fix = {
        messageSummary = {
          template = '{34?:"?"} {35.valueName} {43="Y"?"[POSS DUP]"}',
          details = false,
        },
      },
    },
  })
  plugin.setup({
    server = { cmd = { binary, "--stdio" } },
    treesitter = { enabled = false },
    summary = { mode = "hidden" },
  })
  MiniTest.finally(function()
    vim.lsp.enable("venue-reader", false)
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue-reader" })) do
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
  local client = vim.lsp.get_clients({ name = "venue-reader", bufnr = buffer })[1]
  local requests = vim.deepcopy(client.requests)
  equal(plugin.current_summary(), "42 Heartbeat [POSS DUP]")
  equal(client.requests, requests)
end

tests["winbar can omit details that the in-buffer summary displays"] = function()
  local plugin = require("venue-reader")
  vim.lsp.config("venue-reader", {
    settings = {
      fix = { messageSummary = { template = "{34} {35.valueName} 100%", details = true } },
    },
  })
  plugin.setup({
    server = { cmd = { assert(vim.env.VENUE_READER_TEST_SERVER), "--stdio" } },
    treesitter = { enabled = false },
    summary = { mode = "front" },
  })
  MiniTest.finally(function()
    vim.lsp.enable("venue-reader", false)
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue-reader" })) do
      client:stop(true)
    end
  end)
  local buffer = Lsp.buffer({ "8=FIX.4.2|35=8|34=2|150=2|" })
  vim.api.nvim_set_current_buf(buffer)
  local main = "2 ExecutionReport 100%"
  local full = main .. " | FILL"
  local namespace = vim.api.nvim_create_namespace("venue-reader.summary")
  Lsp.wait(function()
    vim.cmd("redraw!")
    local marks = vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })
    return marks[1]
      and table.concat(vim.tbl_map(function(chunk)
          return chunk[1]
        end, marks[1][4].virt_text))
        == full .. " "
  end, "in-buffer summary with details")
  equal(plugin.current_summary(), full)
  local text = plugin.current_summary({ details = false })
  local chunks = plugin.current_summary({ details = false, format = "chunks" })
  equal(chunks, vim.list_slice(plugin.current_summary({ format = "chunks" }), 1, #chunks))
  local chunk_text = table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, chunks))
  local winbar =
    "%!v:lua.require'venue-reader'.current_summary({'format': 'statusline', 'details': v:false})"
  local rendered = vim.api.nvim_eval_statusline(winbar, { use_winbar = true }).str
  local client = assert(vim.lsp.get_clients({ name = "venue-reader", bufnr = buffer })[1])
  local hints = Lsp.request(client, "textDocument/inlayHint", {
    textDocument = { uri = vim.uri_from_bufnr(buffer) },
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 1, character = 0 } },
  }, buffer)
  local summary = assert(vim.iter(hints):find(function(hint)
    return hint.data.kind == "summary"
  end))
  local expected = summary.data.templateParts and main or full
  equal(text, expected)
  equal(chunk_text, expected)
  equal(rendered, expected)
end

tests["symbol picker selects the source field from real server ranges"] = function()
  local plugin = require("venue-reader")
  local Symbols = require("tests.support.symbols")
  local picker
  plugin.setup({
    server = { cmd = { assert(vim.env.VENUE_READER_TEST_SERVER), "--stdio" } },
    treesitter = { enabled = false },
    summary = { mode = "off" },
  })
  MiniTest.finally(function()
    if picker then
      Symbols.close(picker)
    end
    vim.lsp.enable("venue-reader", false)
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue-reader" })) do
      client:stop(true)
    end
  end)
  local line = "8=FIX.4.4|35=D|58=Привет|55=SYNTHETIC|54=1|"
  local lines = {}
  for index = 1, 300 do
    lines[index] = line
  end
  local buffer = Lsp.buffer(lines)
  vim.api.nvim_set_current_buf(buffer)
  Lsp.wait(function()
    local client = vim.lsp.get_clients({ name = "venue-reader", bufnr = buffer })[1]
    return client and client.initialized
  end, "real symbol client")
  local field_start = assert(line:find("55=", 1, true))
  for _, column in ipairs({ field_start - 1, field_start + 5 }) do
    vim.api.nvim_win_set_cursor(0, { 300, column })
    vim.cmd("VenueReader symbols")
    picker = require("snacks").picker.get()[1]
    Lsp.wait(function()
      local entry = picker:current()
      return entry and entry.pos[1] == 300 and entry.pos[2] == field_start - 1
    end, "real source field selected beyond the first result window")
    equal(picker:current().kind, "Field")
    assert(picker:current().name:find("SYNTHETIC", 1, true))
    Symbols.close(picker)
    picker = nil
    equal(vim.api.nvim_get_current_buf(), buffer)
  end
end

return tests

local binary = assert(vim.env.VENUE_READER_TEST_SERVER, "A real server binary is required")
local client

local function wait(predicate, description)
  assert(vim.wait(5000, predicate, 10), "Timed out: " .. description)
end

local scenarios = {}
local function check(name, callback)
  local scenario = { name = name, status = "failed" }
  table.insert(scenarios, scenario)
  callback()
  scenario.status = "passed"
  io.stdout:write("PASS native-only: " .. name .. "\n")
end

local function isolated()
  local root = assert(vim.env.VENUE_READER_TEST_ROOT)
  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    assert(not path:find(root, 1, true), "Plugin or test dependencies on runtimepath: " .. path)
  end
  for name in pairs(package.loaded) do
    assert(not name:match("^venue%-reader") and not name:match("^snacks"), name)
  end
  assert(vim.fn.exists(":VenueReader") == 0, "Plugin command leaked into native-only client")
end

local success, failure = xpcall(function()
  check("plugin isolation", isolated)
  local message = "8=FIX.4.4|35=W|268=1|269=0|270=123.45|271=100|"
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_name(buffer, vim.uv.cwd() .. "/native.fix")
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { message })
  vim.api.nvim_set_option_value("filetype", "fix", { buf = buffer })
  local uri = vim.uri_from_bufnr(buffer)
  local publications = {}
  local sent_capabilities
  local settings = {
    fix = {
      messageSummary = {
        template = "{35.valueName}",
        details = false,
        semanticTokens = true,
        channels = { codeLens = true, inlayHints = true },
      },
    },
  }
  local identifier = assert(vim.lsp.start({
    name = "venue-reader-native-only",
    cmd = { binary, "--stdio" },
    root_dir = vim.uv.cwd(),
    settings = settings,
    before_init = function(params)
      sent_capabilities = vim.deepcopy(params.capabilities)
    end,
    handlers = {
      ["textDocument/publishDiagnostics"] = function(error, result, context, config)
        if not error and result then
          publications[result.uri] = result
        end
        return vim.lsp.handlers["textDocument/publishDiagnostics"](error, result, context, config)
      end,
    },
  }, { bufnr = buffer }))
  client = assert(vim.lsp.get_client_by_id(identifier))
  wait(function()
    return client.initialized and publications[uri] ~= nil
  end, "native attachment and initial configuration")

  local function request(method, params)
    local response, error = client:request_sync(method, params, 5000, buffer)
    assert(response, error)
    assert(not response.err, vim.inspect(response.err))
    return response.result
  end

  check("default capability negotiation", function()
    local defaults = vim.lsp.protocol.make_client_capabilities()
    assert(vim.deep_equal(sent_capabilities, defaults), "Native capabilities were augmented")
    local versioned_edits =
      vim.tbl_get(sent_capabilities, "workspace", "workspaceEdit", "documentChanges")
    local literal_actions =
      vim.tbl_get(sent_capabilities, "textDocument", "codeAction", "codeActionLiteralSupport")
    assert(
      client:supports_method("textDocument/codeAction", buffer)
        == not not (versioned_edits and literal_actions)
    )
    assert(not vim.tbl_get(sent_capabilities, "experimental", "venueReader", "summaryTokens"))
    assert(client:supports_method("textDocument/hover", buffer))
  end)

  check("native hover popup", function()
    vim.api.nvim_win_set_cursor(0, { 1, assert(message:find("35=W", 1, true)) - 1 })
    vim.lsp.buf.hover()
    local window
    wait(function()
      for _, candidate in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(candidate).relative ~= "" then
          local lines =
            vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(candidate), 0, -1, false)
          if table.concat(lines, "\n"):find("MarketDataSnapshotFullRefresh", 1, true) then
            window = candidate
            return true
          end
        end
      end
    end, "hover content")
    vim.api.nvim_win_close(window, true)
  end)

  check("native inlay labels and unstyled summary", function()
    vim.lsp.inlay_hint.enable(true, { bufnr = buffer })
    local function hint_text(hint)
      if type(hint.label) == "string" then
        return hint.label
      end
      return table.concat(vim.tbl_map(function(part)
        return part.value
      end, hint.label))
    end
    wait(function()
      local labels = {}
      for _, entry in ipairs(vim.lsp.inlay_hint.get({ bufnr = buffer })) do
        local hint = entry.inlay_hint
        labels[#labels + 1] = hint_text(hint)
        assert(not (hint.data and hint.data.tokens), "Unnegotiated summary styles")
      end
      local text = table.concat(labels, "\n")
      return text:find("NoMDEntries/1/MDEntryType", 1, true)
        and text:find("MarketDataSnapshotFullRefresh", 1, true)
    end, "native hint labels and summary")
  end)

  check("native semantic price highlighting", function()
    local position = assert(message:find("123.45", 1, true)) - 1
    wait(function()
      vim.cmd.redraw()
      for _, token in ipairs(vim.lsp.semantic_tokens.get_at_pos(buffer, 0, position) or {}) do
        if token.type == "price" then
          return true
        end
      end
    end, "price semantic token applied")
  end)

  check("native code-lens summary resolution", function()
    vim.lsp.codelens.enable(true, { bufnr = buffer })
    wait(function()
      vim.cmd.redraw()
      for _, entry in ipairs(vim.lsp.codelens.get({ bufnr = buffer })) do
        local lens = entry.lens
        if lens.command and lens.command.title:find("MarketDataSnapshotFullRefresh", 1, true) then
          assert(lens.command.command == "", "Summary is display-only")
          return true
        end
      end
    end, "resolved summary title")
  end)

  check("native document-symbol navigation list", function()
    local items
    vim.lsp.buf.document_symbol({
      on_list = function(result)
        items = result.items
      end,
    })
    wait(function()
      return items ~= nil
    end, "native symbol list")
    local text = vim.inspect(items)
    assert(text:find("NoMDEntries", 1, true) and text:find("MDEntryPx", 1, true), text)
  end)

  check("native structural selection", function()
    local first = assert(message:find("123.45", 1, true)) - 1
    vim.api.nvim_win_set_cursor(0, { 1, first + 1 })
    vim.lsp.buf.selection_range(1, 5000)
    assert(vim.fn.mode() == "v")
    assert(vim.fn.getpos("v")[3] == first + 1)
    assert(vim.api.nvim_win_get_cursor(0)[2] == first + #"123.45" - 1)
    vim.lsp.buf.selection_range(1, 5000)
    assert(vim.fn.getpos("v")[3] == first - #"270=" + 1)
    vim.cmd.normal({
      args = { vim.api.nvim_replace_termcodes("<Esc>", true, false, true) },
      bang = true,
    })
  end)

  check("diagnostics update after an edit", function()
    assert(#vim.diagnostic.get(buffer) > 0)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "8=FIX.4.4|9=5|35=0|10=163|" })
    wait(function()
      return publications[uri].version == vim.lsp.util.buf_versions[buffer]
        and #vim.diagnostic.get(buffer) == 0
    end, "diagnostics cleared for repaired document")
  end)

  check("manual custom command preserves row identity", function()
    local result = request("workspace/executeCommand", {
      command = "fix.decode",
      arguments = {
        {
          textDocument = { uri = uri },
          ranges = {
            { start = { line = 0, character = 15 }, ["end"] = { line = 0, character = 15 } },
          },
        },
      },
    })
    assert(result.textDocument.version == vim.lsp.util.buf_versions[buffer])
    assert(result.results[1].rangeIndex == 0 and result.results[1].lines[1].line == 0)
    assert(result.results[1].lines[1].text:find("Heartbeat", 1, true))
  end)

  local function replace(lines)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    wait(function()
      return publications[uri].version == vim.lsp.util.buf_versions[buffer]
    end, "new source version")
  end

  check("log formats and mixed FIX identities", function()
    local lines = {
      "# synthetic log",
      "Ж😀 [ 8=FIX.4.4|35=0|",
      "8=FIX.4.2^35=0^",
      "8=FIX.4.4\00135=0\001",
      "8=FIXT.1.1|35=D|1128=9|54=1|",
      "",
    }
    replace(lines)
    local result = request("workspace/executeCommand", {
      command = "fix.decode",
      arguments = {
        {
          textDocument = { uri = uri },
          ranges = {
            { start = { line = 0, character = 0 }, ["end"] = { line = 5, character = 0 } },
          },
        },
      },
    })
    local decoded = result.results[1].lines
    assert(#decoded == #lines)
    assert(decoded[1].text == "" and decoded[6].text == "")
    for i = 2, 4 do
      assert(decoded[i].line == i - 1 and decoded[i].text:find("Heartbeat", 1, true))
    end
    assert(decoded[5].text:find("Buy", 1, true), decoded[5].text)
    local column = assert(lines[2]:find("35=0", 1, true)) - 1
    local hover = request("textDocument/hover", {
      textDocument = { uri = uri },
      position = {
        line = 1,
        character = vim.str_utfindex(lines[2], client.offset_encoding, column, false),
      },
    })
    assert(hover.contents.value:find("Heartbeat", 1, true))
  end)

  check("external dictionary discovery selection and hover", function()
    local dictionary = vim.uv.cwd() .. "/native-dictionary.xml"
    vim.fn.writefile({
      '<fix type="FIX" major="4" minor="4">',
      '<header><field name="BeginString" required="Y"/>',
      '<field name="MsgType" required="Y"/></header>',
      '<messages><message name="SyntheticOrder" msgtype="D" msgcat="app">',
      '<field name="SyntheticField" required="N"/></message></messages><trailer/><components/>',
      '<fields><field number="8" name="BeginString" type="STRING"/>',
      '<field number="35" name="MsgType" type="STRING">',
      '<value enum="D" description="ORDER"/></field>',
      '<field number="9001" name="SyntheticField" type="STRING"/></fields></fix>',
    }, dictionary)
    client.settings.fix.allowDictionaryPath = true
    client.settings.fix.dictionaries = { { name = "native-synthetic", path = dictionary } }
    client:notify("workspace/didChangeConfiguration", { settings = client.settings })
    wait(function()
      local result = request("workspace/executeCommand", { command = "fix.listDictionaries" })
      for _, entry in ipairs(result.dictionaries) do
        if entry.name == "native-synthetic" then
          return true
        end
      end
    end, "custom XML registered")
    local selected = request("workspace/executeCommand", {
      command = "fix.useDictionary",
      arguments = { "native-synthetic" },
    })
    assert(selected.name == "native-synthetic")
    replace({ "8=FIX.4.4|35=D|9001=synthetic|" })
    local hover = request("textDocument/hover", {
      textDocument = { uri = uri },
      position = { line = 0, character = 16 },
    })
    assert(hover.contents.value:find("SyntheticField", 1, true), vim.inspect(hover))
    local effective = request("workspace/executeCommand", {
      command = "fix.describeOverrides",
      arguments = { uri },
    })
    assert(effective.effective.dictionary == "native-synthetic", vim.inspect(effective))
  end)

  check("isolation remains intact after native workflows", isolated)
  local output = vim.env.VENUE_READER_TEST_OUTPUT
  if output and output ~= "" then
    vim.fn.writefile({
      vim.json.encode({
        neovim = vim.version(),
        runtimepath = vim.api.nvim_list_runtime_paths(),
        client_capabilities = sent_capabilities,
        server_capabilities = client.server_capabilities,
        server = client.server_info,
        command = { binary, "--stdio" },
      }),
    }, output .. "/native-capabilities.json")
  end
end, debug.traceback)

if client then
  client:stop(true)
  vim.wait(5000, function()
    return vim.lsp.get_client_by_id(client.id) == nil
  end, 10)
end
if vim.env.VENUE_READER_CASE_REPORT then
  vim.fn.writefile({ vim.json.encode(scenarios) }, vim.env.VENUE_READER_CASE_REPORT)
end
if not success then
  io.stderr:write(failure .. "\n")
  vim.cmd("cquit 1")
end

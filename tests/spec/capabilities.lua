local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local equal = MiniTest.expect.equality
local tests = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.lsp.config.venue_reader = {} -- luacheck: ignore 122
    end,
  },
})

local function session(lines)
  local reports = {}
  local messages = {}
  local original_notify = vim.notify
  local original_select = vim.ui.select
  local windows = vim.api.nvim_list_wins()
  local sent_capabilities
  rawset(vim, "notify", function(message, level, options)
    messages[#messages + 1] = tostring(message)
    return original_notify(message, level, options)
  end)
  vim.lsp.config("venue_reader", {
    before_init = function(params)
      sent_capabilities = vim.deepcopy(params.capabilities)
    end,
    handlers = {
      ["textDocument/publishDiagnostics"] = function(err, result, context, options)
        if not err and result then
          reports[result.uri] = result
        end
        return vim.lsp.handlers["textDocument/publishDiagnostics"](err, result, context, options)
      end,
    },
  })
  require("venue-reader").setup({
    server = { cmd = { assert(vim.env.VENUE_READER_TEST_SERVER), "--stdio" } },
    summary = { mode = "off" },
    treesitter = { enabled = false },
  })
  MiniTest.finally(function()
    rawset(vim, "notify", original_notify)
    rawset(vim.ui, "select", original_select)
    vim.lsp.enable("venue_reader", false)
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
      client:stop(true)
    end
    Lsp.wait(function()
      return #vim.lsp.get_clients({ name = "venue_reader" }) == 0
    end, "capability client cleanup")
    for _, window in ipairs(vim.api.nvim_list_wins()) do
      if
        not vim.list_contains(windows, window)
        and vim.api.nvim_win_get_config(window).relative ~= ""
      then
        vim.api.nvim_win_close(window, true)
      end
    end
  end)
  local buffer = Lsp.buffer(lines)
  vim.api.nvim_set_current_buf(buffer)
  local uri = vim.uri_from_bufnr(buffer)
  local client
  Lsp.wait(function()
    client = vim.lsp.get_clients({ name = "venue_reader", bufnr = buffer })[1]
    return client and client.initialized and reports[uri] ~= nil
  end, "capability document configuration")
  local output = vim.env.VENUE_READER_TEST_OUTPUT
  if output and output ~= "" then
    vim.fn.mkdir(output, "p")
    vim.fn.writefile({
      vim.json.encode({
        nvim = vim.version(),
        runtimepath = vim.api.nvim_list_runtime_paths(),
        client_capabilities = assert(sent_capabilities),
        server_capabilities = client.server_capabilities,
        server_info = client.server_info,
        server_command = { assert(vim.env.VENUE_READER_TEST_SERVER), "--stdio" },
      }),
    }, output .. "/plugin-capabilities.json")
  end
  local fixture = { buffer = buffer, client = client, uri = uri, messages = messages }
  function fixture.diagnostics()
    Lsp.wait(function()
      return reports[uri].version == vim.lsp.util.buf_versions[buffer]
    end, "diagnostics for current text")
    return vim.diagnostic.get(buffer, { namespace = vim.lsp.diagnostic.get_namespace(client.id) })
  end
  function fixture.fix_all()
    local choice, select
    rawset(vim.ui, "select", function(items, options, callback)
      equal(options.kind, "codeaction")
      equal(#items, 1)
      choice, select = items[1], callback
    end)
    vim.lsp.buf.code_action({ context = { only = { "source.fixAll" } } })
    Lsp.wait(function()
      return choice ~= nil
    end, "native fix-all selection")
    equal(choice.action.kind, "source.fixAll")
    assert(choice.action.data, vim.inspect(choice.action))
    equal(choice.action.edit, nil)
    return choice, select
  end
  return fixture
end

tests["native fix-all repairs every message and preserves intervening text"] = function()
  local fixture = session({ "8=FIX.4.4|35=0|", "# keep this comment", "8=FIX.4.4|35=0|" })
  assert(#fixture.diagnostics() >= 4)
  equal(fixture.client.server_capabilities.codeActionProvider.resolveProvider, true)
  local choice, select = fixture.fix_all()
  select(choice)
  local expected = {
    "8=FIX.4.4|9=5|35=0|10=163|",
    "# keep this comment",
    "8=FIX.4.4|9=5|35=0|10=163|",
  }
  Lsp.wait(function()
    return vim.deep_equal(vim.api.nvim_buf_get_lines(fixture.buffer, 0, -1, false), expected)
  end, "native fix-all edit application")
  equal(fixture.diagnostics(), {})
end

tests["native fix-all selection rejects an action discovered before a buffer edit"] = function()
  local fixture = session()
  local choice, select = fixture.fix_all()
  local newer = { "8=FIX.4.4|35=1|112=synthetic|" }
  vim.api.nvim_buf_set_lines(fixture.buffer, 0, -1, false, newer)
  fixture.diagnostics()
  select(choice)
  Lsp.wait(function()
    return vim.iter(fixture.messages):any(function(message)
      return message:find("-32801", 1, true) ~= nil
    end)
  end, "native report of stale action resolution")
  equal(vim.api.nvim_buf_get_lines(fixture.buffer, 0, -1, false), newer)
end

tests["native hover opens dictionary content in a real floating buffer"] = function()
  local fixture = session()
  vim.api.nvim_win_set_cursor(0, { 1, 13 })
  vim.lsp.buf.hover()
  local content
  Lsp.wait(function()
    for _, window in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(window).relative ~= "" then
        local buffer = vim.api.nvim_win_get_buf(window)
        content = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
        if content:find("Heartbeat", 1, true) then
          return true
        end
      end
    end
    return false
  end, "native hover preview")
  assert(content:find("MsgType", 1, true), content)
  assert(content:find("Session", 1, true), content)
  equal(vim.api.nvim_buf_get_lines(fixture.buffer, 0, -1, false), { "8=FIX.4.4|35=0|" })
end

tests["native field hints resolve real dictionary tooltips"] = function()
  local fixture = session()
  vim.lsp.inlay_hint.enable(true, { bufnr = fixture.buffer })
  local hint
  Lsp.wait(function()
    for _, item in ipairs(vim.lsp.inlay_hint.get({ bufnr = fixture.buffer })) do
      if item.client_id == fixture.client.id then
        local label = item.inlay_hint.label
        if type(label) == "string" and label:find("MsgType", 1, true) then
          hint = item.inlay_hint
          return true
        end
      end
    end
    return false
  end, "native MsgType hint")
  local resolved = Lsp.request(fixture.client, "inlayHint/resolve", hint, fixture.buffer)
  assert(resolved.tooltip.value:find("MsgType", 1, true), vim.inspect(resolved))
  assert(resolved.tooltip.value:find("Heartbeat", 1, true), vim.inspect(resolved))
  equal(resolved.label, hint.label)
  equal(resolved.position, hint.position)
end

tests["diagnostic configuration clears findings and invalidates fix-all"] = function()
  local fixture = session()
  assert(#fixture.diagnostics() >= 2)
  local choice, select = fixture.fix_all()
  fixture.client.settings.fix.diagnostics = { enabled = false }
  fixture.client:notify("workspace/didChangeConfiguration", { settings = fixture.client.settings })
  Lsp.wait(function()
    return #fixture.diagnostics() == 0
  end, "native diagnostics cleared after configuration")
  select(choice)
  Lsp.wait(function()
    return vim.iter(fixture.messages):any(function(message)
      return message:find("-32801", 1, true) ~= nil
    end)
  end, "native report of stale configuration on resolution")
  equal(vim.api.nvim_buf_get_lines(fixture.buffer, 0, -1, false), { "8=FIX.4.4|35=0|" })
  fixture.client.settings.fix.diagnostics.enabled = true
  fixture.client:notify("workspace/didChangeConfiguration", { settings = fixture.client.settings })
  Lsp.wait(function()
    return #fixture.diagnostics() >= 2
  end, "native diagnostics restored after configuration")
end

tests["all supported message details reach the public summary accessor"] = function()
  local fixture = session({
    "8=FIX.4.4|35=D|54=1|59=0|40=2|38=100|55=SYNTHETIC|44=12.5|",
    "8=FIX.4.4|35=8|150=F|38=10|44=20|11=synthetic|17=exec|",
    "8=FIX.4.4|35=5|58=Session closed|",
    "8=FIX.4.4|35=2|7=10|16=20|",
    "8=FIX.4.4|35=4|123=Y|36=21|",
  })
  local plugin = require("venue-reader")
  fixture.client.settings.fix.messageSummary.template = "{msgName} | {details}"
  fixture.client.settings.fix.messageSummary.details = true
  plugin.summary("hidden")
  local expected = {
    "NewOrderSingle | Buy Day Limit 100 SYNTHETIC @ 12.5",
    "ExecutionReport | Trade 10@20 ClOrdId=synthetic ExecId=exec",
    "Logout | Session closed",
    "ResendRequest | 10 - 20",
    "SequenceReset | Gap Fill to 21",
  }
  for i, summary in ipairs(expected) do
    vim.api.nvim_win_set_cursor(0, { i, 0 })
    Lsp.wait(function()
      return plugin.current_summary() == summary
    end, "message details: " .. summary)
  end
end

tests["native symbol cancellation ends real progress and leaves the client usable"] = function()
  local lines = {}
  for i = 1, 20000 do
    lines[i] = "8=FIX.4.4|9=5|35=0|10=163|"
  end
  local fixture = session(lines)
  local token = "capability-symbol-cancellation"
  local progress = {}
  local request_id
  local response
  local previous = fixture.client.handlers["$/progress"]
  fixture.client.handlers["$/progress"] = function(err, params, context, options)
    if params.token == token then
      progress[#progress + 1] = params.value.kind
      if params.value.kind == "begin" then
        fixture.client:cancel_request(assert(request_id))
      end
    end
    return (previous or vim.lsp.handlers["$/progress"])(err, params, context, options)
  end
  MiniTest.finally(function()
    fixture.client.handlers["$/progress"] = previous
  end)
  local accepted
  accepted, request_id = fixture.client:request("textDocument/documentSymbol", {
    textDocument = { uri = fixture.uri },
    workDoneToken = token,
  }, function(err, result)
    response = { error = err, result = result }
  end, fixture.buffer)
  assert(accepted)
  assert(
    vim.wait(5000, function()
      return fixture.client.requests[request_id] == nil and vim.list_contains(progress, "end")
    end, 10),
    vim.inspect({ response = response, progress = progress })
  )
  equal(progress[1], "begin")
  equal(progress[#progress], "end")
  -- Native RPC consumes RequestCancelled instead of calling the response handler.
  equal(response, nil)
  local hover = Lsp.request(fixture.client, "textDocument/hover", {
    textDocument = { uri = fixture.uri },
    position = { line = 0, character = 17 },
  }, fixture.buffer)
  assert(hover.contents.value:find("Heartbeat", 1, true), vim.inspect(hover))
end

return tests

local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local Symbols = require("tests.support.symbols")
local equal = MiniTest.expect.equality
local tests = MiniTest.new_set()
local symbol = Symbols.symbol

local function finished(picker)
  Lsp.wait(function()
    return Symbols.has_status(picker, "Request finished")
  end, "finished status")
end

local function failed(picker)
  Lsp.wait(function()
    return Symbols.has_status(picker, "Failed") and Symbols.results(picker) == 0
  end, "failure clears partial results")
end

local function ranged_symbol(name, start_column, end_column, kind, children)
  return {
    name = name,
    kind = kind or 8,
    range = {
      start = { line = 0, character = start_column },
      ["end"] = { line = 0, character = end_column },
    },
    selectionRange = {
      start = { line = 0, character = start_column },
      ["end"] = { line = 0, character = math.min(start_column + 2, end_column) },
    },
    children = children,
  }
end

local function field_source(fixture, column, line)
  vim.api.nvim_buf_set_lines(fixture.buffer, 0, -1, false, { line or "35=D|55=ABC|54=1|" })
  vim.api.nvim_win_set_cursor(0, { 1, column })
end

local function wait_selected(picker, name)
  Lsp.wait(function()
    local entry = picker:current()
    return entry and entry.name == name
  end, "selected source symbol " .. name)
end

local function accept_selection(picker)
  picker:action("confirm")
end

local function field_tree()
  return ranged_symbol("Message", 0, 16, 19, {
    ranged_symbol("MessageType", 0, 4),
    ranged_symbol("Group", 5, 16, 18, {
      ranged_symbol("Symbol", 5, 11),
      ranged_symbol("Side", 12, 16),
    }),
  })
end

tests["source tag and value positions select the innermost field before completion"] = function()
  local fixture = Symbols.fixture()
  for _, column in ipairs({ 5, 8 }) do
    field_source(fixture, column)
    local picker, request = fixture:open()
    fixture:chunk(request, { field_tree() }, picker, 5)
    wait_selected(picker, "Symbol")
    assert(Symbols.has_status(picker, "Loading symbols"))
    accept_selection(picker)
    equal(vim.api.nvim_get_current_buf(), fixture.buffer)
    equal(vim.api.nvim_win_get_cursor(0), { 1, 5 })
    assert(fixture:cancelled(request))
  end
end

tests["late source match replaces the containing parent while streaming"] = function()
  local fixture = Symbols.fixture()
  field_source(fixture, 8)
  local picker, request = fixture:open()
  fixture:chunk(request, { ranged_symbol("Message", 0, 16, 19) }, picker, 1)
  wait_selected(picker, "Message")
  fixture:chunk(request, { ranged_symbol("Symbol", 5, 11) }, picker, 2)
  wait_selected(picker, "Symbol")
  assert(Symbols.has_status(picker, "Loading symbols"))
  fixture:chunk(request, { ranged_symbol("Unrelated", 12, 16) }, picker, 3)
  wait_selected(picker, "Symbol")
end

tests["late source targets beyond the visible list work in either layout direction"] = function()
  local fixture = Symbols.fixture()
  for _, reverse in ipairs({ false, true }) do
    field_source(fixture, 1051, string.rep("aa|", 400))
    local picker, request =
      fixture:open({ layout = { preset = "default", preview = false, reverse = reverse } })
    local first, last = {}, {}
    for index = 0, 399 do
      local entry = ranged_symbol(
        index == 350 and "CursorTarget" or ("Field" .. index),
        index * 3,
        index * 3 + 2
      )
      local batch = index < 300 and first or last
      batch[#batch + 1] = entry
    end
    fixture:chunk(request, first, picker, 300)
    assert(picker.list:height() < 350, "source target must be outside the initial visible rows")
    fixture:chunk(request, last, picker, 400)
    wait_selected(picker, "CursorTarget")
    assert(Symbols.has_status(picker, "Loading symbols"))
    accept_selection(picker)
    equal(vim.api.nvim_get_current_buf(), fixture.buffer)
    equal(vim.api.nvim_win_get_cursor(0), { 1, 1050 })
  end
end

tests["final-only symbol trees select the field under the source cursor"] = function()
  local fixture = Symbols.fixture()
  field_source(fixture, 14)
  local picker, request = fixture:open()
  fixture:control("final", { request = request.id, result = { field_tree() } })
  finished(picker)
  wait_selected(picker, "Side")
end

tests["filtered source fields fall back to their available containing group"] = function()
  local fixture = Symbols.fixture()
  field_source(fixture, 8)
  local picker, request = fixture:open({ filter = { fix = { "Object", "Array" } } })
  fixture:chunk(request, { field_tree() }, picker, 2)
  wait_selected(picker, "Group")
end

tests["full ranges exclude their end position when finding the source symbol"] = function()
  local fixture = Symbols.fixture()
  field_source(fixture, 11)
  local picker, request = fixture:open()
  fixture:chunk(request, { field_tree() }, picker, 5)
  wait_selected(picker, "Group")
end

tests["manual selection is preserved when the source match arrives later"] = function()
  local fixture = Symbols.fixture()
  for _, navigate in ipairs({
    function(picker)
      picker.list:move(2, true)
    end,
    function(picker)
      picker:action("list_down")
    end,
    function(picker)
      picker:action("list_bottom")
    end,
  }) do
    field_source(fixture, 8)
    local picker, request = fixture:open()
    fixture:chunk(request, {
      ranged_symbol("First", 0, 2),
      ranged_symbol("Second", 2, 4),
    }, picker, 2)
    navigate(picker)
    wait_selected(picker, "Second")
    fixture:chunk(request, { ranged_symbol("Symbol", 5, 11) }, picker, 3)
    wait_selected(picker, "Second")
    Symbols.close(picker)
  end
end

tests["selection before any results prevents late automatic cursor matching"] = function()
  local fixture = Symbols.fixture()
  field_source(fixture, 8)
  local picker, request = fixture:open()
  picker.list:move(1, true)
  fixture:chunk(request, {
    ranged_symbol("First", 0, 2),
    ranged_symbol("Symbol", 5, 11),
  }, picker, 2)
  wait_selected(picker, "First")
end

tests["search then clearing the query does not reenable cursor matching"] = function()
  local fixture = Symbols.fixture()
  field_source(fixture, 8)
  local picker, request = fixture:open()
  fixture:chunk(request, {
    ranged_symbol("First", 0, 2),
    ranged_symbol("Second", 2, 4),
  }, picker, 2)
  Symbols.query(picker, "second", 1)
  Symbols.query(picker, "", 2)
  local selection = picker:current()
  fixture:chunk(request, { ranged_symbol("Symbol", 5, 11) }, picker, 3)
  equal(picker:current(), selection)
end

tests["initial search takes precedence over the source cursor"] = function()
  local fixture = Symbols.fixture()
  field_source(fixture, 8)
  local picker, request = fixture:open({ pattern = "side" })
  fixture:chunk(request, { field_tree() }, picker, 3)
  wait_selected(picker, "Side")
end

tests["edits discard the original cursor position before a new generation"] = function()
  local fixture = Symbols.fixture()
  field_source(fixture, 8)
  local picker, first = fixture:open()
  vim.api.nvim_buf_set_lines(fixture.buffer, 0, -1, false, { "edited text for new symbols" })
  local second
  Lsp.wait(function()
    second = fixture:state().requests[2]
    return second ~= nil
  end, "new generation after source edit")
  assert(fixture:cancelled(first))
  fixture:chunk(second, {
    ranged_symbol("First", 0, 2),
    ranged_symbol("OldCursorPosition", 5, 11),
  }, picker, 2)
  wait_selected(picker, "First")
end

tests["UTF-16 symbol ranges match UTF-8 source cursor bytes"] = function()
  local fixture = Symbols.fixture()
  equal(fixture.client.offset_encoding, "utf-16")
  field_source(fixture, 10, "😀é|55=ABC|")
  local picker, request = fixture:open()
  fixture:chunk(request, {
    ranged_symbol("Message", 0, 11, 19, { ranged_symbol("Symbol", 4, 10) }),
  }, picker, 2)
  wait_selected(picker, "Symbol")
  accept_selection(picker)
  equal(vim.api.nvim_win_get_cursor(0), { 1, 7 })
end

tests["chunks are selectable and searchable before final response"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  equal(request.params.textDocument.uri, vim.uri_from_bufnr(fixture.buffer))
  assert(request.params.partialResultToken ~= request.params.workDoneToken)
  fixture:chunk(request, { symbol("Alpha"), symbol("Beta", 1) }, picker, 2)
  assert(picker:current())
  vim.wait(1050, function()
    return false
  end)
  assert(Symbols.has_status(picker, "Loading symbols"))
  Symbols.query(picker, "later", 0)
  assert(Symbols.has_status(picker, "Loading symbols"))
  fixture:chunk(request, { symbol("Later", 2) }, picker, 1)
  assert(picker:current().text:find("Later", 1, true))
  equal(#fixture:state().requests, 1)
  fixture:control("final", { request = request.id })
  finished(picker)
  equal(Symbols.results(picker), 1)
end

tests["selection identity survives another chunk and query is preserved"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  fixture:chunk(request, { symbol("MatchFirst"), symbol("MatchSecond", 1) }, picker, 2)
  Symbols.query(picker, "match", 2)
  picker.list:move(2, true)
  local selected = picker:current()
  assert(selected)
  fixture:chunk(request, { symbol("MatchThird", 2) }, picker, 3)
  equal(picker:current(), selected)
  equal(picker.input:get(), "match")
end

tests["manual selection survives final completion and remains navigable"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  fixture:chunk(request, { symbol("First"), symbol("Second", 1), symbol("Third", 2) }, picker, 3)
  picker.list:move(2, true)
  wait_selected(picker, "Second")
  local selected = picker:current()
  fixture:control("final", { request = request.id })
  finished(picker)
  Lsp.wait(function()
    return not picker:is_active()
  end, "finder and matcher completed")
  vim.wait(50, function()
    return false
  end)
  equal(picker:current(), selected)
  picker:action("list_down")
  wait_selected(picker, "Third")
end

tests["marker is an ordinary record under text and kind filters"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open({ filter = { fix = { "Function" } } })
  fixture:chunk(request, {
    symbol("Alpha"),
    symbol("… Some fields/groups omitted", 0, 15),
  }, picker, 1)
  Symbols.close(picker)
  picker, request = fixture:open()
  fixture:chunk(request, {
    symbol("Alpha"),
    symbol("… Some fields/groups omitted", 0, 15),
  }, picker, 2)
  Symbols.query(picker, "alpha", 1)
  Symbols.query(picker, "nomatch", 0)
  assert(Symbols.has_status(picker, "Loading symbols"))
end

tests["work done 100 and end never complete the symbol request"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  fixture:chunk(request, { symbol("Alpha") }, picker, 1)
  fixture:control("progress", {
    request = request.id,
    value = { kind = "begin", title = "Symbols", percentage = 0 },
  })
  fixture:control(
    "progress",
    { request = request.id, value = { kind = "report", percentage = 43 } }
  )
  Lsp.wait(function()
    return Symbols.has_status(picker, "43%")
  end, "percentage rendered")
  fixture:control(
    "progress",
    { request = request.id, value = { kind = "report", percentage = 100 } }
  )
  fixture:control("progress", { request = request.id, value = { kind = "end" } })
  assert(Symbols.has_status(picker, "Loading symbols"))
  fixture:control("final", { request = request.id })
  finished(picker)
end

tests["early selection navigates then cancels the unfinished request"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  fixture:chunk(request, { symbol("Second", 1) }, picker, 1)
  picker:action("confirm")
  Lsp.wait(function()
    return fixture:cancelled(request)
  end, "selection cancellation")
  equal(vim.api.nvim_get_current_buf(), fixture.buffer)
  equal(vim.api.nvim_win_get_cursor(0)[1], 2)
  equal(fixture.client.handlers["$/progress"], fixture.original_handler)
end

tests["list actions export selected or filtered symbols after closing"] = function()
  for _, action in ipairs({ "qflist", "qflist_all", "loclist" }) do
    for _, complete in ipairs({ false, true }) do
      for _, select_item in ipairs({ false, true }) do
        local fixture = Symbols.fixture()
        local picker, request = fixture:open()
        fixture:chunk(request, {
          symbol("Alpha", 0),
          symbol("Beta", 1),
          symbol("Gamma", 2),
        }, picker, 3)
        if complete then
          fixture:control("final", { request = request.id })
          finished(picker)
        end
        if select_item then
          picker.list:select(picker.list:get(2))
          picker.list:select(picker.list:get(3))
        else
          Symbols.query(picker, "Beta", 1)
        end
        local source_window = picker.main
        MiniTest.finally(function()
          vim.cmd("silent! cclose")
          if vim.api.nvim_win_is_valid(source_window) then
            vim.api.nvim_win_call(source_window, function()
              vim.cmd("silent! lclose")
            end)
          end
        end)
        picker:action(action)
        assert(picker.closed)
        local items = action == "loclist" and vim.fn.getloclist(source_window) or vim.fn.getqflist()
        local expected = action == "qflist_all" and select_item and { "Alpha", "Beta", "Gamma" }
          or select_item and { "Beta", "Gamma" }
          or { "Beta" }
        equal(
          vim.tbl_map(function(item)
            return item.text
          end, items),
          expected
        )
        for index, item in ipairs(items) do
          equal(item.bufnr, fixture.buffer)
          equal(item.lnum, #expected == 3 and index or index + 1)
          equal(item.col, 1)
        end
        if not complete then
          Lsp.wait(function()
            return fixture:cancelled(request)
          end, "list export cancels streaming request")
        end
        vim.api.nvim_set_current_win(source_window)
      end
    end
  end
end

tests["empty and populated final-only responses remain supported"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  fixture:control("final", { request = request.id })
  finished(picker)
  equal(Symbols.results(picker), 0)
  Symbols.close(picker)
  picker, request = fixture:open()
  local root = symbol("Parent")
  root.children = { symbol("Child", 1) }
  fixture:control("final", { request = request.id, result = { root } })
  finished(picker)
  Lsp.wait(function()
    return Symbols.results(picker) == 2
  end, "nested final-only symbols")
end

tests["ordinary errors discard partials and do not retry"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  fixture:chunk(request, { symbol("Discard") }, picker, 1)
  fixture:control("final", { request = request.id, error = { code = -32603, message = "broken" } })
  failed(picker)
  equal(#fixture:state().requests, 1)
  equal(fixture.client.handlers["$/progress"], fixture.original_handler)
end

tests["populated final after partial results is a protocol failure"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  fixture:chunk(request, { symbol("Partial") }, picker, 1)
  fixture:control("final", { request = request.id, result = { symbol("Ambiguous") } })
  failed(picker)
end

tests["edits invalidate immediately and coalesce into one new generation"] = function()
  local fixture = Symbols.fixture()
  local picker, first = fixture:open()
  fixture:chunk(first, { symbol("MatchOld", 1) }, picker, 1)
  Symbols.query(picker, "match", 1)
  for index = 1, 5 do
    vim.api.nvim_buf_set_lines(fixture.buffer, 0, 1, false, { "edited " .. index })
  end
  Lsp.wait(function()
    return Symbols.results(picker) == 0 and fixture:cancelled(first)
  end, "edit invalidation")
  local second
  Lsp.wait(function()
    second = fixture:state().requests[2]
    return second ~= nil
  end, "debounced restart")
  equal(#fixture:state().requests, 2)
  equal(picker.input:get(), "match")
  assert(first.params.partialResultToken ~= second.params.partialResultToken)
  fixture:chunk(first, { symbol("MatchStale", 3) })
  fixture:chunk(second, { symbol("MatchCurrent", 2) }, picker, 1)
  assert(picker:current().text:find("MatchCurrent", 1, true))
  fixture:control("final", { request = first.id })
  assert(Symbols.has_status(picker, "Loading symbols"))
end

tests["close during edit debounce prevents a new request"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  vim.api.nvim_buf_set_lines(fixture.buffer, 0, 1, false, { "edited" })
  Symbols.close(picker)
  vim.wait(250, function()
    return false
  end)
  equal(#fixture:state().requests, 1)
  assert(fixture:cancelled(request))
end

tests["close and reopen ignore late old chunks and preserve unrelated progress"] = function()
  local fixture = Symbols.fixture()
  local global = vim.lsp.handlers["$/progress"]
  local picker, first = fixture:open()
  fixture:chunk(first, { symbol("Old") }, picker, 1)
  Symbols.close(picker)
  assert(fixture:cancelled(first))
  local request
  picker, request = fixture:open()
  fixture:chunk(first, { symbol("Late") })
  fixture:chunk(request, { symbol("New") }, picker, 1)
  assert(picker:current().text:find("New", 1, true))
  fixture:control("unrelated")
  Lsp.wait(function()
    for _, progress in ipairs(fixture.progress) do
      if progress.token == "unrelated-work" then
        return true
      end
    end
    return false
  end, "unrelated progress delegated")
  equal(vim.lsp.handlers["$/progress"], global)
  Symbols.close(picker)
  equal(fixture.client.handlers["$/progress"], fixture.original_handler)
end

tests["another component replacing progress routing is not overwritten"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  local replacement = function() end
  fixture.client.handlers["$/progress"] = replacement
  Lsp.wait(function()
    return Symbols.has_status(picker, "Failed") or picker.closed
  end, "lost routing detected")
  assert(fixture:cancelled(request))
  Symbols.close(picker)
  equal(fixture.client.handlers["$/progress"], replacement)
end

tests["inactivity timeout cancels while owned progress resets it"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open({ timeout_ms = 150 })
  for _ = 1, 4 do
    fixture:control("progress", {
      request = request.id,
      value = { kind = "report", message = "Queued" },
    })
    vim.wait(60, function()
      return false
    end)
    assert(Symbols.has_status(picker, "Loading symbols"))
  end
  failed(picker)
  assert(fixture:cancelled(request))
end

tests["disabled timeout keeps an idle request selectable until close"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open({ timeout_ms = 0 })
  fixture:chunk(request, { symbol("Idle") }, picker, 1)
  vim.wait(200, function()
    return false
  end)
  assert(Symbols.has_status(picker, "Loading symbols"))
  assert(not fixture:cancelled(request))
end

tests["detach removes selectable results and cancels outstanding work"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  fixture:chunk(request, { symbol("Detached") }, picker, 1)
  vim.lsp.buf_detach_client(fixture.buffer, fixture.client.id)
  Lsp.wait(function()
    return picker.closed or Symbols.results(picker) == 0
  end, "detach clears locations")
  assert(fixture:cancelled(request))
  equal(fixture.client.handlers["$/progress"], fixture.original_handler)
end

tests["server exit clears selectable results and owned routes"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  fixture:chunk(request, { symbol("Exited") }, picker, 1)
  fixture.client:notify("test/exit", {})
  Lsp.wait(function()
    return fixture.client:is_stopped() and (picker.closed or Symbols.results(picker) == 0)
  end, "server exit cleanup")
  equal(fixture.client.handlers["$/progress"], fixture.original_handler)
end

tests["overlapping requests route separately and restore only after the last owner"] = function()
  local fixture = Symbols.fixture()
  local Request = require("venue-reader.symbols.request")
  local received = { {}, {} }
  local completed = {}
  local requests = {}
  for index = 1, 2 do
    requests[index] = Request.start(fixture.client, fixture.buffer, {
      timeout_ms = 5000,
      on_batch = function(batch)
        vim.list_extend(received[index], batch)
      end,
      on_progress = function() end,
      on_done = function(err)
        assert(not err, vim.inspect(err))
        completed[index] = true
      end,
    })
    MiniTest.finally(requests[index].cancel)
  end
  local pending = fixture:state().requests
  equal(#pending, 2)
  fixture:chunk(pending[2], { symbol("Second") })
  fixture:chunk(pending[1], { symbol("First") })
  equal(received[1][1].name, "First")
  equal(received[2][1].name, "Second")
  requests[1].cancel()
  assert(fixture.client.handlers["$/progress"] ~= fixture.original_handler)
  fixture:chunk(pending[1], { symbol("Stale") })
  fixture:chunk(pending[2], { symbol("StillLive") })
  equal(#received[1], 1)
  equal(#received[2], 2)
  fixture:control("final", { request = pending[2].id })
  Lsp.wait(function()
    return completed[2] == true
  end, "second request finished")
  equal(completed[1], nil)
  equal(fixture.client.handlers["$/progress"], fixture.original_handler)
end

tests["source wipeout cancels and closes the picker"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  fixture:chunk(request, { symbol("Wiped") }, picker, 1)
  local replacement = vim.api.nvim_create_buf(false, true)
  MiniTest.finally(function()
    if vim.api.nvim_buf_is_valid(replacement) then
      vim.api.nvim_buf_delete(replacement, { force = true })
    end
  end)
  vim.api.nvim_win_set_buf(picker.main, replacement)
  vim.api.nvim_buf_delete(fixture.buffer, { force = true })
  assert(not vim.api.nvim_buf_is_valid(fixture.buffer), "source was actually wiped")
  Lsp.wait(function()
    return picker.closed
  end, "source wipeout closes picker")
  assert(fixture:cancelled(request))
end

tests["missing optional Snacks reports a clear dependency error"] = function()
  local script = vim.fn.tempname() .. ".lua"
  MiniTest.finally(function()
    vim.fn.delete(script)
  end)
  local root = assert(vim.env.VENUE_READER_TEST_ROOT)
  vim.fn.writefile({
    "vim.opt.runtimepath:prepend(" .. string.format("%q", root) .. ")",
    "local success, failure = pcall(function()",
    "  require('venue-reader.symbols').open({}, vim.api.nvim_get_current_buf(), {})",
    "end)",
    "assert(not success, 'unexpected success')",
    "assert(tostring(failure):lower():find('snacks', 1, true), tostring(failure))",
  }, script)
  local result = vim
    .system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script })
    :wait(5000)
  equal(result.code, 0)
end

tests["public command opens the managed client stream"] = function()
  local picker
  MiniTest.finally(function()
    if picker then
      Symbols.close(picker)
    end
    vim.cmd("stopinsert")
  end)
  local Plugin = require("venue-reader")
  local root = assert(vim.env.VENUE_READER_TEST_ROOT)
  local original_config = vim.lsp.config["venue-reader"]
  vim.lsp.config["venue-reader"] = { -- luacheck: ignore 122
    cmd = {
      vim.fn.has("win32") == 1 and "python" or "python3",
      root .. "/tests/support/symbol_server.py",
      require("venue-reader.release").series .. ".0",
    },
    root_dir = vim.uv.cwd(),
  }
  Plugin.setup({
    server = { update_version = false },
    summary = { mode = "off" },
    treesitter = { enabled = false },
  })
  MiniTest.finally(function()
    vim.lsp.enable("venue-reader", false)
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue-reader" })) do
      client:stop(true)
    end
    Lsp.wait(function()
      return #vim.lsp.get_clients({ name = "venue-reader" }) == 0
    end, "public client cleanup")
    vim.lsp.config["venue-reader"] = original_config or {} -- luacheck: ignore 122
  end)
  local buffer = Lsp.buffer()
  vim.api.nvim_set_current_buf(buffer)
  local client
  Lsp.wait(function()
    client = vim.lsp.get_clients({ name = "venue-reader", bufnr = buffer })[1]
    return client and client.initialized
  end, "managed client")
  vim.cmd("VenueReader symbols")
  Lsp.wait(function()
    picker = require("snacks").picker.get()[1]
    return picker ~= nil
  end, "public picker")
  local state = Lsp.request(client, "test/state", {}, buffer)
  equal(#state.requests, 1)
  Lsp.request(client, "test/chunk", {
    request = state.requests[1].id,
    symbols = { symbol("PublicEntry") },
  }, buffer)
  Lsp.wait(function()
    return picker:current() ~= nil
  end, "public streamed entry")
  assert(picker:current().text:find("PublicEntry", 1, true))
end

tests["renaming the source closes and cancels its old URI request"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  fixture:chunk(request, { symbol("BeforeRename") }, picker, 1)
  local previous_uri = vim.uri_from_bufnr(fixture.buffer)
  vim.api.nvim_buf_set_name(fixture.buffer, vim.api.nvim_buf_get_name(fixture.buffer) .. ".renamed")
  assert(vim.uri_from_bufnr(fixture.buffer) ~= previous_uri)
  Lsp.wait(function()
    return picker.closed
  end, "rename closes picker")
  assert(fixture:cancelled(request))
  equal(fixture.client.handlers["$/progress"], fixture.original_handler)
end

tests["repeated appends defer restart until edit quietness"] = function()
  local fixture = Symbols.fixture()
  local picker, first = fixture:open()
  fixture:chunk(first, { symbol("BeforeAppend") }, picker, 1)
  for index = 1, 6 do
    vim.api.nvim_buf_set_lines(fixture.buffer, -1, -1, false, { "append " .. index })
    vim.wait(80, function()
      return false
    end)
    equal(#fixture:state().requests, 1)
    equal(Symbols.results(picker), 0)
    equal(picker:current(), nil)
  end
  local second
  Lsp.wait(function()
    second = fixture:state().requests[2]
    return second ~= nil
  end, "append quietness restart")
  equal(#fixture:state().requests, 2)
  assert(fixture:cancelled(first))
  fixture:chunk(second, { symbol("AfterAppend") }, picker, 1)
  Symbols.close(picker)
  assert(fixture:cancelled(second))
end

tests["long Unicode names retain their native location and searchable suffix"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  local name = string.rep("Ж😀", 300) .. "HiddenSuffixNeedle"
  fixture:chunk(request, { symbol(name) }, picker, 1)
  local entry = picker:current()
  equal(entry.name, name)
  assert(entry.text:find(name, 1, true))
  equal(entry.loc.uri, vim.uri_from_bufnr(fixture.buffer))
  equal(entry.loc.range.start, { line = 0, character = 0 })
  Symbols.query(picker, "hiddensuffixneedle", 1)
  equal(picker:current(), entry)
  equal(entry.name, name)
end

local function names(picker)
  return vim.tbl_map(function(item)
    return item.name
  end, picker:items())
end

tests["native tree ancestry and connectors survive streamed siblings"] = function()
  local fixture = Symbols.fixture()
  field_source(fixture, 0)
  local picker, request = fixture:open()
  fixture:chunk(request, { field_tree() }, picker, 5)
  local items = picker:items()
  local message, message_type, group, field, side = unpack(items)
  equal(names(picker), { "Message", "MessageType", "Group", "Symbol", "Side" })
  assert(message.parent.root)
  equal(message_type.parent, message)
  equal(group.parent, message)
  equal(field.parent, group)
  equal(side.parent, group)
  local icons = picker.opts.icons.tree
  local function connector(item)
    return require("snacks.picker.format").tree(item, picker)[1][1]
  end
  equal(connector(message), icons.last)
  equal(connector(message_type), "  " .. icons.middle)
  equal(connector(group), "  " .. icons.last)
  equal(connector(field), "    " .. icons.middle)
  equal(connector(side), "    " .. icons.last)
  fixture:chunk(request, { symbol("NextMessage", 2, 19) }, picker, 6)
  local next_message = picker:items()[6]
  equal(next_message.parent, message.parent)
  equal(connector(message), icons.middle)
  equal(connector(side), icons.vertical .. "  " .. icons.last)
  equal(connector(next_message), icons.last)
  assert(Symbols.has_status(picker, "Loading symbols"))
end

tests["search retains native ancestors and clearing restores source order"] = function()
  local fixture = Symbols.fixture()
  field_source(fixture, 0)
  local picker, request = fixture:open()
  fixture:chunk(request, { field_tree() }, picker, 5)
  Symbols.query(picker, "side", 3)
  equal(names(picker), { "Message", "Group", "Side" })
  local items = picker:items()
  equal(items[3].parent, items[2])
  equal(items[2].parent, items[1])
  Symbols.query(picker, "", 5)
  equal(names(picker), { "Message", "MessageType", "Group", "Symbol", "Side" })
  equal(#fixture:state().requests, 1)
end

tests["kind filtering reconnects descendants to their nearest visible ancestor"] = function()
  local fixture = Symbols.fixture()
  field_source(fixture, 0)
  local picker, request = fixture:open({ filter = { fix = { "Object", "Field" } } })
  fixture:chunk(request, { field_tree() }, picker, 4)
  equal(names(picker), { "Message", "MessageType", "Symbol", "Side" })
  local items = picker:items()
  for index = 2, #items do
    equal(items[index].parent, items[1])
  end
  equal(items[4].last, true)
  assert(not items[3].last)
end

tests["moderate streamed tree stays searchable through completion"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  local function batch(first, last)
    local roots = {}
    for index = first, last do
      local root = symbol("Message" .. index, 0, 19)
      local group = symbol("Group" .. index, 1, 18)
      group.children = {}
      for child = 1, 5 do
        group.children[child] = symbol(("Value%02d_%d"):format(index, child), 2, 8)
      end
      root.children = { group }
      roots[#roots + 1] = root
    end
    return roots
  end
  fixture:chunk(request, batch(1, 10), picker, 70)
  Symbols.query(picker, "Value20_5", 0)
  fixture:chunk(request, batch(11, 20), picker, 3)
  equal(names(picker), { "Message20", "Group20", "Value20_5" })
  picker:action("list_bottom")
  wait_selected(picker, "Value20_5")
  assert(Symbols.has_status(picker, "Loading symbols"))
  fixture:control("final", { request = request.id })
  finished(picker)
  equal(picker:current().name, "Value20_5")
  Symbols.query(picker, "", 140)
  equal(#fixture:state().requests, 1)
end

tests["opening again replaces the picker and cancels the previous request"] = function()
  local fixture = Symbols.fixture()
  local first, request = fixture:open()
  fixture:chunk(request, { symbol("Old") }, first, 1)
  vim.api.nvim_set_current_win(first.main)
  local second = fixture:open()
  assert(first.closed)
  assert(second and not second.closed)
  Lsp.wait(function()
    return fixture:cancelled(request) and #fixture:state().requests == 2
  end, "replacement request")
  local replacement = fixture:state().requests[2]
  fixture:chunk(replacement, { symbol("New") }, second, 1)
  equal(second:current().name, "New")
end

tests["setup and native symbols work without Snacks when picker is disabled"] = function()
  local root = assert(vim.env.VENUE_READER_TEST_ROOT)
  local result = vim
    .system({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-l",
      root .. "/tests/support/no_snacks.lua",
    })
    :wait(15000)
  assert(result.code == 0, result.stderr or result.stdout)
end

return tests

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

tests["chunks are selectable and searchable before final response"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  equal(request.params.textDocument.uri, vim.uri_from_bufnr(fixture.buffer))
  assert(request.params.partialResultToken ~= request.params.workDoneToken)
  fixture:chunk(request, { symbol("Alpha"), symbol("Beta", 1) }, picker, 2)
  assert(picker:get_selection())
  vim.wait(1050, function()
    return false
  end)
  assert(Symbols.has_status(picker, "Loading symbols"))
  Symbols.query(picker, "later", 0)
  assert(Symbols.has_status(picker, "Loading symbols"))
  fixture:chunk(request, { symbol("Later", 2) }, picker, 1)
  assert(picker:get_selection().ordinal:find("Later", 1, true))
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
  picker:set_selection(1)
  local selected = picker:get_selection()
  assert(selected)
  fixture:chunk(request, { symbol("MatchThird", 2) }, picker, 3)
  equal(picker:get_selection(), selected)
  equal(picker:_get_prompt(), "match")
end

tests["marker is an ordinary record under text and kind filters"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open({ symbols = { "Function" } })
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
  require("telescope.actions").select_default(picker.prompt_bufnr)
  Lsp.wait(function()
    return fixture:cancelled(request)
  end, "selection cancellation")
  equal(vim.api.nvim_get_current_buf(), fixture.buffer)
  equal(vim.api.nvim_win_get_cursor(0)[1], 2)
  equal(fixture.client.handlers["$/progress"], fixture.original_handler)
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
  equal(picker:_get_prompt(), "match")
  assert(first.params.partialResultToken ~= second.params.partialResultToken)
  fixture:chunk(first, { symbol("MatchStale", 3) })
  fixture:chunk(second, { symbol("MatchCurrent", 2) }, picker, 1)
  assert(picker:get_selection().ordinal:find("MatchCurrent", 1, true))
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
  assert(picker:get_selection().ordinal:find("New", 1, true))
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
    return Symbols.has_status(picker, "Failed")
      or not vim.api.nvim_buf_is_valid(picker.prompt_bufnr)
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
    return not vim.api.nvim_buf_is_valid(picker.prompt_bufnr) or Symbols.results(picker) == 0
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
    return fixture.client:is_stopped()
      and (not vim.api.nvim_buf_is_valid(picker.prompt_bufnr) or Symbols.results(picker) == 0)
  end, "server exit cleanup")
  equal(fixture.client.handlers["$/progress"], fixture.original_handler)
end

tests["unpaced 50000 symbols retain last match during changing query"] = function()
  local fixture = Symbols.fixture()
  local measurements = {}
  for trial = 1, 3 do
    local picker, request = fixture:open()
    local scans, refreshes = 0, 0
    local refresh = picker.refresh
    picker.refresh = function(self, ...)
      refreshes = refreshes + 1
      return refresh(self, ...)
    end
    picker:register_completion_callback(function()
      scans = scans + 1
    end)
    local started = vim.uv.hrtime()
    local previous = started
    local first_selectable, heartbeat = nil, 0
    local timer = assert(vim.uv.new_timer())
    MiniTest.finally(function()
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end)
    timer:start(
      5,
      5,
      vim.schedule_wrap(function()
        local now = vim.uv.hrtime()
        heartbeat = math.max(heartbeat, (now - previous) / 1e6)
        previous = now
        if not first_selectable and picker:get_selection() then
          first_selectable = (now - started) / 1e6
        end
      end)
    )
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(picker.prompt_bufnr) then
        picker:set_prompt("burst049999", true)
      end
    end, 30)
    fixture.client:notify("test/burst", { request = request.id, total = 50000, batch = 256 })
    finished(picker)
    Lsp.wait(function()
      return Symbols.results(picker) == 1 and picker:get_selection() ~= nil
    end, "last burst match")
    measurements[#measurements + 1] = {
      trial = trial,
      first_selectable_ms = first_selectable,
      total_ms = (vim.uv.hrtime() - started) / 1e6,
      max_heartbeat_ms = heartbeat,
      refreshes = refreshes,
      scans = scans,
      symbols = 50000,
      chunks = 196,
    }
    timer:stop()
    timer:close()
    assert(picker:get_selection().ordinal:find("Burst049999", 1, true))
    Symbols.query(picker, "", 50000)
    assert(scans < 196, "transport chunks must be coalesced before refreshing")
    Symbols.close(picker)
  end
  local destination = vim.env.VENUE_READER_SYMBOL_BENCHMARK
  if destination and destination ~= "" then
    vim.fn.writefile({ vim.json.encode(measurements) }, destination)
  end
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
  vim.api.nvim_win_set_buf(picker.original_win_id, replacement)
  vim.api.nvim_buf_delete(fixture.buffer, { force = true })
  assert(not vim.api.nvim_buf_is_valid(fixture.buffer), "source was actually wiped")
  Lsp.wait(function()
    return not vim.api.nvim_buf_is_valid(picker.prompt_bufnr)
  end, "source wipeout closes picker")
  assert(fixture:cancelled(request))
end

tests["missing optional Telescope reports a clear dependency error"] = function()
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
    "assert(tostring(failure):lower():find('telescope', 1, true), tostring(failure))",
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
  local original_config = vim.lsp.config.venue_reader
  vim.lsp.config.venue_reader = { -- luacheck: ignore 122
    cmd = {
      "python3",
      root .. "/tests/support/symbol_server.py",
      require("venue-reader.release").series .. ".0",
    },
    root_dir = vim.uv.cwd(),
  }
  Plugin.setup({
    server = { auto_install = false },
    summary = { mode = "off" },
    treesitter = { enabled = false },
  })
  MiniTest.finally(function()
    vim.lsp.enable("venue_reader", false)
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
      client:stop(true)
    end
    Lsp.wait(function()
      return #vim.lsp.get_clients({ name = "venue_reader" }) == 0
    end, "public client cleanup")
    vim.lsp.config.venue_reader = original_config or {} -- luacheck: ignore 122
  end)
  local buffer = Lsp.buffer()
  vim.api.nvim_set_current_buf(buffer)
  local client
  Lsp.wait(function()
    client = vim.lsp.get_clients({ name = "venue_reader", bufnr = buffer })[1]
    return client and client.initialized
  end, "managed client")
  vim.cmd("VenueReader symbols")
  Lsp.wait(function()
    local prompts = require("telescope.state").get_existing_prompt_bufnrs()
    if #prompts > 0 then
      picker = require("telescope.actions.state").get_current_picker(prompts[1])
    end
    return picker ~= nil
  end, "public picker")
  local state = Lsp.request(client, "test/state", {}, buffer)
  equal(#state.requests, 1)
  Lsp.request(client, "test/chunk", {
    request = state.requests[1].id,
    symbols = { symbol("PublicEntry") },
  }, buffer)
  Lsp.wait(function()
    return picker:get_selection() ~= nil
  end, "public streamed entry")
  assert(picker:get_selection().ordinal:find("PublicEntry", 1, true))
end

tests["renaming the source closes and cancels its old URI request"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open()
  fixture:chunk(request, { symbol("BeforeRename") }, picker, 1)
  local previous_uri = vim.uri_from_bufnr(fixture.buffer)
  vim.api.nvim_buf_set_name(fixture.buffer, vim.api.nvim_buf_get_name(fixture.buffer) .. ".renamed")
  assert(vim.uri_from_bufnr(fixture.buffer) ~= previous_uri)
  Lsp.wait(function()
    return not vim.api.nvim_buf_is_valid(picker.prompt_bufnr)
  end, "rename closes picker")
  assert(fixture:cancelled(request))
  equal(fixture.client.handlers["$/progress"], fixture.original_handler)
end

tests["close while a large received batch is converting cannot contaminate reopen"] = function()
  local fixture = Symbols.fixture()
  local picker, first = fixture:open()
  fixture:control("burst", { request = first.id, total = 50000, batch = 50000, finish = false })
  Symbols.close(picker)
  assert(fixture:cancelled(first))
  equal(fixture.client.handlers["$/progress"], fixture.original_handler)
  local second
  picker, second = fixture:open()
  fixture:chunk(second, { symbol("Fresh") }, picker, 1)
  fixture:control("final", { request = first.id })
  vim.wait(150, function()
    return false
  end)
  equal(Symbols.results(picker), 1)
  assert(picker:get_selection().ordinal:find("Fresh", 1, true))
  assert(Symbols.has_status(picker, "Loading symbols"))
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
    equal(picker:get_selection(), nil)
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

tests["long Unicode display keeps full names and searchable suffixes"] = function()
  local fixture = Symbols.fixture()
  local picker, request = fixture:open({ symbol_width = 25 })
  local name = string.rep("Ж😀", 300) .. "HiddenSuffixNeedle"
  fixture:chunk(request, { symbol(name) }, picker, 1)
  local entry = picker:get_selection()
  equal(entry.symbol_name, name)
  assert(entry.ordinal:find(name, 1, true))
  assert(entry.value.text:find(name, 1, true))
  local rendered = entry.display(entry)
  assert(not rendered:find("HiddenSuffixNeedle", 1, true))
  local prefix = assert(rendered:match("^(.-)…"), rendered)
  assert(prefix:find("😀", 1, true))
  equal(vim.fn.strcharpart(name, 0, vim.fn.strchars(prefix)), prefix)
  Symbols.query(picker, "hiddensuffixneedle", 1)
  equal(picker:get_selection().symbol_name, name)
  equal(entry.symbol_name, name)
end

return tests

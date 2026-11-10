local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local Transport = require("tests.support.transport")
local Plugin = require("venue-reader")
local Ui = require("tests.support.summary_ui")

local equal = MiniTest.expect.equality
local tests = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.lsp.config.venue_reader = {} -- luacheck: ignore 122
    end,
  },
})
local marks, pending, wait_request = Ui.marks, Ui.pending, Ui.wait_request
local fixture, configuration, hints, reply, refresh =
  Ui.fixture, Ui.configuration, Ui.hints, Ui.reply, Ui.refresh

tests["headless redraw invokes decoration providers"] = function()
  local observed = false
  local probe = vim.api.nvim_create_namespace("summary-test-probe")
  vim.api.nvim_set_decoration_provider(probe, {
    on_win = function()
      observed = true
    end,
  })
  MiniTest.finally(function()
    vim.api.nvim_set_decoration_provider(probe, {})
  end)
  vim.cmd("redraw!")
  assert(observed)
end

tests["front splits summary from native fields and preserves label padding"] = function()
  local context = fixture("front")
  reply(context)
  configuration(context)
  Lsp.wait(function()
    return #marks(context.buffer) == 1
  end, "front summary")
  local mark = marks(context.buffer)[1]
  equal(mark[2], 0)
  equal(mark[4].virt_text_pos, "inline")
  local text = table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, mark[4].virt_text))
  equal(text, " Heartbeat λ details ")
  local native = vim.lsp.inlay_hint.get({ bufnr = context.buffer })
  equal(#native, 1)
  equal(native[1].inlay_hint.label, "MsgType")
  equal(Plugin.status(context.buffer).annotations.mode, "front")
end

tests["above uses a virtual line and native disable hides until explicit activation"] = function()
  local context = fixture("above")
  reply(context)
  configuration(context)
  Lsp.wait(function()
    return #marks(context.buffer) == 1
  end, "above summary")
  assert(marks(context.buffer)[1][4].virt_lines_above)
  assert(marks(context.buffer)[1][4].virt_lines)
  vim.lsp.inlay_hint.enable(false, { bufnr = context.buffer })
  equal(#marks(context.buffer), 0)
  equal(Plugin.status(context.buffer).annotations.native_enabled, false)
  vim.api.nvim_buf_set_lines(context.buffer, 1, 2, false, { "edited" })
  vim.wait(30)
  assert(not vim.lsp.inlay_hint.is_enabled({ bufnr = context.buffer }))
  Plugin.summary("front")
  assert(vim.lsp.inlay_hint.is_enabled({ bufnr = context.buffer }))
end

tests["empty response clears summaries and fields without recovery requests"] = function()
  local context = fixture()
  reply(context)
  configuration(context)
  Lsp.wait(function()
    return #marks(context.buffer) == 1
  end, "summary")
  refresh(context)
  local empty = reply(context, {})
  equal(#marks(context.buffer), 0)
  equal(#vim.lsp.inlay_hint.get({ bufnr = context.buffer }), 0)
  local outstanding = pending(context.transport, "textDocument/inlayHint")
  assert(not outstanding or outstanding.id < empty.id)
end

tests["effective configuration conflict blocks summary while preserving fields"] = function()
  local context = fixture()
  reply(context)
  configuration(context, { ["messageSummary.enabled"] = false })
  equal(#marks(context.buffer), 0)
  equal(#vim.lsp.inlay_hint.get({ bufnr = context.buffer }), 1)
  assert(Plugin.status(context.buffer).annotations.problem)
end

tests["late same-version reply cannot replace newer native request"] = function()
  local context = fixture()
  local old = wait_request(context.transport, "textDocument/inlayHint")
  refresh(context)
  local latest = wait_request(context.transport, "textDocument/inlayHint")
  assert(latest.id ~= old.id)
  context.transport:reply(latest.id, hints("latest"))
  vim.wait(30)
  configuration(context)
  Lsp.wait(function()
    return #marks(context.buffer) == 1
  end, "latest summary")
  context.transport:reply(old.id, hints("old"))
  vim.wait(30)
  local text = vim.inspect(marks(context.buffer))
  assert(text:find("latest", 1, true))
  assert(not text:find("old", 1, true))
end

tests["cancelled response cannot draw custom summary"] = function()
  local context = fixture()
  local request = wait_request(context.transport, "textDocument/inlayHint")
  assert(context.client:cancel_request(request.id))
  context.transport:reply(request.id, hints())
  vim.wait(30)
  equal(#marks(context.buffer), 0)
end

tests["mode switching clears old marks and changes server channels"] = function()
  local context = fixture()
  reply(context)
  configuration(context)
  Lsp.wait(function()
    return #marks(context.buffer) == 1
  end, "summary")
  Plugin.summary("off")
  equal(#marks(context.buffer), 0)
  equal(
    context.client.settings.fix.messageSummary.channels,
    { inlayHints = false, codeLens = false }
  )
  assert(vim.lsp.inlay_hint.is_enabled({ bufnr = context.buffer }))
  Plugin.summary("codelens")
  equal(
    context.client.settings.fix.messageSummary.channels,
    { inlayHints = false, codeLens = true }
  )
  equal(#marks(context.buffer), 0)
  Plugin.summary("above")
  equal(
    context.client.settings.fix.messageSummary.channels,
    { inlayHints = true, codeLens = false }
  )
end

tests["edit hides accepted summaries and rejects the outstanding reply"] = function()
  local context = fixture()
  reply(context)
  configuration(context)
  Lsp.wait(function()
    return #marks(context.buffer) == 1
  end, "accepted summary")
  refresh(context)
  local old = wait_request(context.transport, "textDocument/inlayHint")
  local result = hints("stale after edit")
  vim.api.nvim_buf_set_lines(context.buffer, 0, 1, false, { "8=FIX.4.4|35=2|" })
  equal(#marks(context.buffer), 0)
  context.transport:reply(old.id, result)
  vim.wait(30)
  equal(#marks(context.buffer), 0)
end

tests["rename reattaches and re-enables native hints after explicit disable"] = function()
  local context = fixture()
  reply(context)
  configuration(context)
  Lsp.wait(function()
    return #marks(context.buffer) == 1
  end, "accepted summary")
  vim.lsp.inlay_hint.enable(false, { bufnr = context.buffer })
  equal(#marks(context.buffer), 0)
  vim.api.nvim_buf_call(context.buffer, function()
    vim.cmd("file renamed-summary.fix")
  end)
  Lsp.wait(function()
    return vim.lsp.buf_is_attached(context.buffer, context.client.id)
      and vim.lsp.inlay_hint.is_enabled({ bufnr = context.buffer })
  end, "native gate after rename")
  equal(#marks(context.buffer), 0)
end

tests["unrelated client summary-kind hints remain entirely native"] = function()
  local context = fixture()
  reply(context)
  configuration(context)
  Lsp.wait(function()
    return #marks(context.buffer) == 1
  end, "managed summary")
  local transport = Transport.new()
  local client = Lsp.start({ name = "foreign-summary", cmd = transport.command }, context.buffer)
  transport:reply(1, {
    capabilities = {
      textDocumentSync = { openClose = true, change = 1 },
      inlayHintProvider = true,
    },
  })
  Lsp.ready(client, context.buffer)
  local request = wait_request(transport, "textDocument/inlayHint")
  transport:reply(request.id, {
    {
      position = { line = 1, character = 0 },
      label = "foreign summary",
      data = { kind = "summary" },
    },
  })
  vim.wait(30)
  local native = vim.lsp.inlay_hint.get({ bufnr = context.buffer })
  assert(vim.iter(native):any(function(hint)
    return hint.client_id == client.id and hint.inlay_hint.label == "foreign summary"
  end))
  equal(#marks(context.buffer), 1)
end

tests["pending effective configuration does not assume a document cap"] = function()
  local context = fixture()
  reply(context)
  equal(#marks(context.buffer), 0)
  local annotations = Plugin.status(context.buffer).annotations
  assert(not annotations.effective)
  assert(annotations.problem:find("pending", 1, true))
end

tests["effective cap is reported for empty responses without fallback"] = function()
  local context = fixture()
  reply(context, {})
  configuration(context, { ["limits.rangeLines"] = 1 })
  local annotations = Plugin.status(context.buffer).annotations
  equal(annotations.mode, "front")
  assert(annotations.problem:find("limits.rangeLines", 1, true))
  equal(#marks(context.buffer), 0)
end

tests["late effective lookup from previous mode cannot unblock the new mode"] = function()
  local context = fixture()
  reply(context)
  local old = wait_request(context.transport, "workspace/executeCommand")
  Plugin.summary("above")
  context.transport:reply(old.id, {
    effective = {
      ["messageSummary.enabled"] = true,
      ["messageSummary.channels.inlayHints"] = true,
      ["messageSummary.channels.codeLens"] = false,
      ["limits.rangeLines"] = 2000,
    },
  })
  vim.wait(30)
  equal(#marks(context.buffer), 0)
  equal(Plugin.status(context.buffer).annotations.mode, "above")
end

tests["codelens uses native gate and explicit disable has no fallback"] = function()
  local context = fixture("codelens")
  configuration(context, {
    ["messageSummary.channels.inlayHints"] = false,
    ["messageSummary.channels.codeLens"] = true,
  })
  vim.cmd("redraw!")
  local request = wait_request(context.transport, "textDocument/codeLens")
  context.transport:reply(request.id, {
    {
      range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
      command = { title = "native summary", command = "" },
    },
  })
  vim.wait(30)
  equal(#marks(context.buffer), 0)
  equal(Plugin.status(context.buffer).annotations.mode, "codelens")
  assert(Plugin.status(context.buffer).annotations.native_enabled)
  vim.lsp.codelens.enable(false, { bufnr = context.buffer })
  equal(Plugin.status(context.buffer).annotations.native_enabled, false)
  equal(#marks(context.buffer), 0)
end

local function screen_child()
  local child = MiniTest.new_child_neovim()
  child.start({ "-u", "NONE", "-i", "NONE" })
  MiniTest.finally(child.stop)
  child.lua_func(function(root)
    vim.opt.runtimepath:prepend(root)
    vim.opt.runtimepath:prepend(root .. "/.test-deps/mini.test")
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
    vim.api.nvim_set_option_value("lines", 12, {})
    vim.api.nvim_set_option_value("columns", 42, {})
    vim.api.nvim_set_option_value("laststatus", 0, {})
    vim.api.nvim_set_option_value("ruler", false, {})
    vim.api.nvim_set_option_value("showmode", false, {})
    vim.api.nvim_set_option_value("signcolumn", "no", {})
  end, assert(vim.env.VENUE_READER_TEST_ROOT))
  return child
end

for _, mode in ipairs({ "front", "above" }) do
  tests[mode .. " screen shows first-line Unicode summary exactly once"] = function()
    local child = screen_child()
    child.lua_func(function(selected_mode)
      local SummaryUi = require("tests.support.summary_ui")
      local context = SummaryUi.fixture(selected_mode)
      SummaryUi.reply(context)
      SummaryUi.configuration(context)
      require("tests.support.lsp").wait(function()
        return #SummaryUi.marks(context.buffer) == 1
      end, "screen summary")
      vim.cmd("redraw!")
    end, mode)
    local screenshot = child.get_screenshot()
    local lines = vim.tbl_map(function(line)
      return table.concat(line)
    end, screenshot.text)
    local screen = table.concat(lines, "\n")
    local _, summaries = screen:gsub("Heartbeat λ details", "")
    assert(summaries == 1, screen)
    assert(screen:find("8=FIX.4.4", 1, true), screen)
    if mode == "above" then
      assert(lines[1]:find("Heartbeat λ details", 1, true), screen)
      assert(not lines[1]:find("8=FIX", 1, true), screen)
    else
      assert(lines[1]:find("Heartbeat λ details", 1, true), screen)
    end
  end
end

tests["above preserves two windows with different scroll and fold state"] = function()
  local child = screen_child()
  child.lua_func(function()
    local SummaryUi = require("tests.support.summary_ui")
    local ChildLsp = require("tests.support.lsp")
    local lines = {}
    for index = 1, 40 do
      lines[index] = "row " .. index .. " 8=FIX.4.4|35=0|"
    end
    local context = SummaryUi.fixture("above", lines)
    vim.cmd("setlocal foldmethod=manual nowrap")
    vim.cmd("5,15fold")
    vim.cmd("vsplit")
    local top = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(top, { 1, 0 })
    vim.cmd("normal! zt")
    vim.cmd("wincmd w")
    local later = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(later, { 25, 0 })
    vim.cmd("normal! zt")
    local before = vim.fn.winsaveview()
    SummaryUi.refresh(context)
    local result = SummaryUi.hints("FIRST")
    result[1].label = "FIRST"
    local second = vim.deepcopy(result[1])
    second.position.line = 24
    second.label = "LATER"
    table.insert(result, second)
    SummaryUi.reply(context, result)
    SummaryUi.configuration(context)
    ChildLsp.wait(function()
      return #SummaryUi.marks(context.buffer) == 2
    end, "two-window summary")
    local after = vim.fn.winsaveview()
    assert(after.topline == before.topline)
    assert(after.lnum == before.lnum and after.leftcol == before.leftcol)
    assert(vim.fn.foldclosed(5) == 5)
    assert(vim.wo.wrap == false)
  end)
  local screenshot = child.get_screenshot()
  local screen = table.concat(
    vim.tbl_map(function(line)
      return table.concat(line)
    end, screenshot.text),
    "\n"
  )
  assert(screen:find("FIRST", 1, true), screen)
  assert(screen:find("row 25", 1, true), screen)
end

for _, wrap in ipairs({ true, false }) do
  tests["front long summary preserves wrap=" .. tostring(wrap) .. " and raw buffer"] = function()
    local child = screen_child()
    child.lua_func(function(selected_wrap)
      local SummaryUi = require("tests.support.summary_ui")
      local context = SummaryUi.fixture("front")
      vim.api.nvim_set_option_value("wrap", selected_wrap, { win = 0 })
      local original = vim.api.nvim_buf_get_lines(context.buffer, 0, -1, false)
      SummaryUi.reply(context, SummaryUi.hints("LONGSUMMARY_" .. string.rep("x", 100)))
      SummaryUi.configuration(context)
      require("tests.support.lsp").wait(function()
        return #SummaryUi.marks(context.buffer) == 1
      end, "long summary")
      assert(vim.deep_equal(original, vim.api.nvim_buf_get_lines(context.buffer, 0, -1, false)))
      assert(vim.wo.wrap == selected_wrap)
    end, wrap)
    local screen = table.concat(
      vim.tbl_map(function(line)
        return table.concat(line)
      end, child.get_screenshot().text),
      "\n"
    )
    local _, count = screen:gsub("LONGSUMMARY_", "")
    if wrap then
      assert(count == 1, screen)
    else
      assert(count <= 1 and screen:find("xxxxxxxx", 1, true), screen)
    end
    child.lua_func(function()
      require("venue-reader").summary("off")
      vim.cmd("redraw!")
    end)
    screen = table.concat(
      vim.tbl_map(function(line)
        return table.concat(line)
      end, child.get_screenshot().text),
      "\n"
    )
    assert(not screen:find("LONGSUMMARY_", 1, true), screen)
    assert(screen:find("8=FIX.4.4", 1, true), screen)
  end
end

tests["codelens screen shows native title without owned summary marks"] = function()
  local child = screen_child()
  child.lua_func(function()
    local SummaryUi = require("tests.support.summary_ui")
    local context = SummaryUi.fixture("codelens")
    vim.cmd("redraw!")
    local request = SummaryUi.wait_request(context.transport, "textDocument/codeLens")
    context.transport:reply(request.id, {
      {
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
        command = { title = "NATIVE LENS", command = "" },
      },
    })
    vim.wait(30)
    SummaryUi.configuration(context, {
      ["messageSummary.channels.inlayHints"] = false,
      ["messageSummary.channels.codeLens"] = true,
    })
    assert(#SummaryUi.marks(context.buffer) == 0)
    vim.cmd("redraw!")
  end)
  local screen = table.concat(
    vim.tbl_map(function(line)
      return table.concat(line)
    end, child.get_screenshot().text),
    "\n"
  )
  local _, count = screen:gsub("NATIVE LENS", "")
  assert(count == 1, screen)
end

tests["explicit activation of the same mode restores native hints"] = function()
  local context = fixture("front")
  reply(context)
  configuration(context)
  vim.lsp.inlay_hint.enable(false, { bufnr = context.buffer })
  equal(#marks(context.buffer), 0)
  Plugin.summary("front")
  assert(vim.lsp.inlay_hint.is_enabled({ bufnr = context.buffer }))
  reply(context)
  configuration(context)
  Lsp.wait(function()
    return #marks(context.buffer) == 1
  end, "reactivated front")
end

tests["conflicting effective CodeLens configuration blocks its native backend"] = function()
  local context = fixture("codelens")
  configuration(context, {
    ["messageSummary.channels.inlayHints"] = true,
    ["messageSummary.channels.codeLens"] = true,
  })
  assert(not vim.lsp.codelens.is_enabled({ client_id = context.client.id }))
  assert(Plugin.status(context.buffer).annotations.problem)
  equal(#marks(context.buffer), 0)
end

tests["hidden caches row summaries without marks or cursor requests"] = function()
  local context = fixture("hidden")
  reply(context)
  configuration(context)
  equal(#marks(context.buffer), 0)
  equal(Plugin.current_summary(), "Heartbeat λ details")
  local requests = vim.deepcopy(context.transport.pending)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  equal(Plugin.current_summary(), "")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  equal(Plugin.current_summary(), "Heartbeat λ details")
  equal(context.transport.pending, requests)
  Plugin.summary("off")
  equal(Plugin.current_summary(), "")
  equal(Plugin.current_summary({ format = "chunks" }), {})
end

tests["semantic parts retain base background and preserve null alignment"] = function()
  local context = fixture()
  vim.api.nvim_set_hl(0, "VenueReaderSummary", { bg = 0x112233 })
  vim.api.nvim_set_hl(0, "@lsp.type.number.fix", { fg = 0xff0000 })
  vim.api.nvim_set_hl(0, "@lsp.type.flag.fix", { fg = 0x00ff00 })
  local result = hints()
  result[1].label = { { value = "42" }, { value = " | " }, { value = "100%" }, { value = "end" } }
  result[1].data.tokens = { { "N", 0 }, vim.NIL, { "B", 0 }, { "invalid", -1 } }
  reply(context, result)
  configuration(context)
  local chunks = Plugin.current_summary({ format = "chunks" })
  equal(chunks[1][2], { "VenueReaderSummary", "@lsp.type.number.fix" })
  equal(chunks[2][2], { "VenueReaderSummary" })
  equal(chunks[3][2], { "VenueReaderSummary", "@lsp.type.flag.fix" })
  equal(chunks[4][2], { "VenueReaderSummary" })
  local statusline = Plugin.current_summary({ format = "statusline" })
  assert(statusline:find("100%%", 1, true))
  assert(statusline:sub(-2) == "%*")
  local rendered = vim.api.nvim_eval_statusline(statusline, { highlights = true })
  equal(rendered.str, "42 | 100%end")
  local name = statusline:match("%%#(.-)#")
  local style = vim.api.nvim_get_hl(0, { name = name, link = false })
  equal(style.bg, 0x112233)
  equal(style.fg, 0xff0000)
  vim.api.nvim_set_hl(0, "@lsp.type.number.fix", { fg = 0x123456 })
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  statusline = Plugin.current_summary({ format = "statusline" })
  name = statusline:match("%%#(.-)#")
  equal(vim.api.nvim_get_hl(0, { name = name, link = false }).fg, 0x123456)
end

tests["metadata suppression preserves readable summary and reports source"] = function()
  local context = fixture()
  local result = hints()
  result[1].data.tokens = { { "N", 0 }, { "B", 0 } }
  reply(context, result)
  configuration(context, { ["messageSummary.semanticTokens"] = false })
  equal(Plugin.current_summary(), "Heartbeat λ details")
  for _, chunk in ipairs(Plugin.current_summary({ format = "chunks" })) do
    equal(chunk[2], { "VenueReaderSummary" })
  end
  assert(Plugin.status(context.buffer).annotations.styling:find("disabled", 1, true))
end

tests["monochrome configuration requests no metadata and accessor follows lifecycle"] = function()
  local context = fixture()
  reply(context)
  configuration(context)
  assert(context.client.config.capabilities.experimental.venueReader.summaryTokens == 1)
  local updated = Plugin.status(context.buffer)
  assert(updated.annotations.mode == "front")
  Plugin.setup({
    server = { cmd = { "summary-test", "--stdio" } },
    summary = { semantic_highlighting = false },
  })
  equal(context.client.settings.fix.messageSummary.semanticTokens, false)
  equal(Plugin.current_summary(), "")
  reply(context)
  configuration(context)
  equal(Plugin.current_summary(), "Heartbeat λ details")
  equal(Plugin.current_summary({ format = "chunks" })[1][2], { "VenueReaderSummary" })
  vim.api.nvim_buf_set_lines(context.buffer, 0, 1, false, { "changed" })
  equal(Plugin.current_summary(), "")
end

tests["summary parts stack modifier and type-modifier groups in native order"] = function()
  local context = fixture()
  vim.api.nvim_set_hl(0, "@lsp.type.number.fix", { fg = 0x111111 })
  vim.api.nvim_set_hl(0, "@lsp.mod.peer1.fix", { bg = 0x222222 })
  vim.api.nvim_set_hl(0, "@lsp.typemod.number.peer1.fix", { bold = true })
  local result = hints()
  result[1].data.tokens = { { "N", 2 }, { "N", 128 } }
  reply(context, result)
  configuration(context)
  local chunks = Plugin.current_summary({ format = "chunks" })
  equal(chunks[1][2], {
    "VenueReaderSummary",
    "@lsp.type.number.fix",
    "@lsp.mod.peer1.fix",
    "@lsp.typemod.number.peer1.fix",
  })
  equal(chunks[2][2], { "VenueReaderSummary" })
end

return tests

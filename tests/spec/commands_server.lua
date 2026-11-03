local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local Plugin = require("venue-reader")

local equal = MiniTest.expect.equality
local tests = MiniTest.new_set()
local binary = assert(vim.env.VENUE_READER_TEST_SERVER)

local function setup(settings)
  local ready = {}
  local messages = {}
  local previews = {}
  local original_preview = vim.lsp.util.open_floating_preview
  rawset(vim.lsp.util, "open_floating_preview", function(lines, syntax, options)
    local buffer, window = original_preview(lines, syntax, options)
    previews[#previews + 1] = {
      syntax = syntax,
      text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n"),
      window = window,
    }
    return buffer, window
  end)
  local original_notify = vim.notify
  local clipboard = vim.o.clipboard
  local windows = vim.api.nvim_list_wins()
  vim.api.nvim_set_option_value("clipboard", "", {})
  rawset(vim, "notify", function(message)
    messages[#messages + 1] = tostring(message)
  end)
  Plugin.setup({
    server = { cmd = { binary, "--stdio" } },
    summary = { mode = "off" },
    settings = { fix = settings or {} },
  })
  local config = vim.lsp.config.venue_reader
  -- luacheck: push ignore 122
  config.handlers["textDocument/publishDiagnostics"] = function(err, result, context)
    if not err and result then
      ready[context.client_id .. ":" .. result.uri] = true
    end
    return vim.lsp.handlers["textDocument/publishDiagnostics"](err, result, context)
  end
  -- luacheck: pop
  MiniTest.finally(function()
    vim.lsp.enable("venue_reader", false)
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
      client:stop(true)
    end
    Lsp.wait(function()
      return #vim.lsp.get_clients({ name = "venue_reader" }) == 0
    end, "command session cleanup")
    for _, window in ipairs(vim.api.nvim_list_wins()) do
      if
        not vim.list_contains(windows, window)
        and vim.api.nvim_win_get_config(window).relative ~= ""
      then
        vim.api.nvim_win_close(window, true)
      end
    end
    vim.api.nvim_set_option_value("clipboard", clipboard, {})
    rawset(vim, "notify", original_notify)
    rawset(vim.lsp.util, "open_floating_preview", original_preview)
  end)
  return {
    messages = messages,
    previews = previews,
    attached = function(buffer)
      vim.api.nvim_set_current_buf(buffer)
      local client
      Lsp.wait(function()
        client = vim.lsp.get_clients({ name = "venue_reader", bufnr = buffer })[1]
        return client and ready[client.id .. ":" .. vim.uri_from_bufnr(buffer)]
      end, "committed document configuration")
      return client
    end,
  }
end

local function plain_buffer()
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buffer)
  MiniTest.finally(function()
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end)
  return buffer
end

local function preview_text(fixture, syntax, count)
  assert(
    vim.wait(5000, function()
      return #fixture.previews >= (count or 1)
    end, 10),
    "No preview: " .. vim.inspect(fixture.messages)
  )
  local result = fixture.previews[#fixture.previews]
  equal(result.syntax, syntax)
  return result.text
end

local function overrides(client, buffer)
  return Lsp.request(client, "workspace/executeCommand", {
    command = "fix.describeOverrides",
    arguments = { vim.uri_from_bufnr(buffer) },
  }, buffer)
end

tests["cold reference command starts an unattached reusable native client"] = function()
  local fixture = setup()
  local buffer = plain_buffer()
  vim.cmd("VenueReader tag 35")
  assert(preview_text(fixture, "markdown"):find("MsgType", 1, true))
  equal(vim.bo[buffer].filetype, "")
  equal(#vim.lsp.get_clients({ bufnr = buffer }), 0)
  local session = Plugin.status(buffer).session
  equal(session.buffers, {})
  local client = vim.lsp.get_clients({ name = "venue_reader" })[1]
  equal(client.config.root_dir, vim.fn.getcwd())
  vim.api.nvim_set_current_buf(buffer)
  vim.cmd("VenueReader tag 54 1")
  assert(preview_text(fixture, "markdown", 2):find("Side", 1, true))
  equal(#vim.lsp.get_clients({ name = "venue_reader" }), 1)
  equal(vim.lsp.get_clients({ name = "venue_reader" })[1].id, client.id)
end

tests["cold dictionary choices select an exact identity and attach a later FIX buffer"] = function()
  local fixture = setup()
  local buffer = plain_buffer()
  local original_select = vim.ui.select
  local choices
  rawset(vim.ui, "select", function(items, options, callback)
    choices = items
    local selected = assert(vim.iter(items):find(function(item)
      return item.name == "FIX.4.2"
    end))
    equal(options.format_item(selected), selected.label)
    callback(selected)
  end)
  MiniTest.finally(function()
    rawset(vim.ui, "select", original_select)
  end)
  Plugin.dictionary()
  Lsp.wait(function()
    return #fixture.messages > 0
  end, "selected session dictionary")
  assert(choices and #choices >= 9, vim.inspect({ choices = choices, messages = fixture.messages }))
  local active = vim.lsp.get_clients({ name = "venue_reader" })[1]
  equal(next(active.attached_buffers), nil)
  equal(vim.api.nvim_get_current_buf(), buffer)
  local document = Lsp.buffer()
  equal(fixture.attached(document).id, active.id)
  equal(overrides(active, document).effective.dictionary, "FIX.4.2")
end

tests["cursor decode flushes current edits and writes only returned text"] = function()
  local fixture = setup()
  local buffer = Lsp.buffer()
  fixture.attached(buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "8=FIX.4.4|35=1|112=synthetic|" })
  vim.api.nvim_win_set_cursor(0, { 1, 10 })
  vim.fn.setreg("0", "before", "v")
  vim.cmd("VenueReader yank")
  Lsp.wait(function()
    return vim.fn.getreg("0") ~= "before"
  end, "current snapshot decode")
  assert(vim.fn.getreg("0"):find("TestRequest", 1, true))
  equal(vim.fn.getregtype("0"), "v")
  equal(vim.fn.getreginfo('"').points_to, "0")
end

tests["Ex range preserves physical empty rows and named register semantics"] = function()
  local fixture = setup()
  local buffer = Lsp.buffer({ "8=FIX.4.4|35=0|", "", "8=FIX.4.4|35=1|112=synthetic|" })
  fixture.attached(buffer)
  vim.fn.setreg("0", "keep-zero", "v")
  vim.fn.setreg("a", "before", "v")
  vim.cmd("1,3VenueReader yank a")
  Lsp.wait(function()
    return vim.fn.getreg("a") ~= "before"
  end, "linewise decoded range")
  local rows = vim.fn.getreg("a", 1, true)
  equal(#rows, 3)
  assert(rows[1]:find("Heartbeat", 1, true))
  equal(rows[2], "")
  assert(rows[3]:find("TestRequest", 1, true))
  equal(vim.fn.getregtype("a"), "V")
  equal(vim.fn.getreg("0"), "keep-zero")
  equal(vim.fn.getreginfo('"').points_to, "a")
end

tests["settings preview shows the committed server result"] = function()
  local fixture = setup({ limits = { rangeLines = 17 } })
  local buffer = Lsp.buffer()
  local client = fixture.attached(buffer)
  equal(overrides(client, buffer).effective["limits.rangeLines"], 17)
  Plugin.settings()
  local text = preview_text(fixture, "lua")
  assert(text:find("limits.rangeLines", 1, true))
  assert(text:find("17", 1, true))
end

tests["server range cap reports failure without changing registers"] = function()
  local fixture = setup({ limits = { rangeLines = 1 } })
  local buffer = Lsp.buffer({ "8=FIX.4.4|35=0|", "8=FIX.4.4|35=1|" })
  fixture.attached(buffer)
  vim.fn.setreg("a", "unchanged", "v")
  vim.cmd("1,2VenueReader yank a")
  Lsp.wait(function()
    return #fixture.messages > 0
  end, "range cap error")
  equal(vim.fn.getreg("a"), "unchanged")
  assert(table.concat(fixture.messages, "\n"):find("rangeLines", 1, true))
end

tests["native operator and live Visual block use real structured decode"] = function()
  local fixture = setup()
  local buffer = Lsp.buffer({ "8=FIX.4.4|35=0|", "8=FIX.4.4|35=1|" })
  fixture.attached(buffer)
  vim.keymap.set({ "n", "x" }, "gy", "<Plug>(VenueReaderYank)")
  MiniTest.finally(function()
    vim.keymap.del({ "n", "x" }, "gy")
  end)
  vim.fn.setreg("a", "before", "v")
  vim.api.nvim_win_set_cursor(0, { 1, 10 })
  vim.api.nvim_feedkeys('"agy$', "xt", false)
  Lsp.wait(function()
    return vim.fn.getreg("a") ~= "before"
  end, "native operator decode")
  assert(vim.fn.getreg("a"):find("Heartbeat", 1, true))
  vim.fn.setreg("a", "before-block", "v")
  vim.api.nvim_win_set_cursor(0, { 1, 9 })
  local keys = vim.api.nvim_replace_termcodes('<C-v>j3l"agy', true, false, true)
  vim.api.nvim_feedkeys(keys, "xt", false)
  Lsp.wait(function()
    return vim.fn.getreg("a") ~= "before-block"
  end, "native Visual block decode")
  local rows = vim.fn.getreg("a", 1, true)
  equal(#rows, 2)
  assert(rows[1]:find("Heartbeat", 1, true))
  assert(rows[2]:find("TestRequest", 1, true))
  assert(vim.fn.getregtype("a"):sub(1, 1) == "\22")
end

tests["modeline precedence survives session dictionary selection"] = function()
  local fixture = setup()
  local buffer = Lsp.buffer({ "# fix: dictionary=FIX.4.3", "8=FIX.4.4|35=0|" })
  local client = fixture.attached(buffer)
  Plugin.dictionary("FIX.4.2")
  Lsp.wait(function()
    return #fixture.messages > 0
  end, "session selection response")
  local result = overrides(client, buffer)
  equal(result.effective.dictionary, "FIX.4.3")
  equal(result.sources.dictionary.layer, "modeline")
end

tests["native restart uses latest setup initialization settings"] = function()
  local fixture = setup({ documentLink = { url = "https://example.test/first/{tag}" } })
  local buffer = Lsp.buffer()
  local initial = fixture.attached(buffer)
  Plugin.setup({
    server = { cmd = { binary, "--stdio" } },
    summary = { mode = "off" },
    settings = { fix = { documentLink = { url = "https://example.test/second/{tag}" } } },
  })
  vim.cmd("lsp restart venue_reader")
  local replacement
  Lsp.wait(function()
    replacement = vim.lsp.get_clients({ name = "venue_reader", bufnr = buffer })[1]
    return replacement and replacement.id ~= initial.id
  end, "native restart replacement")
  Plugin.tag(35)
  assert(preview_text(fixture, "markdown"):find("https://example.test/second/35", 1, true))
  equal(replacement.config.venue_reader_initial_settings, replacement.settings)
end

tests["cold explicit global dictionary uses committed initialization settings"] = function()
  local fixture = setup({
    dictionaries = { { name = "synthetic", transport = "FIX.4.2", application = "FIX.4.2" } },
  })
  plain_buffer()
  Plugin.dictionary("synthetic")
  assert(
    vim.wait(5000, function()
      return vim.iter(fixture.messages):any(function(message)
        return message:find("venue-reader: session dictionary synthetic;", 1, true) ~= nil
      end)
    end, 10),
    vim.inspect(fixture.messages)
  )
  local active = vim.lsp.get_clients({ name = "venue_reader" })[1]
  equal(next(active.attached_buffers), nil)
  local buffer = Lsp.buffer()
  equal(fixture.attached(buffer).id, active.id)
  equal(overrides(active, buffer).effective.dictionary, "synthetic")
end

return tests

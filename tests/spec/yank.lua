local MiniTest = require("mini.test")
local tests = MiniTest.new_set()

local equal = MiniTest.expect.equality

local function child(options)
  local process = MiniTest.new_child_neovim()
  process.start({ "-u", "NONE", "-i", "NONE" })
  MiniTest.finally(process.stop)
  process.lua_func(function(root, value)
    vim.opt.runtimepath:prepend(root)
    vim.opt.runtimepath:prepend(root .. "/.test-deps/mini.test")
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
    _G.messages = {}
    rawset(vim, "notify", function(message)
      table.insert(_G.messages, message)
    end)
    _G.copies = {}
    _G.clipboard = { ["+"] = { { "old-plus" }, "v" }, ["*"] = { { "old-star" }, "v" } }
    local function copy(name)
      return function(lines, kind)
        _G.clipboard[name] = { vim.deepcopy(lines), kind }
        _G.copies[#_G.copies + 1] = name
      end
    end
    vim.api.nvim_set_var("clipboard", {
      name = "yank-test",
      cache_enabled = 0,
      copy = { ["+"] = copy("+"), ["*"] = copy("*") },
      paste = {
        ["+"] = function()
          return _G.clipboard["+"]
        end,
        ["*"] = function()
          return _G.clipboard["*"]
        end,
      },
    })
    vim.api.nvim_set_option_value("clipboard", value.clipboard or "", {})
    _G.Fixture = require("tests.support.yank")
    _G.context = _G.Fixture.new(value)
    _G.Yank = require("venue-reader.yank")
    vim.fn.setreg("0", "original-zero", "vu")
    vim.fn.setreg("a", "original-a", "v")
    _G.reply = function(texts, mutate)
      _G.Fixture.reply(_G.context, texts, mutate)
    end
    _G.request = function(command)
      return _G.Fixture.request(_G.context, command)
    end
    _G.state = function(name)
      local register = vim.fn.getreginfo(name or "0")
      return { register.regcontents, register.regtype, vim.fn.getreginfo('"').points_to }
    end
  end, assert(vim.env.VENUE_READER_TEST_ROOT), options or {})
  return process
end

tests["cursor sends one URI-only decode and accepts the native request version"] = function()
  local process = child()
  process.lua("Yank.run()")
  equal(process.lua_get("request().params"), {
    command = "fix.decode",
    arguments = {
      {
        textDocument = { uri = process.lua_get("vim.uri_from_bufnr(context.buffer)") },
        ranges = { { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } } },
      },
    },
  })
  process.lua("reply({[0]='decoded'})")
  equal(process.lua_get("state()"), { { "decoded" }, "v", "0" })
  equal(process.lua_get("messages"), {})
end

tests["default clipboard mirrors and ordinary paste use decoded output"] = function()
  for _, flags in ipairs({ "", "unnamed", "unnamedplus", "unnamed,unnamedplus" }) do
    local process = child({ clipboard = flags })
    process.lua_func(function()
      _G.Yank.run()
      _G.request()
      _G.clipboard["+"] = { { "external" }, "v" }
      _G.reply({ [0] = "decoded" })
    end)
    equal(process.lua_get("state()"), { { "decoded" }, "v", "0" })
    local mirrors = {}
    if flags:find("unnamedplus", 1, true) then
      mirrors[#mirrors + 1] = "+"
    end
    if flags == "unnamed" or flags == "unnamed,unnamedplus" then
      mirrors[#mirrors + 1] = "*"
    end
    equal(process.lua_get("copies"), mirrors)
    process.lua_func(function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
      vim.cmd.normal({ "p", bang = true })
    end)
    equal(process.api.nvim_buf_get_lines(0, 0, -1, false), { "decoded" })
  end
end

tests["explicit destinations append natively and do not mirror or alter register zero"] = function()
  local process = child({ clipboard = "unnamed,unnamedplus" })
  process.lua_func(function()
    _G.Yank.run({ register = "A" })
    _G.reply({ [0] = "decoded" })
  end)
  equal(process.lua_get("state('a')"), { { "original-adecoded" }, "v", "a" })
  equal(process.fn.getreg("0"), "original-zero")
  equal(process.lua_get("copies"), {})
  process.lua_func(function()
    _G.Yank.run({ register = "+" })
    _G.reply({ [0] = "clip" })
  end)
  equal(process.lua_get("copies"), { "+" })
  equal(process.fn.getreg("0"), "original-zero")
  equal(process.lua_get("vim.fn.getreginfo('\"').points_to"), "+")
end

tests["unsupported registers fail before dispatch and blackhole is a no-op"] = function()
  local process = child({ clipboard = "unnamedplus" })
  for _, name in ipairs({ "/", "=", ".", "%", "#", ":", "aa", "" }) do
    process.lua("Yank.run({register=...})", { name })
  end
  equal(process.lua_get("context.transport.next_id"), 1)
  equal(process.lua_get("#messages"), 8)
  process.lua("Yank.run({register='_'})")
  equal(process.lua_get("context.transport.next_id"), 1)
  equal(process.lua_get("state()"), { { "original-zero" }, "v", "0" })
  equal(process.lua_get("copies"), {})
end

tests["register contents pointer and clipboard flags invalidate pending output"] = function()
  for _, mutation in ipairs({ "register_zero", "unnamed_pointer", "clipboard_flags" }) do
    local process = child()
    process.lua_func(function(mutation_name)
      local mutations = {
        register_zero = function()
          vim.fn.setreg("0", "manual", "v")
        end,
        unnamed_pointer = function()
          vim.fn.setreg("a", "manual", "vu")
        end,
        clipboard_flags = function()
          vim.api.nvim_set_option_value("clipboard", "unnamedplus", {})
        end,
      }
      _G.Yank.run()
      _G.request()
      assert(mutations[mutation_name])()
    end, mutation)
    process.lua_func(function()
      _G.before = _G.state()
      _G.reply({ [0] = "late" })
    end)
    equal(process.lua_get("state()"), process.lua_get("before"))
  end
  local process = child()
  process.lua_func(function()
    _G.Yank.run({ register = "A" })
    _G.request()
    vim.fn.setreg("a", "manual", "v")
    _G.reply()
  end)
  equal(process.fn.getreg("a"), "manual")
end

tests["source edits rename detach and client shutdown discard late responses"] = function()
  for _, mutation in ipairs({ "edit", "rename", "detach", "shutdown" }) do
    local process = child()
    process.lua_func(function()
      _G.Yank.run()
      _G.sent = _G.request()
      _G.result = _G.Fixture.result(_G.context, _G.sent)
    end)
    process.lua_func(function(mutation_name)
      local mutations = {
        edit = function()
          vim.api.nvim_buf_set_lines(0, 0, 1, false, { "changed" })
        end,
        rename = function()
          vim.api.nvim_buf_set_name(0, "renamed.fix")
        end,
        detach = function()
          vim.lsp.buf_detach_client(_G.context.buffer, _G.context.client.id)
        end,
        shutdown = function()
          _G.context.client:stop(true)
        end,
      }
      assert(mutations[mutation_name])()
    end, mutation)
    process.lua_func(function()
      if not _G.context.transport.closing then
        _G.context.transport:reply(_G.sent.id, _G.result)
      end
      vim.wait(20)
    end)
    equal(process.fn.getreg("0"), "original-zero")
  end
end

tests["latest invocation cancels the older yank across registers"] = function()
  local process = child()
  process.lua_func(function()
    _G.Yank.run({ register = "a" })
    _G.first = _G.request()
    _G.Yank.run()
    _G.second = _G.request()
    _G.context.transport:reply(
      _G.second.id,
      _G.Fixture.result(_G.context, _G.second, { [0] = "new" })
    )
    vim.wait(20)
    _G.context.transport:reply(
      _G.first.id,
      _G.Fixture.result(_G.context, _G.first, { [0] = "old" })
    )
    vim.wait(20)
  end)
  equal(process.lua_get("state()"), { { "new" }, "v", "0" })
  equal(process.fn.getreg("a"), "original-a")
  equal(process.lua_get("context.transport:notification('$/cancelRequest')"), {
    id = process.lua_get("first.id"),
  })
end

tests["timeout reports once and never commits a late response"] = function()
  local process = child({ timeout_ms = 20 })
  process.lua_func(function()
    _G.Yank.run()
    _G.sent = _G.request()
    vim.wait(100)
    _G.reply({ [0] = "late" })
  end)
  equal(process.fn.getreg("0"), "original-zero")
  local messages = vim.tbl_filter(function(message)
    return message:find("^venue%-reader: ") ~= nil
  end, process.lua_get("messages"))
  equal(messages, { "venue-reader: command timed out" })
end

tests["structured response checks URI version index rows and text before writing"] = function()
  for _, mutation in ipairs({ "uri", "version", "results", "index", "lines", "line", "text" }) do
    local process = child()
    process.lua_func(function(mutation_name)
      local mutations = {
        uri = function(result)
          result.textDocument.uri = "file:///different.fix"
        end,
        version = function(result)
          result.textDocument.version = result.textDocument.version + 1
        end,
        results = function(result)
          result.results = {}
        end,
        index = function(result)
          result.results[1].rangeIndex = 1
        end,
        lines = function(result)
          result.results[1].lines = {}
        end,
        line = function(result)
          result.results[1].lines[1].line = 1
        end,
        text = function(result)
          result.results[1].lines[1].text = false
        end,
      }
      _G.Yank.run()
      _G.reply({ [0] = "decoded" }, assert(mutations[mutation_name]))
    end, mutation)
    equal(process.fn.getreg("0"), "original-zero")
    equal(process.lua_get("#messages"), 1)
  end
end

tests["line output retains empty rows embedded newlines and native paste type"] = function()
  local process = child()
  process.lua_func(function()
    _G.Yank.run({ mode = "line", first = 1, last = 3 })
    _G.reply({ [1] = "middle\nnext" })
  end)
  equal(process.lua_get("state()"), { { "", "middle", "next", "" }, "V", "0" })
  process.lua_func(function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "here" })
    vim.cmd.normal({ "p", bang = true })
  end)
  equal(process.api.nvim_buf_get_lines(0, 0, -1, false), { "here", "", "middle", "next", "" })
end

tests["all empty output preserves registers"] = function()
  local process = child()
  process.lua_func(function()
    _G.Yank.run({ mode = "line", first = 1, last = 3 })
    _G.reply({})
  end)
  equal(process.fn.getreg("0"), "original-zero")
  equal(process.lua_get("#messages"), 1)
end

tests["block cap rejects before row geometry and sends no decode"] = function()
  local process = child()
  process.lua_func(function()
    vim.fn.setpos("'[", { 0, 1, 1, 0 })
    vim.fn.setpos("']", { 0, 3, 1, 1 })
    require("venue-reader.selection").ranges = function()
      error("must not allocate ranges")
    end
    _G.Yank.run({ mode = "block", operator = true })
    local sent = _G.request("fix.describeOverrides")
    assert(vim.deep_equal(sent.params.arguments, { vim.uri_from_bufnr(_G.context.buffer) }))
    _G.context.transport:reply(sent.id, { effective = { ["limits.rangeLines"] = 2 } })
    vim.wait(20)
  end)
  equal(process.lua_get("context.transport.next_id"), 2)
  equal(process.fn.getreg("0"), "original-zero")
  assert(process.lua_get("messages[1]"):find("exceeds", 1, true))
end

tests["block uses one batched decode preserves rows and native decoded width"] = function()
  local process = child()
  process.lua_func(function()
    vim.fn.setpos("'[", { 0, 1, 1, 0 })
    vim.fn.setpos("']", { 0, 3, 1, 1 })
    _G.Yank.run({ mode = "block", operator = true })
    local sent = _G.request("fix.describeOverrides")
    _G.context.transport:reply(sent.id, { effective = { ["limits.rangeLines"] = 10 } })
    _G.sent = _G.request()
    _G.reply({ [0] = "ab", [2] = "xyz" })
  end)
  equal(process.lua_get("#sent.params.arguments[1].ranges"), 3)
  equal(process.lua_get("state()"), { { "ab", "", "xyz" }, "\0223", "0" })
  process.lua_func(function()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "!", "!", "!" })
    vim.cmd.normal({ "p", bang = true })
  end)
  equal(process.api.nvim_buf_get_lines(0, 0, -1, false), { "!ab", "!", "!xyz" })
end

tests["block rejects multiline renderings"] = function()
  for _, value in ipairs({ "a\nb", "a\rb" }) do
    local process = child()
    process.lua_func(function(text)
      vim.fn.setpos("'[", { 0, 1, 1, 0 })
      vim.fn.setpos("']", { 0, 2, 2, 0 })
      _G.Yank.run({ mode = "block", operator = true })
      local sent = _G.request("fix.describeOverrides")
      _G.context.transport:reply(sent.id, { effective = { ["limits.rangeLines"] = 10 } })
      _G.reply({ [0] = text })
    end, value)
    equal(process.fn.getreg("0"), "original-zero")
    equal(process.lua_get("#messages"), 1)
  end
end

tests["operator mapping defaults match commands and explicit named prefixes append"] = function()
  for _, flags in ipairs({ "", "unnamed", "unnamedplus", "unnamed,unnamedplus" }) do
    local process = child({ clipboard = flags })
    process.lua("vim.keymap.set('n','Q',Yank.operator,{expr=true})")
    process.type_keys("Qiw")
    process.lua("reply({[0]='mapped'})")
    equal(process.lua_get("state()"), { { "mapped" }, "v", "0" })
    process.type_keys('"AQiw')
    process.lua("reply({[0]='append'})")
    equal(process.fn.getreg("a"), "original-aappend")
    equal(process.fn.getreg("0"), "mapped")
  end
end

tests["visual mapping captures before leaving Visual and preserves cursor position"] = function()
  local process = child()
  process.lua_func(function()
    vim.keymap.set("x", "Q", function()
      _G.Yank.run({ mode = "visual", mapping = true })
    end)
  end)
  process.type_keys("gg0vjjQ")
  equal(process.lua_get("vim.fn.mode()"), "n")
  equal(process.api.nvim_win_get_cursor(0), { 3, 0 })
  process.lua("reply({[0]='first',[2]='last'})")
  equal(process.lua_get("state()"), { { "first", "", "last" }, "v", "0" })
end

tests["missing clipboard provider and exposed setter errors are reported"] = function()
  local process = child({ clipboard = "unnamedplus" })
  process.lua_func(function()
    local native = vim.fn.has
    rawset(vim.fn, "has", function(feature)
      return feature == "clipboard" and 0 or native(feature)
    end)
    _G.Yank.run()
    _G.reply({ [0] = "decoded" })
  end)
  equal(process.fn.getreg("0"), "original-zero")
  equal(process.lua_get("#messages"), 1)
  local failing = child({ clipboard = "unnamedplus" })
  failing.lua_func(function()
    local native = vim.fn.setreg
    rawset(vim.fn, "setreg", function(name, ...)
      if name == "+" then
        return 1
      end
      return native(name, ...)
    end)
    _G.Yank.run()
    _G.reply({ [0] = "decoded" })
  end)
  equal(failing.fn.getreg("0"), "decoded")
  equal(failing.lua_get("#messages"), 1)
end

tests["blackhole supersedes pending output without writing"] = function()
  local process = child()
  process.lua_func(function()
    _G.Yank.run()
    _G.request()
    _G.Yank.run({ register = "_" })
    _G.reply({ [0] = "late" })
  end)
  equal(process.fn.getreg("0"), "original-zero")
  equal(process.lua_get("#messages"), 0)
end

tests["server errors and malformed block metadata never write"] = function()
  local process = child()
  process.lua_func(function()
    _G.Yank.run()
    local sent = _G.request()
    _G.context.transport:reply(sent.id, nil, { code = -32803, message = "synthetic failure" })
    vim.wait(20)
  end)
  equal(process.fn.getreg("0"), "original-zero")
  equal(process.lua_get("#messages"), 1)
  for _, cap in ipairs({ 0, -1, 1.5, "10" }) do
    process.lua_func(function(limit)
      vim.fn.setpos("'[", { 0, 1, 1, 0 })
      vim.fn.setpos("']", { 0, 2, 2, 0 })
      _G.Yank.run({ mode = "block", operator = true })
      local sent = _G.request("fix.describeOverrides")
      _G.context.transport:reply(sent.id, { effective = { ["limits.rangeLines"] = limit } })
      vim.wait(20)
    end, cap)
    equal(process.fn.getreg("0"), "original-zero")
  end
end

tests["block response indices are unique and physical row order is exact"] = function()
  for _, mutation in ipairs({ "duplicate_index", "wrong_line", "extra_line" }) do
    local process = child()
    process.lua_func(function()
      vim.fn.setpos("'[", { 0, 1, 1, 0 })
      vim.fn.setpos("']", { 0, 2, 2, 0 })
      _G.Yank.run({ mode = "block", operator = true })
      local sent = _G.request("fix.describeOverrides")
      _G.context.transport:reply(sent.id, { effective = { ["limits.rangeLines"] = 10 } })
    end)
    process.lua_func(function(mutation_name)
      local mutations = {
        duplicate_index = function(result)
          result.results[2].rangeIndex = 0
        end,
        wrong_line = function(result)
          result.results[1].lines[1].line = 1
        end,
        extra_line = function(result)
          result.results[1].lines[2] = { line = 1, text = "extra" }
        end,
      }
      _G.reply({ [0] = "first", [1] = "second" }, assert(mutations[mutation_name]))
    end, mutation)
    equal(process.fn.getreg("0"), "original-zero")
    equal(process.lua_get("#messages"), 1)
  end
end

tests["character output preserves embedded and trailing newlines"] = function()
  local process = child()
  process.lua_func(function()
    _G.Yank.run()
    _G.reply({ [0] = "first\nsecond\n" })
  end)
  equal(process.lua_get("state()"), { { "first", "second", "" }, "v", "0" })
end

tests["block tab and wide-character writes use native width and P behavior"] = function()
  local process = child()
  process.lua_func(function()
    vim.fn.setpos("'[", { 0, 1, 1, 0 })
    vim.fn.setpos("']", { 0, 2, 2, 0 })
    _G.Yank.run({ mode = "block", operator = true })
    local sent = _G.request("fix.describeOverrides")
    _G.context.transport:reply(sent.id, { effective = { ["limits.rangeLines"] = 10 } })
    _G.reply({ [0] = "\t", [1] = "😀" })
    vim.fn.setreg("a", { "\t", "😀" }, "b")
    _G.native = vim.fn.getreginfo("a")
    assert(vim.deep_equal(vim.fn.getreginfo("0").regcontents, _G.native.regcontents))
    assert(vim.fn.getregtype("0") == _G.native.regtype)
    assert(_G.native.regtype == "\0222")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "left", "right" })
    vim.cmd.normal({ '"aP', bang = true })
    _G.expected = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "left", "right" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd.normal({ '"0P', bang = true })
  end)
  equal(process.api.nvim_buf_get_lines(0, 0, -1, false), process.lua_get("expected"))
end

tests["operator counts and dot repeat capture fresh source positions"] = function()
  local process = child({ lines = { "one two three four" } })
  process.lua("vim.keymap.set('n','Q',Yank.operator,{expr=true})")
  process.type_keys("2Qw")
  equal(process.lua_get("request().params.arguments[1].ranges[1]['end'].character"), 8)
  process.lua("reply({[0]='first'})")
  process.type_keys("w.")
  equal(process.lua_get("request().params.arguments[1].ranges[1].start.character"), 4)
  process.lua("reply({[0]='repeated'})")
  equal(process.fn.getreg("0"), "repeated")
end

return tests

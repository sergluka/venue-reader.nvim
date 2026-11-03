local M = {}

local Commands = require("venue-reader.commands")
local Selection = require("venue-reader.selection")

local pending

local function notify(message)
  vim.notify("venue-reader: " .. tostring(message), vim.log.levels.ERROR)
end

local function pointer()
  return vim.fn.getreginfo('"').points_to
end

local function register_value(name)
  local info = vim.fn.getreginfo(name)
  return { contents = info.regcontents, kind = info.regtype }
end

local function targets(options, selection)
  local clipboard = vim.o.clipboard
  local flags = vim.split(clipboard, ",", { plain = true })
  local plus = vim.list_contains(flags, "unnamedplus")
  local star = vim.list_contains(flags, "unnamed")
  local name = options.register
  local default = name == nil
  if default and options.mapping then
    name = selection.register
    local implied = plus and "+" or star and "*" or '"'
    default = name == '"' or name == implied
  end
  name = default and "0" or name
  assert(
    type(name) == "string" and #name == 1 and name:match('^["0-9a-zA-Z%-%+%*_]$'),
    "invalid text register"
  )
  if name == '"' then
    name = "0"
  end
  local result = { primary = name, mirrors = {}, clipboard = clipboard, pointer = pointer() }
  if default then
    if plus then
      table.insert(result.mirrors, "+")
    end
    if star then
      table.insert(result.mirrors, "*")
    end
  end
  result.physical = name:lower()
  if name ~= "+" and name ~= "*" and name ~= "_" then
    result.value = register_value(result.physical)
  end
  return result
end

local function unchanged(target)
  return vim.o.clipboard == target.clipboard
    and pointer() == target.pointer
    and (target.value == nil or vim.deep_equal(register_value(target.physical), target.value))
end

local function decoded(result, context, selection, ranges)
  assert(type(result) == "table" and type(result.textDocument) == "table", "invalid decode result")
  assert(result.textDocument.uri == selection.uri, "decode returned a different document")
  assert(
    type(context.version) == "number" and result.textDocument.version == context.version,
    "decode returned a different document version"
  )
  assert(
    type(result.results) == "table" and vim.islist(result.results) and #result.results == #ranges,
    "invalid decode range count"
  )
  local by_index = {}
  for _, item in ipairs(result.results) do
    assert(type(item) == "table", "invalid decode range")
    local index = item.rangeIndex
    assert(
      type(index) == "number"
        and index % 1 == 0
        and index >= 0
        and index < #ranges
        and by_index[index] == nil,
      "invalid decode range index"
    )
    by_index[index] = item
  end
  local texts, nonempty = {}, false
  for index, range in ipairs(ranges) do
    local rows = by_index[index - 1].lines
    local last = math.min(range["end"].line, selection.line_count - 1)
    assert(
      type(rows) == "table" and vim.islist(rows) and #rows == last - range.start.line + 1,
      "invalid decode row count"
    )
    for offset, row in ipairs(rows) do
      assert(
        type(row) == "table"
          and row.line == range.start.line + offset - 1
          and type(row.text) == "string",
        "invalid decode row"
      )
      assert(selection.kind ~= "block" or not row.text:find("[\r\n]"), "multiline block row")
      nonempty = nonempty or row.text ~= ""
      table.insert(texts, row.text)
    end
  end
  return texts, nonempty
end

local function write(target, texts, kind)
  local clipboard = target.primary == "+" or target.primary == "*" or #target.mirrors > 0
  assert(not clipboard or vim.fn.has("clipboard") == 1, "clipboard provider is unavailable")
  local contents = kind == "b" and texts or table.concat(texts, "\n")
  if kind == "V" then
    -- setreg consumes one terminal LF from linewise strings.
    contents = contents .. "\n"
  end
  assert(vim.fn.setreg(target.primary, contents, kind .. "u") == 0, "register write failed")
  for _, name in ipairs(target.mirrors) do
    assert(vim.fn.setreg(name, contents, kind) == 0, "clipboard write failed")
  end
end

local function finish(token)
  if token.operation then
    token.operation:finish()
  end
  if pending == token then
    pending = nil
  end
end

local function valid(token)
  return pending == token
    and token.operation:valid()
    and Selection.valid(token.selection)
    and unchanged(token.target)
end

local function decode(token)
  local selection, operation = token.selection, token.operation
  local success, ranges = pcall(Selection.ranges, selection, operation.client.offset_encoding)
  if not success then
    finish(token)
    notify(ranges)
    return
  end
  operation:request(
    "fix.decode",
    { { textDocument = { uri = selection.uri }, ranges = ranges } },
    function(err, result, context)
      if not valid(token) then
        finish(token)
        return
      end
      local accepted, message = pcall(function()
        assert(not err, type(err) == "table" and err.message or tostring(err))
        local supported, texts, nonempty = pcall(decoded, result, context, selection, ranges)
        assert(
          supported,
          "unsupported fix.decode result (URI/version and physical rows): " .. tostring(texts)
        )
        assert(nonempty, "nothing decoded")
        if valid(token) then
          write(token.target, texts, selection.regtype)
        end
      end)
      finish(token)
      if not accepted then
        notify(message)
      end
    end
  )
end

function M.run(options)
  options = options or {}
  local success, selection, target = pcall(function()
    assert(type(options) == "table", "yank options must be a table")
    local capture = Selection.capture(options)
    return capture, targets(options, capture)
  end)
  if not success then
    notify(selection)
    return
  end
  if pending and pending.operation then
    pending.operation:cancel()
  end
  pending = nil
  if options.mode == "visual" then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  end
  if target.primary == "_" then
    return
  end
  local token = { selection = selection, target = target }
  pending = token
  local operation = Commands.operation(selection.buffer, true, function(ready)
    token.operation = ready
    if not valid(token) then
      finish(token)
      return
    end
    if selection.kind ~= "block" then
      decode(token)
      return
    end
    ready:request("fix.describeOverrides", { selection.uri }, function(err, result)
      if not valid(token) then
        finish(token)
        return
      end
      local cap = type(result) == "table"
        and type(result.effective) == "table"
        and result.effective["limits.rangeLines"]
      if err or type(cap) ~= "number" or cap % 1 ~= 0 or cap < 1 then
        finish(token)
        notify(type(err) == "table" and err.message or "invalid decode range limit")
      elseif selection.row_count > cap then
        finish(token)
        notify("block selection exceeds limits.rangeLines (" .. cap .. ")")
      else
        decode(token)
      end
    end)
  end)
  token.operation = operation
  return operation
end

function M.operator_apply(kind)
  M.run({ mode = kind, operator = true, mapping = true })
end

function M.operator()
  vim.api.nvim_set_option_value(
    "operatorfunc",
    "v:lua.require'venue-reader.yank'.operator_apply",
    { scope = "global" }
  )
  return "g@"
end

return M

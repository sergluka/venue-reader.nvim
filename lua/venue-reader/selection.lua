local M = {}

local modes = { v = "char", V = "line", ["\22"] = "block" }

local function window_options(window, buffer)
  return {
    selection = vim.o.selection,
    ambiwidth = vim.o.ambiwidth,
    tabstop = vim.bo[buffer].tabstop,
    vartabstop = vim.bo[buffer].vartabstop,
    virtualedit = vim.api.nvim_get_option_value("virtualedit", { win = window }),
  }
end

local function ordered(first, last)
  if first[2] > last[2] or (first[2] == last[2] and first[3] > last[3]) then
    return last, first
  end
  return first, last
end

local function line(buffer, row)
  return vim.api.nvim_buf_get_lines(buffer, row - 1, row, true)[1] or ""
end

local function byte_after(text, column)
  if column <= 0 then
    return 0
  end
  local offset = math.min(column - 1, #text)
  if offset == #text then
    return offset
  end
  local following = vim.fn.byteidx(text, vim.fn.charidx(text, offset) + 1)
  return following < 0 and #text or following
end

local function position(row, byte, text, encoding)
  return {
    line = row - 1,
    character = vim.str_utfindex(text, encoding, math.max(0, math.min(byte, #text)), false),
  }
end

function M.capture(options)
  options = options or {}
  local window = options.window or vim.api.nvim_get_current_win()
  local buffer = options.buffer or vim.api.nvim_win_get_buf(window)
  if buffer == 0 then
    buffer = vim.api.nvim_get_current_buf()
  end
  assert(vim.api.nvim_win_get_buf(window) == buffer, "Selection buffer is not in its window")
  return vim.api.nvim_win_call(window, function()
    local kind = options.mode or "cursor"
    local first, last
    local exclusive = false
    local maxcol = false
    if kind == "visual" then
      kind = assert(modes[vim.fn.mode()], "A live Visual selection is required")
      first, last = vim.fn.getpos("v"), vim.fn.getpos(".")
      exclusive = vim.o.selection == "exclusive"
      maxcol = vim.fn.winsaveview().curswant == vim.v.maxcol
    elseif options.operator then
      assert(kind == "char" or kind == "line" or kind == "block", "Invalid operator selection")
      first, last = vim.fn.getpos("'["), vim.fn.getpos("']")
    elseif kind == "line" then
      first = { buffer, options.first or vim.fn.line("."), 1, 0 }
      last = { buffer, options.last or first[2], 1, 0 }
    elseif kind == "cursor" then
      local cursor = vim.api.nvim_win_get_cursor(window)
      first = { buffer, cursor[1], cursor[2] + 1, 0 }
      last = vim.deepcopy(first)
    else
      error("Selection mode needs live Visual or operator positions")
    end
    first[1], last[1] = buffer, buffer
    local count = vim.api.nvim_buf_line_count(buffer)
    assert(
      first[2] >= 1 and last[2] >= 1 and first[2] <= count and last[2] <= count,
      "Invalid selection rows"
    )
    return {
      buffer = buffer,
      window = window,
      tick = vim.api.nvim_buf_get_changedtick(buffer),
      uri = vim.uri_from_bufnr(buffer),
      kind = kind,
      regtype = ({ cursor = "v", char = "v", line = "V", block = "b" })[kind],
      first = first,
      last = last,
      row_count = math.abs(last[2] - first[2]) + 1,
      line_count = count,
      exclusive = exclusive,
      maxcol = maxcol,
      register = vim.v.register,
      options = window_options(window, buffer),
    }
  end)
end

function M.valid(selection)
  return vim.api.nvim_buf_is_valid(selection.buffer)
    and vim.api.nvim_buf_is_loaded(selection.buffer)
    and vim.api.nvim_win_is_valid(selection.window)
    and vim.api.nvim_win_get_buf(selection.window) == selection.buffer
    and vim.api.nvim_buf_get_changedtick(selection.buffer) == selection.tick
    and vim.uri_from_bufnr(selection.buffer) == selection.uri
    and vim.deep_equal(window_options(selection.window, selection.buffer), selection.options)
end

function M.ranges(selection, encoding)
  assert(M.valid(selection), "Selection changed while decoding")
  local buffer = selection.buffer
  local first, last = ordered(selection.first, selection.last)
  if selection.kind == "block" then
    return vim.api.nvim_win_call(selection.window, function()
      local previous = vim.api.nvim_get_option_value("virtualedit", {
        win = selection.window,
        scope = "local",
      })
      local success, regions = pcall(function()
        vim.api.nvim_set_option_value(
          "virtualedit",
          "all",
          { win = selection.window, scope = "local" }
        )
        return vim.fn.getregionpos(selection.first, selection.last, {
          type = "\22",
          exclusive = selection.exclusive,
          eol = true,
        })
      end)
      vim.api.nvim_set_option_value(
        "virtualedit",
        previous,
        { win = selection.window, scope = "local" }
      )
      assert(success, regions)
      local result = {}
      for _, region in ipairs(regions) do
        local row = region[1][2]
        local text = line(buffer, row)
        local start_byte = math.max(0, math.min(region[1][3] - 1, #text))
        local end_byte = selection.maxcol and #text or byte_after(text, region[2][3])
        result[#result + 1] = {
          start = position(row, start_byte, text, encoding),
          ["end"] = position(row, math.max(start_byte, end_byte), text, encoding),
        }
      end
      return result
    end)
  end
  local first_text, last_text = line(buffer, first[2]), line(buffer, last[2])
  local start_byte = math.max(0, math.min(first[3] - 1, #first_text))
  local end_byte
  if selection.kind == "cursor" then
    end_byte = start_byte
  elseif selection.kind == "line" then
    start_byte, end_byte = 0, #last_text
  elseif selection.exclusive and (first[2] ~= last[2] or first[3] ~= last[3]) then
    end_byte = math.max(0, math.min(last[3] - 1, #last_text))
  else
    end_byte = byte_after(last_text, last[3])
  end
  return {
    {
      start = position(first[2], start_byte, first_text, encoding),
      ["end"] = position(last[2], end_byte, last_text, encoding),
    },
  }
end

return M

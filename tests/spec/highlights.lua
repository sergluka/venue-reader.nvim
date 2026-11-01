local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local Plugin = require("venue-reader")

local tests = MiniTest.new_set()
local equal = MiniTest.expect.equality

local function child()
  local process = MiniTest.new_child_neovim()
  process.start({ "-u", "NONE", "-i", "NONE" })
  MiniTest.finally(process.stop)
  process.lua(
    [[
    local root = ...
    vim.opt.runtimepath:prepend(root)
    _G.setup = function()
      require("venue-reader").setup({
        server = { auto_install = false }, summary = { mode = "off" },
      })
    end
  ]],
    { assert(vim.env.VENUE_READER_TEST_ROOT) }
  )
  return process
end

tests["setup links native value types and supplies background-only group defaults"] = function()
  local process = child()
  process.lua([[
    local sources = { "DiffAdd", "DiffChange", "DiffDelete", "DiffText", "Pmenu", "Folded" }
    for index, source in ipairs(sources) do
      vim.api.nvim_set_hl(0, source, { fg = 0xFFFFFF, bg = 0x101010 + index, bold = true })
    end
    setup()
  ]])
  for _, kind in ipairs({ "price", "quantity", "money", "timestamp" }) do
    equal(process.api.nvim_get_hl(0, { name = "@lsp.type." .. kind .. ".fix", link = true }), {
      default = true,
      link = kind == "timestamp" and "@string" or "@number",
    })
  end
  local modifiers = { "group1a", "group1b", "group2a", "group2b", "group3a", "group3b" }
  for index, modifier in ipairs(modifiers) do
    equal(
      process.api.nvim_get_hl(
        0,
        { name = "@lsp.typemod.group." .. modifier .. ".fix", link = false }
      ),
      {
        default = true,
        bg = 0x101010 + index,
      }
    )
  end
end

tests["setup and colorscheme preserve explicitly defined user styles"] = function()
  local process = child()
  local price, group = "@lsp.type.price.fix", "@lsp.typemod.group.group1a.fix"
  local value_style = { fg = 0xABCDEF, underline = true }
  local group_style = { fg = 0x123456, bg = 0x654321, italic = true }
  process.api.nvim_set_hl(0, price, value_style)
  process.api.nvim_set_hl(0, group, group_style)
  local before_value = process.api.nvim_get_hl(0, { name = price, link = false })
  local before_group = process.api.nvim_get_hl(0, { name = group, link = false })
  process.lua("setup(); setup()")
  process.api.nvim_exec_autocmds("ColorScheme", { pattern = "user-theme" })
  equal(process.api.nvim_get_hl(0, { name = price, link = false }), before_value)
  equal(process.api.nvim_get_hl(0, { name = group, link = false }), before_group)
end

tests["colorscheme restores cleared defaults using new theme backgrounds"] = function()
  local process = child()
  process.lua([[
    setup()
    vim.cmd("highlight clear")
    vim.api.nvim_set_hl(0, "DiffAdd", { fg = 0x010203, bg = 0x334455, reverse = true })
    vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "new-theme" })
  ]])
  equal(
    process.api.nvim_get_hl(0, { name = "@lsp.type.price.fix", link = true }),
    { default = true, link = "@number" }
  )
  equal(
    process.api.nvim_get_hl(0, { name = "@lsp.typemod.group.group1a.fix", link = false }),
    { default = true, bg = 0x334455 }
  )
end

tests["cterm-only theme background remains usable without a forced foreground"] = function()
  local process = child()
  process.lua([[
    vim.o.termguicolors = false
    vim.api.nvim_set_hl(0, "DiffAdd", { ctermfg = 1, ctermbg = 4 })
    setup()
  ]])
  equal(
    process.api.nvim_get_hl(0, { name = "@lsp.typemod.group.group1a.fix", link = false }),
    { default = true, ctermbg = 4 }
  )
end

tests["visual selection stays visible over nested group backgrounds"] = function()
  local process = child()
  process.lua([[
    vim.o.termguicolors = true
    -- Terminal attributes must not mask identical RGB colours in screen comparisons.
    local visual = vim.api.nvim_get_hl(0, { name = "Visual", link = false })
    vim.api.nvim_set_hl(0, "Visual", { bg = visual.bg })
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcdefgh", "abcdefgh" })
    setup()
    local namespace = vim.api.nvim_create_namespace("highlight-test")
    for index, modifier in ipairs({ "group2b", "group3b" }) do
      vim.api.nvim_buf_set_extmark(0, namespace, index - 1, 0, {
        end_col = 8,
        hl_group = "@lsp.typemod.group." .. modifier .. ".fix",
        priority = vim.hl.priorities.semantic_tokens + 2,
      })
    end
  ]])
  for row = 1, 2 do
    process.type_keys("<Esc>", row .. "G0vlll")
    local screenshot = process.get_screenshot()
    assert(
      screenshot.attr[row][2] ~= screenshot.attr[row][6],
      "Visual selection is hidden on row " .. row
    )
  end
end

tests["released server supplies native price quantity and repeating-group tokens"] = function()
  local binary = assert(vim.env.VENUE_READER_TEST_SERVER)
  local settings = {
    fix = { inlayHints = { tagNames = { enabled = true }, groupPaths = { enabled = true } } },
  }
  Plugin.setup({
    server = { cmd = { binary, "--stdio" } },
    summary = { mode = "off" },
    settings = settings,
  })
  MiniTest.finally(function()
    vim.lsp.enable("venue_reader", false)
    for _, client in ipairs(vim.lsp.get_clients({ name = "venue_reader" })) do
      client:stop(true)
    end
    Lsp.wait(function()
      return #vim.lsp.get_clients({ name = "venue_reader" }) == 0
    end, "highlight client cleanup")
  end)
  local message = "8=FIX.4.4|35=W|268=2|269=0|270=123.45|271=100|269=1|270=124.45|271=200|"
  local buffer = Lsp.buffer({ message })
  vim.api.nvim_set_current_buf(buffer)
  local active
  Lsp.wait(function()
    active = vim.lsp.get_clients({ bufnr = buffer, name = "venue_reader" })[1]
    return active and active.initialized
  end, "native highlighting attachment")
  local price = assert(message:find("123.45", 1, true)) - 1
  local quantity = assert(message:find("100", 1, true)) - 1
  local tokens
  Lsp.wait(function()
    vim.cmd("redraw!")
    tokens = vim.lsp.semantic_tokens.get_at_pos(buffer, 0, price) or {}
    return vim.iter(tokens):any(function(token)
      return token.type == "price"
    end)
  end, "native price token")
  assert(
    vim.iter(tokens):any(function(token)
      return token.type == "group" and token.modifiers.group1a
    end),
    vim.inspect(tokens)
  )
  assert(vim.iter(vim.lsp.semantic_tokens.get_at_pos(buffer, 0, quantity) or {}):any(function(token)
    return token.type == "quantity"
  end))
  local second_price = assert(message:find("124.45", 1, true)) - 1
  assert(
    vim.iter(vim.lsp.semantic_tokens.get_at_pos(buffer, 0, second_price) or {}):any(function(token)
      return token.type == "group" and token.modifiers.group1b
    end)
  )
  vim.lsp.inlay_hint.enable(true, { bufnr = buffer })
  Lsp.wait(function()
    return #vim.lsp.inlay_hint.get({ bufnr = buffer }) > 0
  end, "native field hints")
  local function labels()
    return table.concat(
      vim.tbl_map(function(item)
        local label = item.inlay_hint.label
        return type(label) == "string" and label
          or table.concat(vim.tbl_map(function(part)
            return part.value
          end, label))
      end, vim.lsp.inlay_hint.get({ bufnr = buffer })),
      "\n"
    )
  end
  assert(labels():find("NoMDEntries/1/MDEntryType", 1, true), labels())
  assert(labels():find("NoMDEntries/2/MDEntryType", 1, true), labels())
  settings.fix.inlayHints.groupPaths.enabled = false
  Plugin.setup({
    server = { cmd = { binary, "--stdio" } },
    summary = { mode = "off" },
    settings = settings,
  })
  Lsp.wait(function()
    local current = labels()
    return current:find("MDEntryType", 1, true) and not current:find("NoMDEntries/1", 1, true)
  end, "group-path switch preserves plain tag names")
  settings.fix.inlayHints.groupPaths.enabled = true
  settings.fix.inlayHints.tagNames.enabled = false
  Plugin.setup({
    server = { cmd = { binary, "--stdio" } },
    summary = { mode = "off" },
    settings = settings,
  })
  Lsp.wait(function()
    local current = labels()
    return current:find("Bid", 1, true) and not current:find("MDEntry", 1, true)
  end, "tag-name switch also removes group paths")
  equal(Plugin.status(buffer).annotations.mode, "off")
  local namespace = vim.api.nvim_create_namespace("venue-reader.summary")
  equal(#vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, {}), 0)
end

return tests

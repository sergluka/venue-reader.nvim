local Fixture = {}

function Fixture.init(root, options)
  Fixture.root = root
  Fixture.messages = {}
  Fixture.calls = 0
  rawset(vim, "notify", function(message)
    Fixture.messages[#Fixture.messages + 1] = message
  end)
  vim.api.nvim_set_option_value("clipboard", "", {})
  if options.parser then
    vim.opt.runtimepath:prepend(root .. "/.test-deps/treesitter/runtime")
  end
  if options.textobjects then
    vim.opt.runtimepath:prepend(root .. "/.test-deps/nvim-treesitter-textobjects")
  end
  if options.manager then
    package.preload["nvim-treesitter.parsers"] = function()
      return {}
    end
    package.preload["nvim-treesitter"] = function()
      return {
        install = function(languages)
          assert(vim.deep_equal(languages, { "fix" }))
          Fixture.calls = Fixture.calls + 1
          package.loaded["nvim-treesitter.parsers"] = nil
          vim.api.nvim_exec_autocmds("User", { pattern = "TSUpdate" })
          Fixture.recipe = require("nvim-treesitter.parsers").fix
          return {
            await = function(_, callback)
              Fixture.pending = callback
            end,
          }
        end,
      }
    end
  end
end

function Fixture.buffer(lines, name)
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buffer)
  if name then
    vim.api.nvim_buf_set_name(buffer, name)
  end
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines or { "8=FIX.4.4|35=0|" })
  vim.api.nvim_set_option_value("filetype", "fix", { buf = buffer })
  return buffer
end

function Fixture.finish(failure, success, parser)
  if parser then
    vim.opt.runtimepath:prepend(Fixture.root .. "/.test-deps/treesitter/runtime")
  end
  local callback = assert(Fixture.pending, "No pending grammar installation")
  Fixture.pending = nil
  callback(failure, success)
end

function Fixture.wait(predicate, description)
  assert(vim.wait(3000, predicate, 10), description)
end

return Fixture

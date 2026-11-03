local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local function child(scenario)
  local lazy_path = assert(vim.env.VENUE_READER_TEST_LAZY)
  vim.api.nvim_set_option_value("loadplugins", true, {})
  vim.opt.runtimepath:prepend(lazy_path)
  require("lazy").setup({
    spec = {
      {
        name = "nvim-treesitter",
        dir = root .. "/.test-deps/nvim-treesitter",
        lazy = true,
        module = false,
        opts = function()
          local install_dir = vim.fn.stdpath("data") .. "/site"
          vim.fn.mkdir(install_dir, "p")
          return { install_dir = install_dir }
        end,
      },
      {
        name = "venue-reader.nvim",
        dir = root,
        dependencies = scenario == "startup" and { "nvim-treesitter" } or nil,
        config = function()
          require("venue-reader").setup({ server = { auto_install = false } })
          vim.lsp.enable("venue_reader", false)
        end,
      },
    },
    root = vim.fn.stdpath("data") .. "/plugins",
    lockfile = vim.fn.stdpath("state") .. "/lazy-lock.json",
    local_spec = false,
    install = { missing = false },
    checker = { enabled = false },
    change_detection = { enabled = false },
  })
  local plugin = require("venue-reader")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "8=FIX.4.4\00135=0\001" })
  vim.api.nvim_set_option_value("filetype", "fix", {})
  if scenario == "late" then
    assert(
      vim.wait(2000, function()
        return plugin.status().treesitter.state == "failed"
      end),
      "Missing manager should fail without blocking startup"
    )
    assert(not vim.b.ts_highlight, "Missing grammar cannot highlight")
    require("lazy").load({ plugins = { "nvim-treesitter" } })
    plugin.install("grammar")
  end
  assert(
    vim.wait(120000, function()
      local state = plugin.status().treesitter.state
      return state == "ready" or state == "failed"
    end, 50),
    vim.inspect(plugin.status().treesitter)
  )
  assert(
    plugin.status().treesitter.state == "ready",
    vim.inspect({
      status = plugin.status().treesitter,
      runtimepath = vim.api.nvim_list_runtime_paths(),
      installed = vim.fn.glob(vim.fn.stdpath("data") .. "/site/parser/*", false, true),
    })
  )
  assert(vim.b.ts_highlight, "Installed grammar must highlight the waiting FIX buffer")
  local manifest =
    vim.json.decode(table.concat(vim.fn.readfile(root .. "/lua/venue-reader/grammar.json"), "\n"))
  local evidence = { scenario = scenario, grammar = manifest, status = plugin.status().treesitter }
  print(vim.json.encode(evidence))
end

local function run()
  if arg[1] then
    child(arg[1])
    return
  end
  local lazy_path = vim.env.VENUE_READER_TEST_LAZY
  assert(
    lazy_path and vim.fn.filereadable(lazy_path .. "/lua/lazy/init.lua") == 1,
    "Set LAZY=/absolute/path/to/lazy.nvim"
  )
  dofile(root .. "/scripts/dependencies.lua").verify_tests()
  local temporary = root .. "/.test-deps/grammar-smoke-" .. vim.uv.os_getpid()
  local evidence = {
    timestamp_utc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    nvim = vim.version(),
    lazy = vim.trim(vim.system({ "git", "-C", lazy_path, "rev-parse", "HEAD" }):wait().stdout),
    scenarios = {},
  }
  for _, scenario in ipairs({ "startup", "late" }) do
    local environment = vim.fn.environ()
    for _, name in ipairs({
      "NVIM",
      "NVIM_LISTEN_ADDRESS",
      "VIM",
      "VIMRUNTIME",
      "VIMINIT",
      "EXINIT",
      "MYVIMRC",
      "LUA_PATH",
      "LUA_CPATH",
    }) do
      environment[name] = nil
    end
    local directories = { "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME" }
    for _, name in ipairs(directories) do
      environment[name] = temporary .. "/" .. scenario .. "/" .. name
      vim.fn.mkdir(environment[name], "p")
    end
    environment.NVIM_LOG_FILE = temporary .. "/" .. scenario .. "/nvim.log"
    print("Live grammar installation: " .. scenario)
    local result = vim
      .system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "-l",
        root .. "/scripts/smoke-grammar.lua",
        scenario,
      }, { cwd = temporary, env = environment, clear_env = true })
      :wait(180000)
    io.stdout:write(result.stdout or "")
    io.stderr:write(result.stderr or "")
    assert(result.code == 0, "Grammar smoke failed; inspect " .. temporary)
    evidence.scenarios[#evidence.scenarios + 1] = {
      name = scenario,
      exit_code = result.code,
      stdout = result.stdout,
      stderr = result.stderr,
    }
  end
  vim.fn.writefile({ vim.json.encode(evidence) }, root .. "/.test-deps/grammar-smoke.json")
  vim.fn.delete(temporary, "rf")
  print("PASS: live grammar installation and explicit retry through isolated Lazy specs")
end

local success, failure = pcall(run)
if not success then
  io.stderr:write(tostring(failure) .. "\n")
  vim.cmd("cquit 1")
end

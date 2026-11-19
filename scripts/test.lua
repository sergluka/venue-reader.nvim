local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local temporary = vim.fn.tempname()
local started = vim.uv.hrtime()

local success, result = pcall(function()
  assert(vim.fn.has("nvim-0.12") == 1, "Neovim >=0.12 is required")
  local available = {
    "real_server",
    "capabilities",
    "native_only",
    "transport",
    "dependencies",
    "lifecycle",
    "native_configuration",
    "installation",
    "summaries",
    "symbols",
    "highlights",
    "selection",
    "commands",
    "yank",
    "commands_server",
    "treesitter",
    "acceptance",
  }
  local suites = #arg > 0 and vim.list_slice(arg)
    or (
      vim.env.VENUE_READER_TEST_SUITE ~= nil
        and vim.env.VENUE_READER_TEST_SUITE ~= ""
        and { vim.env.VENUE_READER_TEST_SUITE }
      or available
    )
  local selected = vim.tbl_map(function(suite)
    assert(vim.tbl_contains(available, suite), "Unknown suite: " .. suite)
    return suite
  end, suites)
  local command_integration = vim.tbl_contains(suites, "commands_server")
  local dependencies = dofile(root .. "/scripts/dependencies.lua")
  dependencies.verify_tests()
  local environment = vim.fn.environ()
  environment.VENUE_READER_TEST_ROOT = root
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
    environment[name] = temporary .. "/" .. name
    vim.fn.mkdir(environment[name], "p")
  end
  if
    vim.tbl_contains(suites, "real_server")
    or vim.tbl_contains(suites, "capabilities")
    or vim.tbl_contains(suites, "native_only")
    or vim.tbl_contains(suites, "lifecycle")
    or vim.tbl_contains(suites, "highlights")
    or command_integration
    or vim.tbl_contains(suites, "treesitter")
    or vim.tbl_contains(suites, "acceptance")
  then
    local binary = vim.env.VENUE_READER_TEST_SERVER
    local override = binary ~= nil and binary ~= ""
    binary = override and vim.fn.fnamemodify(binary, ":p") or dependencies.verify()
    environment.VENUE_READER_TEST_SERVER = binary
    environment.VENUE_READER_TEST_RELEASE = override and "0" or "1"
    io.stdout:write(
      (override and "LOCAL OVERRIDE (not release evidence): " or "VERIFIED RELEASE: ")
        .. binary
        .. "\n"
    )
  end
  local output = vim.env.VENUE_READER_TEST_OUTPUT
  output = output ~= "" and output or nil
  if output and output ~= "" then
    output = vim.fn.fnamemodify(output, ":p")
    vim.fn.mkdir(output, "p")
    environment.VENUE_READER_TEST_OUTPUT = output
  end
  local outcomes = {}
  local exit_code = 0
  for _, suite in ipairs(selected) do
    local suite_started = vim.uv.hrtime()
    local directory = temporary .. "/" .. suite
    vim.fn.mkdir(directory, "p")
    for _, name in ipairs(directories) do
      environment[name] = directory .. "/" .. name
      vim.fn.mkdir(environment[name], "p")
    end
    environment.NVIM_LOG_FILE = directory .. "/nvim.log"
    local report = directory .. "/cases.json"
    if output then
      environment.VENUE_READER_CASE_REPORT = report
    end
    local runner = suite == "native_only" and "/tests/native_only.lua" or "/tests/run.lua"
    local command =
      { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", root .. runner }
    if suite ~= "native_only" then
      command[#command + 1] = root .. "/tests/spec/" .. suite .. ".lua"
    end
    io.stdout:write("Suite: " .. suite .. "\n")
    io.stdout:flush()
    local child =
      vim.system(command, { cwd = directory, env = environment, clear_env = true }):wait(60000)
    io.stdout:write(child.stdout or "")
    io.stderr:write(child.stderr or "")
    local duration = (vim.uv.hrtime() - suite_started) / 1e9
    local outcome = { suite = suite, code = child.code, duration = duration }
    outcomes[#outcomes + 1] = outcome
    io.stdout:write(("Suite duration: %.3f seconds; exit: %d\n"):format(duration, child.code))
    if output then
      if vim.fn.filereadable(report) == 1 then
        outcome.cases = vim.json.decode(table.concat(vim.fn.readfile(report)))
      end
      if not outcome.cases or #outcome.cases == 0 then
        io.stderr:write("No scenario results for " .. suite .. "\n")
        exit_code = 1
      end
      if child.code ~= 0 then
        local logs = output .. "/" .. suite .. "-logs"
        for _, log in ipairs(vim.fn.globpath(directory, "**/*.log", false, true)) do
          local target = logs .. "/" .. vim.fs.basename(log)
          vim.fn.mkdir(logs, "p")
          assert(vim.uv.fs_copyfile(log, target))
        end
      end
      vim.fn.writefile(
        vim.split((child.stdout or "") .. (child.stderr or ""), "\n"),
        output .. "/" .. suite .. ".log"
      )
    end
    if child.code ~= 0 then
      exit_code = 1
    end
  end
  if output then
    vim.fn.writefile({ vim.json.encode(outcomes) }, output .. "/suites.json")
  end
  return exit_code
end)
vim.fn.delete(temporary, "rf")
io.stdout:write(("Test duration: %.3f seconds\n"):format((vim.uv.hrtime() - started) / 1e9))
if not success or result ~= 0 then
  if not success then
    io.stderr:write(tostring(result) .. "\n")
  end
  vim.cmd("cquit 1")
end

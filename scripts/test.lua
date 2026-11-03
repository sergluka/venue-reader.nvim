local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local temporary = vim.fn.tempname()

local success, result = pcall(function()
  assert(vim.fn.has("nvim-0.12") == 1, "Neovim >=0.12 is required")
  local available = {
    "real_server",
    "transport",
    "dependencies",
    "lifecycle",
    "installation",
    "summaries",
    "highlights",
    "selection",
    "commands",
    "yank",
    "commands_server",
  }
  local suites = #arg > 0 and vim.list_slice(arg)
    or (
      vim.env.VENUE_READER_TEST_SUITE ~= nil
        and vim.env.VENUE_READER_TEST_SUITE ~= ""
        and { vim.env.VENUE_READER_TEST_SUITE }
      or available
    )
  local files = vim.tbl_map(function(suite)
    assert(vim.tbl_contains(available, suite), "Unknown suite: " .. suite)
    return root .. "/tests/spec/" .. suite .. ".lua"
  end, suites)
  local command_integration = vim.tbl_contains(suites, "commands_server")
  local dependencies = dofile(root .. "/scripts/dependencies.lua")
  dependencies.verify_tests()
  local environment = vim.fn.environ()
  environment.VENUE_READER_TEST_ROOT = root
  environment.NVIM_LOG_FILE = temporary .. "/nvim.log"
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
    or vim.tbl_contains(suites, "lifecycle")
    or vim.tbl_contains(suites, "highlights")
    or command_integration
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
  local command =
    { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", root .. "/tests/run.lua" }
  vim.list_extend(command, files)
  local child =
    vim.system(command, { cwd = temporary, env = environment, clear_env = true }):wait(60000)
  io.stdout:write(child.stdout or "")
  io.stderr:write(child.stderr or "")
  return child.code
end)
vim.fn.delete(temporary, "rf")
if not success or result ~= 0 then
  if not success then
    io.stderr:write(tostring(result) .. "\n")
  end
  vim.cmd("cquit 1")
end

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local function fail(message)
  io.stderr:write("venue-reader dev: " .. message .. "\n")
  vim.cmd("cquit 1")
end

local function git(arguments)
  local result = vim.system(vim.list_extend({ "git" }, arguments), { text = true }):wait()
  if result.code ~= 0 then
    fail("cannot detect paired worktree; set SERVER_DIR explicitly. " .. (result.stderr or ""))
  end
  return result.stdout
end

local function paired_server()
  if vim.fn.executable("git") ~= 1 then
    fail("Git is required for worktree detection; set SERVER_DIR explicitly")
  end
  local branch = vim.trim(git({ "-C", root, "symbolic-ref", "--quiet", "HEAD" }))
  local common =
    vim.trim(git({ "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir" }))
  local server = vim.fs.dirname(vim.fs.dirname(common)) .. "/venue-reader"
  local worktrees = git({ "-C", server, "worktree", "list", "--porcelain", "-z" })
  local directory
  local matches = {}
  for field in worktrees:gmatch("[^%z]+") do
    if field:sub(1, 9) == "worktree " then
      directory = field:sub(10)
    elseif
      field == "branch " .. branch and vim.fn.filereadable(directory .. "/Cargo.toml") == 1
    then
      matches[#matches + 1] = directory
    end
  end
  if #matches ~= 1 then
    fail(
      ("expected one server worktree on %s, found %d; set SERVER_DIR explicitly"):format(
        branch,
        #matches
      )
    )
  end
  return matches[1]
end

local directory = vim.env.VENUE_READER_DEV_SERVER_DIR
if not directory or directory == "" then
  directory = paired_server()
end
directory = vim.fs.normalize(vim.fn.fnamemodify(directory, ":p"))
local manifest = directory .. "/Cargo.toml"
if vim.fn.filereadable(manifest) ~= 1 then
  fail("Cargo.toml not found in " .. directory)
end
if vim.fn.executable("cargo") ~= 1 then
  fail("cargo is required to build the selected server")
end
io.stderr:write("Building venue-reader in " .. directory .. "\n")
local result = vim
  .system({
    "cargo",
    "build",
    "--manifest-path",
    manifest,
    "--bin",
    "venue-reader",
    "--message-format=json-render-diagnostics",
  }, { cwd = directory, text = true })
  :wait()
io.stderr:write(result.stderr or "")
if result.code ~= 0 then
  fail("server build failed; exit code " .. result.code)
end
local binary
for line in (result.stdout or ""):gmatch("[^\n]+") do
  local artifact = vim.json.decode(line)
  if
    artifact.reason == "compiler-artifact"
    and artifact.target.name == "venue-reader"
    and artifact.executable
  then
    binary = artifact.executable
  end
end
if not binary then
  fail("Cargo did not report a venue-reader executable")
end
vim.fn.setenv("VENUE_READER_DEV_PLUGIN_DIR", root)
vim.fn.setenv("VENUE_READER_DEV_SERVER", binary)
local config = vim.fn.stdpath("config")
local init = config .. "/init.lua"
if vim.fn.filereadable(init) ~= 1 then
  init = config .. "/init.vim"
end
if vim.fn.filereadable(init) ~= 1 then
  fail("no init.lua or init.vim found in " .. config)
end
io.stderr:write("Development plugin: " .. root .. "\nDevelopment server: " .. binary .. "\n")
vim.fn.setenv("MYVIMRC", init)
vim.cmd.source({ args = { init } })

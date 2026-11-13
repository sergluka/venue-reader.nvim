local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local function fail(message)
  io.stderr:write("venue-reader dev: " .. message .. "\n")
  vim.cmd("cquit 1")
end

local function git(arguments)
  local result = vim.system(vim.list_extend({ "git" }, arguments), { text = true }):wait()
  if result.code ~= 0 then
    fail("cannot detect main checkout; set SERVER_DIR explicitly. " .. (result.stderr or ""))
  end
  return result.stdout
end

local function selected_server()
  if vim.fn.executable("git") ~= 1 then
    fail("Git is required for checkout detection; set SERVER_DIR explicitly")
  end
  local common =
    vim.trim(git({ "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir" }))
  local repositories = vim.fs.dirname(vim.fs.dirname(common))
  local workspaces = vim.fs.dirname(repositories) .. "/workspaces"
  local parent = vim.fs.dirname(root)
  if vim.fs.basename(repositories) == "repos" and vim.fn.isdirectory(workspaces) == 1 then
    local function feature(directory)
      local relative = directory:sub(#workspaces + 2)
      if directory:sub(1, #workspaces + 1) == workspaces .. "/" and relative ~= "" then
        return workspaces .. "/" .. relative:match("^[^/]+")
      end
    end
    parent = feature(vim.fn.getcwd()) or feature(root) or repositories
  end
  local candidate = parent .. "/venue-reader"
  if vim.uv.fs_lstat(candidate) then
    return candidate
  end
  return repositories .. "/venue-reader"
end

local directory = vim.env.VENUE_READER_DEV_SERVER_DIR
if not directory or directory == "" then
  directory = selected_server()
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

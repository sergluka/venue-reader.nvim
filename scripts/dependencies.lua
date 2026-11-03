local M = {}

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local function read(filename)
  local file = assert(io.open(filename, "rb"), "Cannot read " .. filename)
  local content = file:read("*a")
  file:close()
  return content
end

local manifest = vim.json.decode(read(root .. "/tests/dependencies.json"))
manifest.server = dofile(root .. "/lua/venue-reader/release.lua")
manifest.grammar = vim.json.decode(read(root .. "/lua/venue-reader/grammar.json"))
M.version = manifest.server.version

local function run(command, options)
  local result = vim.system(command, options):wait(120000)
  assert(result.code == 0, command[1] .. " failed: " .. (result.stderr or ""))
  return result.stdout
end

local function release()
  local system = vim.uv.os_uname()
  local architecture = ({ arm64 = "aarch64", AMD64 = "x86_64" })[system.machine] or system.machine
  local suffix = ({
    Linux = "unknown-linux-gnu",
    Darwin = "apple-darwin",
    Windows_NT = "pc-windows-msvc",
  })[system.sysname]
  local target = architecture .. "-" .. (suffix or "unsupported")
  local artifact = assert(manifest.server.artifacts[target], "No pinned artifact; use SERVER=/path")
  local windows = suffix == "pc-windows-msvc"
  return artifact,
    root .. "/.test-deps/" .. M.version .. "/" .. target,
    windows and "venue-reader.exe" or "venue-reader",
    windows and "" or "venue-reader-" .. target .. "/"
end

local function test_sources()
  return {
    { "mini.test", manifest.mini_test },
    { "nvim-treesitter", manifest.treesitter },
    { "nvim-treesitter-textobjects", manifest.textobjects },
    { "tree-sitter-fix", manifest.grammar },
  }
end

local function verify_source(name, source)
  local directory = root .. "/.test-deps/" .. name
  assert(
    vim.fn.isdirectory(directory .. "/.git") == 1,
    name .. " is missing; run make prepare-tests"
  )
  assert(
    vim.trim(run({ "git", "-C", directory, "rev-parse", "HEAD" })) == source.commit,
    name .. " revision differs from pin; remove its .test-deps checkout and prepare again"
  )
  run({ "git", "-C", directory, "diff", "--exit-code", "HEAD", "--" })
  return directory
end

local parser_root = root .. "/.test-deps/treesitter"
local parser_file = parser_root .. "/runtime/parser/fix.so"
local parser_record = parser_root .. "/build.json"

local function verify_parser()
  assert(
    vim.fn.filereadable(parser_file) == 1 and vim.fn.filereadable(parser_record) == 1,
    "FIX test parser is missing; run make prepare-tests"
  )
  local build = vim.json.decode(read(parser_record))
  assert(
    build.commit == manifest.grammar.commit,
    "FIX test parser source revision differs from pin"
  )
  assert(build.sha256 == vim.fn.sha256(read(parser_file)), "FIX test parser checksum differs")
  return parser_root .. "/runtime"
end

function M.verify_tests()
  for _, entry in ipairs(test_sources()) do
    verify_source(entry[1], entry[2])
  end
  verify_parser()
  return root .. "/.test-deps/mini.test"
end

function M.prepare_tests()
  for _, entry in ipairs(test_sources()) do
    local name, source = entry[1], entry[2]
    local directory = root .. "/.test-deps/" .. name
    if vim.fn.isdirectory(directory) == 0 then
      run({ "git", "init", directory })
      run({ "git", "-C", directory, "fetch", "--depth", "1", source.repository, source.commit })
      run({ "git", "-C", directory, "checkout", "--detach", "FETCH_HEAD" })
    end
    verify_source(name, source)
  end
  if vim.fn.filereadable(parser_record) == 0 then
    local compiler = vim.trim(run({ "tree-sitter", "--version" }))
    vim.fn.mkdir(vim.fs.dirname(parser_file), "p")
    run({ "tree-sitter", "build", "-o", parser_file }, {
      cwd = root .. "/.test-deps/tree-sitter-fix",
    })
    vim.fn.writefile({
      vim.json.encode({
        commit = manifest.grammar.commit,
        compiler = compiler,
        sha256 = vim.fn.sha256(read(parser_file)),
      }),
    }, parser_record)
  end
  return M.verify_tests()
end

local function checksum(filename, artifact)
  assert(vim.fn.sha256(read(filename)) == artifact.sha256, "SHA-256 mismatch: " .. filename)
end

function M.verify()
  local artifact, directory, executable, prefix = release()
  local archive = directory .. "/" .. artifact.archive
  assert(vim.fn.filereadable(archive) == 1, "Pinned server is missing; run make prepare")
  checksum(archive, artifact)
  local original = prefix == "" and run({ "unzip", "-p", archive, executable })
    or run({ "tar", "-xOf", archive, prefix .. executable })
  local binary = directory .. "/" .. executable
  assert(read(binary) == original, "Prepared binary differs from verified archive: " .. binary)
  assert(
    vim.trim(run({ binary, "--version" })) == "venue-reader " .. M.version,
    "Unexpected server version"
  )
  return binary
end

function M.prepare(source)
  local artifact, directory, executable, prefix = release()
  if source and source ~= "" then
    checksum(source, artifact)
  end
  if vim.fn.isdirectory(directory) == 1 then
    return M.verify()
  end
  local staging = directory .. ".tmp-" .. vim.uv.os_getpid()
  vim.fn.mkdir(staging, "p")
  local success, failure = pcall(function()
    local archive = staging .. "/" .. artifact.archive
    if source and source ~= "" then
      assert(vim.uv.fs_copyfile(source, archive))
    else
      run({
        "curl",
        "--fail",
        "--location",
        "--connect-timeout",
        "10",
        "--max-time",
        "60",
        "--output",
        archive,
        manifest.server.base_url .. artifact.archive,
      })
    end
    checksum(archive, artifact)
    -- Only pinned, verified release bytes reach the standard extractor.
    if prefix == "" then
      run({ "unzip", "-q", archive, "-d", staging })
    else
      run({ "tar", "-xf", archive, "--strip-components=1", "-C", staging })
    end
    assert(
      vim.trim(run({ staging .. "/" .. executable, "--version" })) == "venue-reader " .. M.version,
      "Unexpected server version"
    )
    assert(vim.uv.fs_rename(staging, directory))
  end)
  vim.fn.delete(staging, "rf")
  assert(success, failure)
  return M.verify()
end

return M

local Dependencies = {}
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))

local function read(filename)
  local file = assert(io.open(filename, "rb"), "Cannot read " .. filename)
  local content = file:read("*a")
  file:close()
  return content
end

local manifest = vim.json.decode(read(root .. "/tests/dependencies.json"))
manifest.server = dofile(root .. "/lua/venue-reader/release.lua")
Dependencies.version = manifest.server.version

local function run(command)
  local result = vim.system(command):wait(120000)
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
    root .. "/.test-deps/" .. Dependencies.version .. "/" .. target,
    windows and "venue-reader.exe" or "venue-reader",
    windows and "" or "venue-reader-" .. target .. "/"
end

function Dependencies.verify_tests()
  local directory = root .. "/.test-deps/mini.test"
  assert(
    vim.fn.filereadable(directory .. "/lua/mini/test.lua") == 1,
    "mini.test is missing; run make prepare-tests"
  )
  assert(
    vim.trim(run({ "git", "-C", directory, "rev-parse", "HEAD" })) == manifest.mini_test.commit,
    "mini.test revision differs from the pinned commit"
  )
  run({ "git", "-C", directory, "diff", "--exit-code", "HEAD", "--" })
  return directory
end

function Dependencies.prepare_tests()
  local directory = root .. "/.test-deps/mini.test"
  if vim.fn.isdirectory(directory) == 0 then
    run({
      "git",
      "clone",
      "--depth",
      "1",
      "--branch",
      manifest.mini_test.tag,
      manifest.mini_test.repository,
      directory,
    })
  end
  return Dependencies.verify_tests()
end

local function checksum(filename, artifact)
  assert(vim.fn.sha256(read(filename)) == artifact.sha256, "SHA-256 mismatch: " .. filename)
end

function Dependencies.verify()
  local artifact, directory, executable, prefix = release()
  local archive = directory .. "/" .. artifact.archive
  assert(vim.fn.filereadable(archive) == 1, "Pinned server is missing; run make prepare")
  checksum(archive, artifact)
  local original = prefix == "" and run({ "unzip", "-p", archive, executable })
    or run({ "tar", "-xOf", archive, prefix .. executable })
  local binary = directory .. "/" .. executable
  assert(read(binary) == original, "Prepared binary differs from verified archive: " .. binary)
  assert(
    vim.trim(run({ binary, "--version" })) == "venue-reader " .. Dependencies.version,
    "Unexpected server version"
  )
  return binary
end

function Dependencies.prepare(source)
  local artifact, directory, executable, prefix = release()
  if source and source ~= "" then
    checksum(source, artifact)
  end
  if vim.fn.isdirectory(directory) == 1 then
    return Dependencies.verify()
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
      vim.trim(run({ staging .. "/" .. executable, "--version" }))
        == "venue-reader " .. Dependencies.version,
      "Unexpected server version"
    )
    assert(vim.uv.fs_rename(staging, directory))
  end)
  vim.fn.delete(staging, "rf")
  assert(success, failure)
  return Dependencies.verify()
end

return Dependencies

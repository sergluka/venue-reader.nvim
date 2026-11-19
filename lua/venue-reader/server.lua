local Server = {}

local manifest = require("venue-reader.release")
local jobs = {}
local current = { state = "idle" }

local function run(command, callback, timeout)
  local stdout, stderr, size, process = {}, {}, 0
  local overflow = false

  local function collect(destination)
    return function(_, chunk)
      if not chunk then
        return
      end
      size = size + #chunk
      if size > 65536 then
        overflow = true
        if process then
          process:kill(9)
        end
      else
        destination[#destination + 1] = chunk
      end
    end
  end
  local ok, result = pcall(vim.system, command, {
    timeout = timeout or 60000,
    stdout = collect(stdout),
    stderr = collect(stderr),
  }, function(exit)
    vim.schedule(function()
      local error = overflow and "subprocess output exceeded 64 KiB"
        or exit.code ~= 0 and (command[1] .. " failed (" .. exit.code .. "): " .. table.concat(
          stderr
        ))
        or nil
      callback(error, table.concat(stdout))
    end)
  end)
  process = ok and result or nil
  if not ok then
    vim.schedule(function()
      callback(tostring(result))
    end)
  end
end

local function probe(binary, callback)
  run({ binary, "--version" }, function(error, output)
    local version = output and output:match("^venue%-reader (%d+%.%d+%.%d+)%s*$")
    local series = version and version:match("^(%d+%.%d+)%.%d+$")
    callback(
      error
        or (series ~= manifest.series and "Unsupported server version: " .. vim.trim(output or ""))
        or nil,
      version
    )
  end, 5000)
end

local function install(target, system, directory, callback)
  local artifact = manifest.artifacts[target]
  if not artifact then
    callback("No release for " .. target .. "; set server.cmd to a compatible binary")
    return
  end
  local windows = system == "Windows_NT"
  local downloader = windows and "curl.exe" or "curl"
  local extractor = windows and "tar.exe" or "tar"
  local hasher = windows and "certutil.exe" or system == "Darwin" and "shasum" or "sha256sum"
  for _, tool in ipairs({ downloader, extractor, hasher }) do
    if vim.fn.executable(tool) ~= 1 then
      callback("Missing " .. tool .. "; install it or set server.cmd to a compatible binary")
      return
    end
  end
  vim.fn.mkdir(vim.fs.dirname(directory), "p")
  local staging, failure = vim.uv.fs_mkdtemp(directory .. ".tmp-XXXXXX")
  if not staging then
    callback("Cannot create staging directory: " .. tostring(failure))
    return
  end
  local archive = staging .. "/release.archive"
  local contents = staging .. "/contents"
  vim.fn.mkdir(contents)
  local binary = windows and "venue-reader.exe" or "venue-reader"
  local prefix = windows and "" or "venue-reader-" .. target .. "/"

  local function finish(error, argv, version)
    vim.fn.delete(staging, "rf")
    callback(error, argv, version)
  end

  local function publish()
    local prepared = contents .. "/" .. prefix .. binary
    probe(prepared, function(error, version)
      if error or version ~= manifest.version then
        finish(error or "Unexpected release version")
        return
      end
      local published = vim.uv.fs_rename(
        prefix == "" and contents or contents .. "/" .. prefix:sub(1, -2),
        directory
      )
      if published then
        finish(nil, { directory .. "/" .. binary, "--stdio" }, version)
      else
        -- Another process may have published the same immutable release.
        probe(directory .. "/" .. binary, function(winner_error, winner_version)
          if winner_error or winner_version ~= manifest.version then
            finish("Cannot publish installation: " .. (winner_error or "unexpected version"))
          else
            finish(nil, { directory .. "/" .. binary, "--stdio" }, winner_version)
          end
        end)
      end
    end)
  end

  local function inventory()
    run({ extractor, "-tf", archive }, function(error, output)
      if error then
        finish(error)
        return
      end
      local allowed = {
        [binary] = true,
        LICENSE = true,
        NOTICE = true,
        ["THIRD_PARTY_LICENSES.txt"] = true,
        ["DEPENDENCY_LICENSES.txt"] = true,
        ["CHANGELOG.md"] = true,
        ["README.md"] = true,
      }
      local seen = {}
      for name in output:gmatch("[^\r\n]+") do
        if name ~= prefix then
          local relative = name:sub(#prefix + 1)
          if name:sub(1, #prefix) ~= prefix or not allowed[relative] or seen[relative] then
            finish("Unexpected archive member: " .. name)
            return
          end
          seen[relative] = true
        end
      end
      for _, required in ipairs({
        binary,
        "LICENSE",
        "NOTICE",
        "THIRD_PARTY_LICENSES.txt",
        "DEPENDENCY_LICENSES.txt",
      }) do
        if not seen[required] then
          finish("Missing archive member: " .. required)
          return
        end
      end
      run({ extractor, "-tvf", archive }, function(list_error, listing)
        if list_error then
          finish(list_error)
          return
        end
        for line in listing:gmatch("[^\r\n]+") do
          if
            not line:match("^[-d]") or line:sub(1, 1) == "d" and not vim.endswith(line, prefix)
          then
            finish("Archive contains links or special entries")
            return
          end
        end
        run({ extractor, "-xf", archive, "-C", contents }, function(extract_error)
          if extract_error then
            finish(extract_error)
          else
            publish()
          end
        end)
      end)
    end)
  end
  current.state = "downloading"
  run({
    downloader,
    "--fail",
    "--location",
    "--proto",
    "=https",
    "--proto-redir",
    "=https",
    "--connect-timeout",
    "10",
    "--max-time",
    "60",
    "--max-filesize",
    "104857600",
    "--output",
    archive,
    manifest.base_url .. artifact.archive,
  }, function(error)
    if error then
      finish(error)
      return
    end
    current.state = "verifying"
    local command = windows and { hasher, "-hashfile", archive, "SHA256" }
      or system == "Darwin" and { hasher, "-a", "256", archive }
      or { hasher, archive }
    run(command, function(hash_error, output)
      local digest
      for candidate in (output or ""):gmatch("%x+") do
        if #candidate == 64 then
          digest = candidate:lower()
          break
        end
      end
      if hash_error or not digest or digest:lower() ~= artifact.sha256 then
        finish(hash_error or "Release SHA-256 mismatch")
      else
        inventory()
      end
    end)
  end)
end

function Server.resolve(options, callback, retry)
  options = options or {}
  local key = vim.inspect({ options.cmd, options.auto_install ~= false })
  local job = jobs[key]
  if job and not retry then
    if job.waiters then
      job.waiters[#job.waiters + 1] = callback
    else
      vim.schedule(function()
        callback(job.error, vim.deepcopy(job.argv), job.version)
      end)
    end
    return
  end
  if job and job.waiters then
    job.waiters[#job.waiters + 1] = callback
    return
  end
  job = { waiters = { callback } }
  jobs[key] = job
  current = { state = "discovering" }

  local function finish(error, argv, version)
    job.error, job.argv, job.version = error, argv, version
    current = {
      state = error and "failed" or "ready",
      error = error,
      argv = argv,
      version = version,
      reason = job.reason,
    }
    local waiters = job.waiters
    job.waiters = nil
    for _, waiter in ipairs(waiters) do
      waiter(error, vim.deepcopy(argv), version)
    end
  end
  if options.cmd then
    if not vim.islist(options.cmd) or #options.cmd == 0 then
      finish("server.cmd must be a nonempty argv list")
      return
    end
    for _, argument in ipairs(options.cmd) do
      if type(argument) ~= "string" or argument == "" then
        finish("server.cmd arguments must be nonempty strings")
        return
      end
    end
    probe(options.cmd[1], function(error, version)
      finish(error, not error and vim.deepcopy(options.cmd) or nil, version)
    end)
    return
  end
  local target, system = manifest.platform()
  local directory =
    vim.fs.joinpath(vim.fn.stdpath("data"), "venue-reader", manifest.version, target)
  local binary = system == "Windows_NT" and "venue-reader.exe" or "venue-reader"

  local function managed()
    local path = directory .. "/" .. binary
    if vim.fn.filereadable(path) == 1 then
      probe(path, function(error, version)
        finish(
          error and ("Managed binary " .. path .. ": " .. error) or nil,
          not error and { path, "--stdio" } or nil,
          version
        )
      end)
    elseif options.auto_install == false then
      finish("No compatible server; set server.cmd or run :VenueReader install server")
    elseif not manifest.pinned then
      finish(
        "No compatible release pinned yet; set server.cmd to a " .. manifest.series .. ".x binary"
      )
    else

      local function acquire()
        install(target, system, directory, finish)
      end
      if system == "Linux" and manifest.artifacts[target] then
        run({ "getconf", "GNU_LIBC_VERSION" }, function(error, output)
          local major, minor = (output or ""):match("glibc (%d+)%.(%d+)")
          if
            error
            or not major
            or tonumber(major) < 2
            or tonumber(major) == 2 and tonumber(minor) < 35
          then
            finish(
              "Automatic installation requires glibc >=2.35; set server.cmd to a compatible binary"
            )
          else
            acquire()
          end
        end)
      else
        acquire()
      end
    end
  end
  local path = vim.fn.exepath("venue-reader")
  if path == "" then
    managed()
  else
    probe(path, function(error, version)
      if error then
        job.reason = "PATH candidate: " .. error
        managed()
      else
        finish(nil, { path, "--stdio" }, version)
      end
    end)
  end
end

function Server.status()
  return vim.deepcopy(current)
end

return Server

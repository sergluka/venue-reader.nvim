local Server = {}

local manifest = require("venue-reader.release")
local jobs = {}
local current = { state = "idle" }

function Server.message(message, level)
  local highlight = level == vim.log.levels.WARN and "WarningMsg" or nil
  vim.api.nvim_echo({ { "venue-reader: " .. message, highlight } }, true, {
    err = level == vim.log.levels.ERROR,
  })
end

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
    if not error and not manifest.compatible(version) then
      error = "Unsupported server version: " .. vim.trim(output or "")
    end
    callback(error, version)
  end, 5000)
end

local function install(selected, target, system, directory, callback, progress)
  local artifact = selected.artifacts[target]
  local windows = system == "Windows_NT"
  local downloader = windows and "curl.exe" or "curl"
  local extractor = windows and "tar.exe" or "tar"
  local hasher = windows and "certutil.exe" or system == "Darwin" and "shasum" or "sha256sum"
  for _, tool in ipairs({ downloader, extractor, hasher }) do
    if vim.fn.executable(tool) ~= 1 then
      callback("Missing " .. tool .. " for server installation")
      return
    end
  end
  local created, mkdir_error = pcall(vim.fn.mkdir, vim.fs.dirname(directory), "p")
  if not created then
    callback("Cannot create installation directory: " .. tostring(mkdir_error))
    return
  end
  local staging, failure = vim.uv.fs_mkdtemp(directory .. ".tmp-XXXXXX")
  if not staging then
    callback("Cannot create staging directory: " .. tostring(failure))
    return
  end
  local archive = staging .. "/release.archive"
  local contents = staging .. "/contents"
  created, mkdir_error = pcall(vim.fn.mkdir, contents)
  if not created then
    vim.fn.delete(staging, "rf")
    callback("Cannot create extraction directory: " .. tostring(mkdir_error))
    return
  end
  local binary = windows and "venue-reader.exe" or "venue-reader"
  local prefix = windows and "" or "venue-reader-" .. target .. "/"

  local function finish(error, argv, version, published)
    vim.fn.delete(staging, "rf")
    callback(error, argv, version, published)
  end

  local function publish()
    local prepared = contents .. "/" .. prefix .. binary
    probe(prepared, function(error, version)
      if error or version ~= selected.version then
        finish(error or "Unexpected release version")
        return
      end
      local published = vim.uv.fs_rename(
        prefix == "" and contents or contents .. "/" .. prefix:sub(1, -2),
        directory
      )
      if published then
        finish(nil, { directory .. "/" .. binary, "--stdio" }, version, true)
      else
        -- Another process may have published the same immutable release.
        probe(directory .. "/" .. binary, function(winner_error, winner_version)
          if winner_error or winner_version ~= selected.version then
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
  if progress then
    progress("downloading")
  end
  run({
    downloader,
    "--disable",
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
    selected.base_url .. artifact.archive,
  }, function(error)
    if error then
      finish(error)
      return
    end
    if progress then
      progress("verifying")
    end
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

local function managed_path(version, target, system)
  local binary = system == "Windows_NT" and "venue-reader.exe" or "venue-reader"
  return vim.fs.joinpath(vim.fn.stdpath("data"), "venue-reader", version, target, binary)
end

local function installed_versions()
  local root = vim.fs.joinpath(vim.fn.stdpath("data"), "venue-reader")
  local versions = {}
  for name, kind in vim.fs.dir(root) do
    if kind == "directory" and manifest.compatible(name) then
      versions[#versions + 1] = name
    end
  end
  table.sort(versions, manifest.newer)
  return versions
end

local function check_host(target, system, callback)
  if system ~= "Linux" or not target:match("linux%-gnu$") then
    callback()
    return
  end
  run({ "getconf", "GNU_LIBC_VERSION" }, function(error, output)
    local major, minor = (output or ""):match("glibc (%d+)%.(%d+)")
    if
      error
      or not major
      or tonumber(major) < 2
      or tonumber(major) == 2 and tonumber(minor) < 35
    then
      callback("Server installation requires glibc >=2.35")
    else
      callback()
    end
  end)
end

function Server.update_policy(options, native_command)
  local selector = options.update_version
  if selector and (native_command or options.cmd) then
    local source = native_command and "native LSP cmd" or "server.cmd"
    return nil, source .. " conflicts with server.update_version; omit it or set it to false"
  end
  if selector == nil and not (native_command or options.cmd) then
    return "latest"
  end
  return selector or false
end

local function resolve(options, manual, callback)
  local selector, policy_error = Server.update_policy(options)
  if policy_error then
    callback(policy_error)
    return
  end
  local target, system = manifest.platform()
  local key = vim.inspect({ options.cmd, selector, manual })
  local job = jobs[key]
  if job then
    job.waiters[#job.waiters + 1] = callback
    current = job
    return
  end
  job = {
    state = "discovering",
    update_version = selector,
    supported_major = manifest.major,
    waiters = { callback },
  }
  jobs[key] = job
  current = job

  local function finish(error, argv, version, source, published)
    jobs[key] = nil
    job.state = error and "failed" or "ready"
    job.error, job.argv, job.version, job.source = error, argv, version, source
    local waiters = job.waiters
    job.waiters = nil
    if not error and (published or manual) then
      Server.message(("Installed server %s at %s"):format(version, argv[1]))
    elseif not error and job.update_error then
      job.reason = ("Automatic server update failed: %s. Using compatible server %s (%s)."):format(
        job.update_error,
        version,
        source
      )
      Server.message(job.reason, vim.log.levels.WARN)
    end
    for _, waiter in ipairs(waiters) do
      waiter(error, vim.deepcopy(argv), version, source)
    end
  end

  if selector and selector ~= "latest" and not manifest.compatible(selector) then
    finish(
      "Expected latest or a stable version in major "
        .. manifest.major
        .. ", got "
        .. tostring(selector)
    )
    return
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
      finish(error, not error and options.cmd or nil, version, "server.cmd")
    end)
    return
  end

  local function managed(wanted, on_missing, on_invalid)
    local versions
    if wanted and (manual or selector ~= "latest") then
      versions = { wanted }
    else
      versions = installed_versions()
    end
    local last_error
    local function try_version(index)
      local candidate = versions[index]
      if not candidate or wanted and manifest.newer(wanted, candidate) then
        on_missing(last_error)
        return
      end
      local path = managed_path(candidate, target, system)
      if vim.fn.filereadable(path) == 0 then
        try_version(index + 1)
        return
      end
      probe(path, function(error, version)
        if not error and version == candidate then
          finish(nil, { path, "--stdio" }, version, "managed")
          return
        end
        last_error = ("Managed binary %s: %s"):format(
          path,
          error or ("unexpected version " .. tostring(version))
        )
        if candidate == wanted then
          on_invalid(last_error)
        else
          try_version(index + 1)
        end
      end)
    end
    try_version(1)
  end

  local function discover(wanted, on_missing, on_invalid)
    local path = not manual and vim.fn.exepath("venue-reader") or ""
    if path == "" then
      managed(wanted, on_missing, on_invalid)
      return
    end
    probe(path, function(error, version)
      if
        not error
        and (
          not wanted
          or version == wanted
          or selector == "latest" and manifest.newer(version, wanted)
        )
      then
        finish(nil, { path, "--stdio" }, version, "PATH")
      else
        if not job.update_error then
          job.reason = "PATH candidate: "
            .. (error or ("found " .. version .. ", wanted " .. wanted))
        end
        managed(wanted, on_missing, on_invalid)
      end
    end)
  end

  local function acquire(selected, on_error)
    if not selected.artifacts[target] then
      on_error("No release archive for " .. target .. " at v" .. selected.version)
      return
    end
    local directory = vim.fs.dirname(managed_path(selected.version, target, system))
    check_host(target, system, function(host_error)
      if host_error then
        on_error(host_error)
        return
      end
      install(selected, target, system, directory, function(error, argv, version, published)
        if error then
          on_error(error)
        else
          finish(nil, argv, version, "managed", published)
        end
      end, function(state)
        job.state = state
      end)
    end)
  end

  local function unavailable(local_error)
    finish(
      job.update_error
        or local_error
        or "No compatible server; run :VenueReader install server or set server.update_version"
    )
  end

  local function update_failed(error)
    if manual then
      finish(error)
      return
    end
    job.update_error, job.reason = error, error
    discover(nil, unavailable)
  end

  if selector == "latest" then
    manifest.resolve(selector, target, function(error, selected)
      if error then
        update_failed(error)
        return
      end
      job.target_version = selected.version
      discover(selected.version, function()
        acquire(selected, update_failed)
      end, update_failed)
    end, manual)
  elseif selector then
    job.target_version = selector
    discover(selector, function()
      manifest.resolve(selector, target, function(error, selected)
        if error then
          finish(error)
        else
          acquire(selected, finish)
        end
      end)
    end, finish)
  else
    discover(nil, unavailable)
  end
end

function Server.resolve(options, callback)
  resolve(options or {}, false, callback)
end

function Server.install(version, callback)
  if version ~= nil and version ~= "latest" and not manifest.valid_version(version) then
    callback("Expected latest or a stable server version")
    return
  end
  resolve({ update_version = version or "latest" }, true, callback)
end

function Server.status()
  local result = vim.tbl_extend("force", {}, current)
  result.waiters = nil
  return vim.deepcopy(result)
end

return Server

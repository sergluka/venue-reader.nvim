local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local target = assert(arg[1], "Expected the release target as an argument")

local function exercise(profile, mode)
  vim.opt.rtp:prepend(root)
  local plugin = require("venue-reader")
  local manifest = require("venue-reader.release")
  local host, system = manifest.platform()
  assert(host == target, ("Expected %s, got %s"):format(target, host))
  local windows = system == "Windows_NT"
  local artifact = assert(manifest.artifacts[host])
  local install_dir =
    vim.fs.joinpath(vim.fn.stdpath("data"), "venue-reader", manifest.version, host)
  local expected = vim.fs.joinpath(install_dir, windows and "venue-reader.exe" or "venue-reader")
  assert(vim.fn.exepath("venue-reader") == "", "The server must be absent from PATH")
  assert(not vim.uv.fs_stat(install_dir), "Expected an empty managed installation")
  assert(#vim.api.nvim_get_runtime_file("parser/fix.*", true) == 0, "Expected no FIX parser")
  local downloads, release_checks = 0, 0
  local release_list = "https://api.github.com/repos/" .. manifest.repository .. "/releases?"
  local system_command = vim.system
  rawset(vim, "system", function(command, options, callback)
    local executable = vim.fs.basename(command[1]):lower()
    if executable == "curl" or executable == "curl.exe" then
      downloads = downloads + 1
      if vim.startswith(command[#command], release_list) then
        release_checks = release_checks + 1
        local entry = { tag_name = "v" .. manifest.version, draft = false, prerelease = false }
        callback({ code = 0, stdout = vim.json.encode({ entry }) .. "\n200" })
        return
      end
    end
    return system_command(command, options, callback)
  end)
  if mode == "disabled" then
    plugin.setup({ server = { update_version = false } })
  elseif mode == "latest" then
    plugin.setup({ server = { update_version = "latest" } })
  elseif mode == "pinned" then
    plugin.setup({ server = { update_version = manifest.version } })
  else
    plugin.setup()
  end
  local fixture = vim.fs.joinpath(profile, "input.fix")
  vim.fn.writefile({ "8=FIX.4.4|35=0|" }, fixture)
  vim.cmd("filetype on")
  vim.cmd.edit({ args = { fixture } })
  assert(vim.bo.filetype == "fix", "Expected .fix filetype detection")
  if mode == "disabled" then
    assert(
      vim.wait(10000, function()
        return plugin.status().acquisition.state == "failed"
      end, 50),
      vim.inspect(plugin.status())
    )
    local acquisition = plugin.status().acquisition
    assert(acquisition.error:find(":VenueReader install server", 1, true), acquisition.error)
    assert(#vim.lsp.get_clients({ bufnr = 0, name = "venue-reader" }) == 0)
    assert(not vim.uv.fs_stat(install_dir), "Disabled updates installed a managed server")
    assert(downloads == 0, "Disabled updates issued a download")
    print(mode .. ": no download, missing server reported")
    return
  end

  local client
  assert(vim.wait(120000, function()
    client = vim.lsp.get_clients({ bufnr = 0, name = "venue-reader" })[1]
    return client and client.initialized or plugin.status().acquisition.state == "failed"
  end, 50) and client and client.initialized, vim.inspect(plugin.status()))
  assert(
    release_checks == (mode == "pinned" and 0 or 1),
    "Unexpected release checks: " .. release_checks
  )
  local path = vim.fs.normalize(assert(client.config.venue_reader_argv)[1])
  assert(path == vim.fs.normalize(expected), "Unexpected managed binary: " .. path)
  assert(client.server_info.version == manifest.version, vim.inspect(client.server_info))
  local version = vim.system({ path, "--version" }):wait(5000)
  assert(version.code == 0 and vim.trim(version.stdout) == "venue-reader " .. manifest.version)

  local verified = dofile(root .. "/scripts/dependencies.lua").verify()
  local function digest(binary)
    local file = assert(io.open(binary, "rb"))
    local bytes = file:read("*a")
    file:close()
    return vim.fn.sha256(bytes)
  end
  local binary_sha256 = digest(path)
  assert(
    binary_sha256 == digest(verified),
    "Installed executable differs from the verified release"
  )
  local tools = {}
  for _, name in ipairs({
    windows and "curl.exe" or "curl",
    windows and "tar.exe" or "tar",
    windows and "certutil.exe" or system == "Darwin" and "shasum" or "sha256sum",
  }) do
    tools[name] = vim.fn.exepath(name)
    assert(tools[name] ~= "", "Missing " .. name)
  end

  local evidence = vim.json.encode({
    mode = mode,
    release_checks = release_checks,
    target = target,
    archive = artifact.archive,
    archive_sha256 = artifact.sha256,
    binary = path,
    binary_sha256 = binary_sha256,
    server = client.server_info,
    client = client.name,
    tools = tools,
  })
  print(evidence)
  local output = vim.env.VENUE_READER_TEST_OUTPUT
  if output and output ~= "" then
    vim.fn.mkdir(output, "p")
    vim.fn.writefile(
      { evidence },
      vim.fs.joinpath(
        output,
        mode == "pinned" and "fresh-install.json" or "fresh-install-" .. mode .. ".json"
      )
    )
  end
  client:stop(true)
  assert(
    vim.wait(5000, function()
      return vim.lsp.get_client_by_id(client.id) == nil
    end),
    "Server failed to stop"
  )
end

local function run_profile(mode)
  assert(
    vim.tbl_contains({ "default", "disabled", "latest", "pinned" }, mode),
    "Expected default, disabled, latest or pinned"
  )
  local profile = vim.fn.tempname()
  vim.fn.mkdir(profile, "p")
  local environment = { NVIM_APPNAME = "venue-reader-ci", LOCALAPPDATA = profile }
  for _, kind in ipairs({ "CONFIG", "DATA", "STATE", "CACHE" }) do
    environment["XDG_" .. kind .. "_HOME"] = vim.fs.joinpath(profile, kind:lower())
  end
  local result = vim
    .system({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-i",
      "NONE",
      "-l",
      root .. "/scripts/ci-install.lua",
      target,
      mode,
      profile,
    }, { env = environment })
    :wait(150000)
  vim.fn.delete(profile, "rf")
  io.stdout:write(result.stdout or "")
  io.stderr:write(result.stderr or "")
  assert(result.code == 0, "Fresh profile failed: " .. mode)
end

if arg[3] then
  exercise(arg[3], arg[2])
elseif arg[2] then
  run_profile(arg[2])
else
  run_profile("default")
  run_profile("disabled")
  run_profile("latest")
  run_profile("pinned")
end

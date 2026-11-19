local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local target = assert(arg[1], "Expected the release target as an argument")

local function exercise(profile)
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
  local tools = {}
  for _, name in ipairs({
    windows and "curl.exe" or "curl",
    windows and "tar.exe" or "tar",
    windows and "certutil.exe" or system == "Darwin" and "shasum" or "sha256sum",
  }) do
    tools[name] = vim.fn.exepath(name)
    assert(tools[name] ~= "", "Missing " .. name)
  end

  plugin.setup()
  local fixture = vim.fs.joinpath(profile, "input.fix")
  vim.fn.writefile({ "8=FIX.4.4|35=0|" }, fixture)
  vim.cmd("filetype on")
  vim.cmd.edit({ args = { fixture } })
  assert(vim.bo.filetype == "fix", "Expected .fix filetype detection")
  local client
  assert(vim.wait(120000, function()
    client = vim.lsp.get_clients({ bufnr = 0, name = "venue_reader" })[1]
    return client and client.initialized or plugin.status().acquisition.state == "failed"
  end, 50) and client and client.initialized, vim.inspect(plugin.status()))
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
  local evidence = vim.json.encode({
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
    vim.fn.writefile({ evidence }, vim.fs.joinpath(output, "fresh-install.json"))
  end
  client:stop(true)
  assert(
    vim.wait(5000, function()
      return vim.lsp.get_client_by_id(client.id) == nil
    end),
    "Server failed to stop"
  )
end

if arg[2] then
  exercise(arg[2])
else
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
      profile,
    }, { env = environment })
    :wait(150000)
  vim.fn.delete(profile, "rf")
  io.stdout:write(result.stdout or "")
  io.stderr:write(result.stderr or "")
  assert(result.code == 0, "Fresh installation failed")
end

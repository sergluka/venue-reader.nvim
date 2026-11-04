local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local function child(size, binary, output)
  vim.opt.runtimepath:prepend(root)
  local requests, events, samples = {}, {}, {}
  local phase = "startup"
  local last_activity = vim.uv.hrtime()
  vim.lsp.log.set_format_func(function(level, event, payload)
    if event == "rpc.send" and type(payload) == "table" and payload.id and payload.method then
      local params = payload.params or {}
      requests[#requests + 1] = {
        phase = phase,
        method = payload.method,
        range = params.range,
        command = params.command,
        owner = params.command == "fix.describeOverrides" and "adapter" or "native",
      }
      last_activity = vim.uv.hrtime()
    end
    if level == "ERROR" or level == "WARN" then
      local message = type(payload) == "string" and payload
        or type(payload) == "table" and payload.message
        or ""
      return ("[%s] %s %s\n"):format(level, tostring(event), tostring(message):sub(1, 2048))
    end
  end)
  vim.api.nvim_create_autocmd("LspRequest", {
    callback = function(event)
      local request = event.data.request
      local key = request.method .. ":" .. request.type
      events[key] = (events[key] or 0) + 1
    end,
  })
  local plugin = require("venue-reader")
  plugin.setup({
    server = { cmd = { binary, "--stdio" } },
    treesitter = {
      enabled = function()
        return false
      end,
    },
  })
  local ready = {}
  local config = vim.lsp.config.venue_reader
  -- luacheck: push ignore 122
  config.handlers["textDocument/publishDiagnostics"] = function(err, result, context)
    if not err and result then
      ready[result.uri] = true
    end
    return vim.lsp.handlers["textDocument/publishDiagnostics"](err, result, context)
  end
  -- luacheck: pop
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_buf_set_name(buffer, output .. "/synthetic-" .. size .. ".fix")
  local lines = {}
  for index = 1, size do
    lines[index] = "8=FIX.4.4|35=0|"
  end
  lines[2] = "# Synthetic Unicode comment: λ界"
  lines[3] = "8=FIX.4.4|35=0|58=" .. string.rep("long-value", 300) .. "|"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  lines = nil -- luacheck: ignore 311
  vim.api.nvim_set_option_value("filetype", "fix", { buf = buffer })
  local active

  local function wait_for(predicate, description)
    assert(vim.wait(20000, predicate, 10), "Timed out: " .. description)
  end

  wait_for(function()
    active = vim.lsp.get_clients({ name = "venue_reader", bufnr = buffer })[1]
    return active
      and active.initialized
      and ready[vim.uri_from_bufnr(buffer)]
      and plugin.status(buffer).annotations.effective ~= nil
  end, "native attachment and effective configuration")

  local function settled()
    vim.cmd("redraw!")
    wait_for(function()
      return next(active.requests) == nil and (vim.uv.hrtime() - last_activity) > 400000000
    end, "request quiet period")
  end

  local namespace = vim.api.nvim_create_namespace("venue-reader.summary")
  local function sample(name)
    collectgarbage("collect")
    local state = plugin.status(buffer)
    samples[#samples + 1] = {
      phase = name,
      lua_kib = collectgarbage("count"),
      buffers = #vim.api.nvim_list_bufs(),
      summary_marks = #vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, {}),
      requests = #requests,
      annotations = {
        mode = state.annotations.mode,
        problem = state.annotations.problem,
        lines = state.annotations.lines,
        native_enabled = state.annotations.native_enabled,
      },
      treesitter = {
        state = state.treesitter.state,
        eligible = state.treesitter.eligible,
        highlighted = state.treesitter.highlighted,
      },
    }
  end

  settled()
  local initial = plugin.status(buffer)
  assert(initial.annotations.problem:find("limits.rangeLines", 1, true), "Cap must be reported")
  assert(not initial.treesitter.eligible and not initial.treesitter.highlighted)
  assert(
    initial.treesitter.state == "unchecked",
    "Excluded log must not attempt grammar acquisition"
  )
  sample("warmup")
  local main_window = vim.api.nvim_get_current_win()
  for cycle = 1, 3 do
    phase = "cycle-" .. cycle
    vim.cmd("vsplit")
    local split_window = vim.api.nvim_get_current_win()
    for _, target in ipairs({ 1, math.floor(size / 4), math.floor(size / 2), size, 1 }) do
      vim.api.nvim_win_set_cursor(split_window, { target, 0 })
      vim.cmd("normal! zt")
      vim.api.nvim_win_set_cursor(main_window, { math.min(size, target + 20), 0 })
      vim.cmd("redraw!")
    end
    vim.api.nvim_win_close(split_window, true)
    vim.api.nvim_set_current_win(main_window)
    settled()
    phase = "hidden-" .. cycle
    local empty = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(main_window, empty)
    settled()
    local hidden_start = #requests
    vim.wait(750, function()
      return false
    end, 10)
    local hidden_requests = {}
    for index = hidden_start + 1, #requests do
      hidden_requests[#hidden_requests + 1] = requests[index]
      assert(requests[index].owner ~= "adapter", "Adapter sent recurring hidden-view requests")
    end
    sample(phase)
    samples[#samples].hidden_observation_ms = 750
    samples[#samples].hidden_requests = hidden_requests
    phase = "reopen-" .. cycle
    vim.api.nvim_win_set_buf(main_window, buffer)
    vim.api.nvim_buf_delete(empty, { force = true })
    settled()
    sample(phase)
  end
  phase = "edit"
  ready[vim.uri_from_bufnr(buffer)] = nil
  vim.api.nvim_buf_set_lines(buffer, 0, 1, false, { "8=FIX.4.4|35=1|112=SYNTHETIC|" })
  wait_for(function()
    return ready[vim.uri_from_bufnr(buffer)]
  end, "edited diagnostics")
  settled()
  sample(phase)
  for _, request in ipairs(requests) do
    if request.method == "workspace/executeCommand" then
      assert(request.command == "fix.describeOverrides", "Unexpected adapter recovery command")
    end
  end
  phase = "detach"
  vim.api.nvim_buf_delete(buffer, { force = true })
  settled()
  collectgarbage("collect")
  local final_buffers = #vim.api.nvim_list_bufs()
  local evidence = {
    size = size,
    nvim = vim.version(),
    server = active.server_info,
    requests = requests,
    request_events = events,
    samples = samples,
    final = { lua_kib = collectgarbage("count"), buffers = final_buffers },
    limits = initial.annotations.effective,
    observations = {
      "Read-only native events/log formatting recorded metadata, not production callsite proof.",
      "Native ranges are observations; changes in native scheduling are not adapter failures.",
      "Persistent marks are zero above the cap; ephemeral rendering is checked separately.",
      "Lua figures include observer/native state; editor RSS and server memory are not measured.",
      "No fixed memory budget is asserted; inspect repeated-cycle samples for continued growth.",
    },
  }
  vim.fn.writefile({ vim.json.encode(evidence) }, output .. "/stress-" .. size .. ".json")
  active:stop(true)
  wait_for(function()
    return vim.lsp.get_client_by_id(active.id) == nil
  end, "server shutdown")
  print("PASS: synthetic log " .. size .. " lines")
end

local function run()
  if arg[1] == "--child" then
    child(assert(tonumber(arg[2])), assert(arg[3]), assert(arg[4]))
    return
  end
  local output = vim.fn.fnamemodify(
    arg[1] or vim.env.VENUE_READER_ACCEPTANCE_OUTPUT or root .. "/.test-deps/stress",
    ":p"
  )
  vim.fn.mkdir(output, "p")
  local binary = dofile(root .. "/scripts/dependencies.lua").verify()
  for _, size in ipairs({ 10000, 100000 }) do
    local environment = vim.fn.environ()
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
      environment[name] = output .. "/isolated-" .. size .. "/" .. name
      vim.fn.mkdir(environment[name], "p")
    end
    environment.NVIM_LOG_FILE = output .. "/isolated-" .. size .. "/nvim.log"
    print("Large-log acceptance: " .. size)
    local result = vim
      .system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-i",
        "NONE",
        "-l",
        root .. "/scripts/stress.lua",
        "--child",
        tostring(size),
        binary,
        output,
      }, { env = environment, clear_env = true, cwd = output })
      :wait(120000)
    io.stdout:write(result.stdout or "")
    io.stderr:write(result.stderr or "")
    assert(result.code == 0, "Large-log child failed; inspect " .. output)
  end
end

local success, failure = pcall(run)
if not success then
  io.stderr:write(tostring(failure) .. "\n")
  vim.cmd("cquit 1")
end

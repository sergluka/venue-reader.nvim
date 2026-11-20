local M = {}

local Server = require("venue-reader.server")
local Operation = {}
Operation.__index = Operation

local acquire
local managed
local timeout_ms = 5000
local epoch = 0
local active = {}
local bootstrap = {}
local native_configuration = vim.lsp.handlers["workspace/configuration"]

local function notify(message)
  vim.notify("venue-reader: " .. message, vim.log.levels.ERROR)
end

local function failure(message)
  return { message = message }
end

local function error_text(err)
  return type(err) == "table" and err.message or tostring(err)
end

function Operation:valid()
  if self.done or self.epoch ~= epoch or (self.guard and not self.guard()) then
    return false
  end
  local client = self.client
  if client then
    if
      vim.lsp.get_client_by_id(client.id) ~= client
      or client:is_stopped()
      or not managed(client)
      or client.config.root_dir ~= self.root
      or not vim.deep_equal(client.settings, self.settings)
    then
      return false
    end
  end
  if self.document then
    return vim.api.nvim_buf_is_valid(self.buffer)
      and vim.api.nvim_buf_get_changedtick(self.buffer) == self.changedtick
      and vim.uri_from_bufnr(self.buffer) == self.uri
      and (not client or vim.lsp.buf_is_attached(self.buffer, client.id))
  end
  return true
end

function Operation:finish()
  if self.done then
    return
  end
  self.done = true
  active[self] = nil
  if self.client and bootstrap[self.client.id] then
    bootstrap[self.client.id].waiting[self] = nil
  end
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

function Operation:cancel()
  if self.request_id and self.client then
    self.client:cancel_request(self.request_id)
    self.request_id = nil
  end
  self:finish()
end

function Operation:request(command, arguments, callback)
  if not self:valid() then
    self:cancel()
    return false
  end
  local commands = (self.client.server_capabilities.executeCommandProvider or {}).commands or {}
  if not vim.list_contains(commands, command) then
    callback(failure("server does not advertise " .. command), nil, {})
    return false
  end
  local accepted, request_id = self.client:request("workspace/executeCommand", {
    command = command,
    arguments = arguments,
  }, function(err, result, context)
    self.request_id = nil
    if not self:valid() then
      self:cancel()
      return
    end
    callback(err, result, context)
  end, self.document and self.buffer or nil)
  self.request_id = accepted and request_id or nil
  if not accepted then
    callback(failure("server rejected " .. command .. " request"), nil, {})
  end
  return accepted, request_id
end

local function ready(operation, callback)
  if not operation:valid() then
    operation:cancel()
    return
  end
  local client = operation.client
  if not client.initialized then
    return
  end
  if not vim.deep_equal(client.config.venue_reader_initial_settings, client.settings) then
    operation:cancel()
    notify("initial server settings changed; invoke the command again")
    return
  end
  callback(operation)
end

local function attach(operation, err, client, callback, guard)
  if operation.done or operation.epoch ~= epoch then
    return
  end
  if err then
    operation:finish()
    Server.message(error_text(err), vim.log.levels.ERROR)
    return
  end
  if not client then
    operation:finish()
    notify("no Venue Reader client")
    return
  end
  if operation.document and not client.initialized then
    operation:finish()
    notify("Venue Reader attachment is pending")
    return
  end
  operation.guard = guard
  operation.client = client
  operation.root = client.config.root_dir
  operation.settings = vim.deepcopy(client.settings)
  if not operation:valid() then
    operation:cancel()
    return
  end
  local state = bootstrap[client.id]
  if not state then
    state = { waiting = {} }
    bootstrap[client.id] = state
  end
  if state.ready then
    callback(operation)
  else
    state.waiting[operation] = callback
  end
end

local function operation(buffer, document, callback, client, guard)
  local result = setmetatable({ buffer = buffer, document = document, epoch = epoch }, Operation)
  if document then
    result.uri = vim.uri_from_bufnr(buffer)
    result.changedtick = vim.api.nvim_buf_get_changedtick(buffer)
  end
  active[result] = true
  result.timer = assert(vim.uv.new_timer())
  result.timer:start(
    timeout_ms,
    0,
    vim.schedule_wrap(function()
      if result.done then
        return
      end
      local current = result:valid()
      result:cancel()
      if current then
        notify("command timed out")
      end
    end)
  )
  if client then
    attach(result, nil, client, callback, guard)
  else
    acquire(buffer, document, function(err, selected, selected_guard)
      attach(result, err, selected, callback, selected_guard)
    end, function()
      return not result.done and result.epoch == epoch
    end)
  end
  return result
end

function M.operation(buffer, document, callback)
  return operation(buffer, document, callback)
end

function M.before_init(params, config)
  config.venue_reader_initial_settings = vim.deepcopy(config.settings)
  params.initializationOptions = vim.tbl_extend(
    "force",
    vim.deepcopy(params.initializationOptions or {}),
    { fix = vim.deepcopy(config.settings.fix or vim.empty_dict()) }
  )
end

function M.configuration(err, params, context, config)
  local result, response_error = native_configuration(err, params, context, config)
  local client = vim.lsp.get_client_by_id(context.client_id)
  if client and managed and managed(client) and not response_error then
    local global = false
    for _, item in ipairs(params.items or {}) do
      if item.section == "fix" and item.scopeUri == nil then
        global = true
      end
    end
    if global then
      local state = bootstrap[client.id]
      if not state then
        state = { waiting = {} }
        bootstrap[client.id] = state
      end
      if not state.ready and not state.scheduled then
        state.scheduled = true
        vim.schedule(function()
          if bootstrap[client.id] ~= state or client:is_stopped() then
            return
          end
          state.ready = true
          local waiting = state.waiting
          state.waiting = {}
          for pending, callback in pairs(waiting) do
            ready(pending, callback)
          end
        end)
      end
    end
  end
  return result, response_error
end

function M.closed(client_id)
  bootstrap[client_id] = nil
  for pending in pairs(active) do
    if pending.client and pending.client.id == client_id then
      pending:cancel()
    end
  end
end

function M.setup(options, acquire_client, owned)
  for pending in pairs(active) do
    pending:cancel()
  end
  epoch = epoch + 1
  timeout_ms = options.timeout_ms
  acquire = acquire_client
  managed = owned
  local group = vim.api.nvim_create_augroup("venue-reader-commands", { clear = true })
  vim.api.nvim_create_autocmd({ "LspDetach", "BufWipeout", "BufFilePre" }, {
    group = group,
    callback = function(event)
      for pending in pairs(active) do
        if
          pending.document
          and pending.buffer == event.buf
          and (
            event.event ~= "LspDetach"
            or not pending.client
            or pending.client.id == event.data.client_id
          )
        then
          pending:cancel()
        end
      end
    end,
  })
end

local function response(operation_value, err)
  if err then
    operation_value:finish()
    notify(error_text(err))
    return false
  end
  return true
end

local function preview(lines, filetype)
  vim.lsp.util.open_floating_preview(lines, filetype, { border = "rounded" })
end

function M.tag(number, value)
  local decimal = type(number) == "number" and tostring(number) or number
  if type(decimal) ~= "string" or not decimal:match("^%d+$") then
    notify("tag must be a positive decimal u32 integer")
    return
  end
  local tag = tonumber(decimal)
  if tag < 1 or tag > 4294967295 or (value ~= nil and type(value) ~= "string") then
    notify("tag must be a positive decimal u32 integer and value must be a string")
    return
  end
  M.operation(vim.api.nvim_get_current_buf(), false, function(pending)
    local arguments = { tag }
    if value ~= nil then
      arguments[2] = value
    end
    pending:request("fix.describeTag", arguments, function(err, result)
      if not response(pending, err) then
        return
      end
      pending:finish()
      if type(result) ~= "string" then
        notify("unsupported fix.describeTag result: expected Markdown text")
        return
      end
      preview(vim.split(result, "\n", { plain = true }), "markdown")
    end)
  end)
end

function M.settings()
  local buffer = vim.api.nvim_get_current_buf()
  M.operation(buffer, true, function(pending)
    pending:request("fix.describeOverrides", { pending.uri }, function(err, result)
      if not response(pending, err) then
        return
      end
      pending:finish()
      if type(result) ~= "table" or type(result.effective) ~= "table" then
        notify("unsupported fix.describeOverrides result: expected committed settings")
        return
      end
      preview(vim.split(vim.inspect(result), "\n", { plain = true }), "lua")
    end)
  end)
end

local function use_dictionary(pending, name)
  pending:request("fix.useDictionary", { name }, function(err, result)
    if not response(pending, err) then
      return
    end
    pending:finish()
    if type(result) ~= "table" or type(result.name) ~= "string" then
      notify("unsupported fix.useDictionary result: expected selected dictionary")
      return
    end
    vim.notify(
      "venue-reader: session dictionary "
        .. result.name
        .. "; project and modeline overrides take precedence"
    )
  end)
end

local function choose_dictionary(captured, name)
  local client = captured.client
  if
    captured.epoch ~= epoch
    or vim.lsp.get_client_by_id(client.id) ~= client
    or client:is_stopped()
    or not managed(client)
    or not vim.deep_equal(captured.settings, client.settings)
    or client.config.root_dir ~= captured.root
    or (captured.guard and not captured.guard())
  then
    return
  end
  operation(captured.buffer, false, function(pending)
    use_dictionary(pending, name)
  end, client, captured.guard)
end

function M.dictionary(name)
  if name ~= nil and (type(name) ~= "string" or name == "") then
    notify("dictionary name must be a non-empty string")
    return
  end
  M.operation(vim.api.nvim_get_current_buf(), false, function(pending)
    if name then
      use_dictionary(pending, name)
      return
    end
    pending:request("fix.listDictionaries", {}, function(err, result)
      if not response(pending, err) then
        return
      end
      pending:finish()
      if type(result) ~= "table" or not vim.islist(result.dictionaries) then
        notify("unsupported fix.listDictionaries result: expected dictionary choices")
        return
      end
      for _, item in ipairs(result.dictionaries) do
        if type(item) ~= "table" or type(item.name) ~= "string" or type(item.label) ~= "string" then
          notify("unsupported fix.listDictionaries result: expected dictionary names and labels")
          return
        end
      end
      vim.ui.select(result.dictionaries, {
        prompt = "Venue Reader session dictionary",
        format_item = function(item)
          return item.label
        end,
      }, function(selected)
        if selected then
          choose_dictionary(pending, selected.name)
        end
      end)
    end)
  end)
end

return M

local Transport = {}
Transport.__index = Transport

function Transport.new()
  local self = setmetatable(
    { events = {}, notifications = {}, pending = {}, next_id = 0, closing = false },
    Transport
  )
  self.command = function(dispatchers)
    self.dispatchers = dispatchers
    return {
      request = function(method, params, callback, completed)
        if self.closing then
          return false
        end
        table.insert(self.events, method)
        self.next_id = self.next_id + 1
        local request_id = self.next_id
        local request = {
          id = request_id,
          method = method,
          params = params,
          callback = callback,
          completed = completed,
        }
        self.pending[request_id] = request
        return true, request_id
      end,
      notify = function(method, params)
        if self.closing then
          return false
        end
        table.insert(self.events, method)
        table.insert(self.notifications, { method = method, params = params })
        if method == "exit" then
          self:exit(0, 0)
        end
        return true
      end,
      is_closing = function()
        return self.closing
      end,
      terminate = function()
        self:exit(0, 15)
      end,
    }
  end
  return self
end

function Transport:reply(request_id, result, response_error)
  local request = assert(self.pending[request_id], "No pending request " .. request_id)
  self.pending[request_id] = nil
  vim.schedule(function()
    if self.closing then
      return
    end
    if request.completed then
      request.completed(request_id)
    end
    request.callback(response_error, result, request_id)
  end)
end

function Transport:initialize()
  local request = assert(self.pending[1])
  assert(request.method == "initialize")
  self:reply(request.id, {
    capabilities = { textDocumentSync = { openClose = true, change = 1 }, hoverProvider = true },
    serverInfo = { name = "controlled-test-server", version = "1" },
  })
end

function Transport:notification(method)
  for _, notification in ipairs(self.notifications) do
    if notification.method == method then
      return notification.params
    end
  end
end

function Transport:exit(code, signal)
  if self.closing then
    return
  end
  self.closing = true
  self.pending = {}
  vim.schedule(function()
    self.dispatchers.on_exit(code, signal)
  end)
end

return Transport

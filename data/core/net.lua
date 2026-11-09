local core = require "core"
local native = require "net"

local net = {}

-- Keyed by client id, which is what net events carry.
local clients = setmetatable({}, { __mode = "v" })

local Client = {}
Client.__index = Client

-- Options as for `native.client`:
--  - max_connections
--  - timeout
--  - user_agent.
function net.client(options)
  local handle = native.client(options)
  local client = setmetatable({ handle = handle, waiting = {} }, Client)
  clients[handle:get_id()] = client
  return client
end

-- Send a request. Yields till the response arrives.
-- TODO: cancel the request if the waiting thread is abandoned.
function Client:request(options)
  local thread = core.current_thread()
  assert(thread, "net requests must be made from a core thread")
  local id = self.handle:request(options)
  local slot = { thread = thread }
  self.waiting[id] = slot
  while not slot.response do
    coroutine.yield(math.huge)
  end
  local response = slot.response
  if response.error then
    return nil, response.error
  end
  return response
end

function Client:close()
  self.handle:close()
  for id, slot in pairs(self.waiting) do
    slot.response = { id = id, status = 0, error = "client closed" }
    core.wake(slot.thread)
  end
  self.waiting = {}
end

local default_client

-- Like `Client:request`, on the deault client
function net.request(options)
  default_client = default_client or net.client()
  return default_client:request(options)
end

function net.on_event(client_id)
  local client = clients[client_id]
  if not client then return end
  for response in function() return client.handle:poll() end do
    local slot = client.waiting[response.id]
    if slot then
      client.waiting[response.id] = nil
      slot.response = response
      core.wake(slot.thread)
    end
  end
end

return net

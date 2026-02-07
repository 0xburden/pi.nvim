local M = {}

-- Event listeners: { event_name = { listener_id = callback } }
M.listeners = {}
M.next_id = 1

-- Subscribe to an event
function M.on(event, callback)
  if not M.listeners[event] then
    M.listeners[event] = {}
  end
  
  local id = M.next_id
  M.next_id = M.next_id + 1
  
  M.listeners[event][id] = callback
  
  -- Return unsubscribe function
  return function()
    if M.listeners[event] then
      M.listeners[event][id] = nil
    end
  end
end

-- Emit an event
function M.emit(event, ...)
  if not M.listeners[event] then return end
  
  for _, callback in pairs(M.listeners[event]) do
    local ok, err = pcall(callback, ...)
    if not ok then
      vim.notify("Pi event handler error: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

-- Clear all listeners
function M.clear()
  M.listeners = {}
end

return M
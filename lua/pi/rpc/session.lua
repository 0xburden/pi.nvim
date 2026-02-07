local M = {}

-- List available sessions
function M.list(client, callback)
  client:request("session.list", {}, function(result)
    if result and not result.error then
      local state = require("pi.state")
      state.update("sessions.available", result.sessions or {})
    end
    
    if callback then callback(result) end
  end)
end

-- Load a session
function M.load(client, session_id, callback)
  client:request("session.load", { id = session_id }, function(result)
    if result and not result.error then
      local state = require("pi.state")
      state.update("sessions.current", result.session)
      
      local events = require("pi.events")
      events.emit("session_changed", result.session)
    end
    
    if callback then callback(result) end
  end)
end

-- Save current session
function M.save(client, name, callback)
  client:request("session.save", { name = name }, function(result)
    if result and not result.error then
      local events = require("pi.events")
      events.emit("session_changed", result.session)
    end
    
    if callback then callback(result) end
  end)
end

-- Delete a session
function M.delete(client, session_id, callback)
  client:request("session.delete", { id = session_id }, callback)
end

-- Get current session
function M.current(client, callback)
  client:request("session.current", {}, function(result)
    if result and not result.error then
      local state = require("pi.state")
      state.update("sessions.current", result.session)
    end
    
    if callback then callback(result) end
  end)
end

return M
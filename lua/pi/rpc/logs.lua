local M = {}

-- Start streaming logs
function M.stream(client, callback)
  client:request("logs.stream", {}, function(result)
    if result and not result.error then
      local state = require("pi.state")
      state.update("logs.stream_active", true)
    end
    
    if callback then callback(result) end
  end)
  
  -- Listen for log events from RPC
  local events = require("pi.events")
  return events.on("rpc_event", function(event)
    if event.method == "logs.entry" then
      -- Add log entry to state
      local state = require("pi.state")
      local entries = state.get("logs.entries")
      table.insert(entries, event.params)
      state.update("logs.entries", entries)
      
      -- Emit log event for UI
      events.emit("log_entry", event.params)
    end
  end)
end

-- Stop streaming logs
function M.stop(client, unsubscribe, callback)
  if unsubscribe then
    unsubscribe()  -- Remove event listener
  end
  
  client:request("logs.stop", {}, function(result)
    if result and not result.error then
      local state = require("pi.state")
      state.update("logs.stream_active", false)
    end
    
    if callback then callback(result) end
  end)
end

-- Get historical logs
function M.history(client, limit, callback)
  client:request("logs.history", { limit = limit or 100 }, callback)
end

return M
local M = {}

-- Start agent with a task
function M.start(client, task, callback)
  client:request("agent.start", { task = task }, function(result)
    if result and not result.error then
      local state = require("pi.state")
      state.update("agent.running", true)
      state.update("agent.current_task", task)
      state.update("agent.session_id", result.sessionId)
      
      local events = require("pi.events")
      events.emit("agent_started", result)
    end
    
    if callback then callback(result) end
  end)
end

-- Pause agent
function M.pause(client, callback)
  client:request("agent.pause", {}, function(result)
    if result and not result.error then
      local state = require("pi.state")
      state.update("agent.paused", true)
      
      local events = require("pi.events")
      events.emit("agent_paused")
    end
    
    if callback then callback(result) end
  end)
end

-- Resume agent
function M.resume(client, callback)
  client:request("agent.resume", {}, function(result)
    if result and not result.error then
      local state = require("pi.state")
      state.update("agent.paused", false)
      
      local events = require("pi.events")
      events.emit("agent_resumed")
    end
    
    if callback then callback(result) end
  end)
end

-- Stop agent
function M.stop(client, callback)
  client:request("agent.stop", {}, function(result)
    if result and not result.error then
      local state = require("pi.state")
      state.update("agent.running", false)
      state.update("agent.paused", false)
      state.update("agent.current_task", nil)
      
      local events = require("pi.events")
      events.emit("agent_stopped")
    end
    
    if callback then callback(result) end
  end)
end

-- Get agent status
function M.status(client, callback)
  client:request("agent.status", {}, callback)
end

return M
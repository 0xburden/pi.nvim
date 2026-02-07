local M = {}

function M.start(client, task, callback)
  client:request("prompt", { type = "prompt", message = task }, function(result)
    vim.schedule(function()
      if result and not result.error then
        local state = require("pi.state")
        state.update("agent.running", true)
        state.update("agent.current_task", task)

        local events = require("pi.events")
        events.emit("agent_started", result)
      end
      if callback then callback(result) end
    end)
  end)
end

function M.pause(client, callback)
  client:request("pause", { type = "pause" }, function(result)
    vim.schedule(function()
      if result and not result.error then
        local state = require("pi.state")
        state.update("agent.paused", true)

        local events = require("pi.events")
        events.emit("agent_paused")
      end
      if callback then callback(result) end
    end)
  end)
end

function M.resume(client, callback)
  client:request("resume", { type = "resume" }, function(result)
    vim.schedule(function()
      if result and not result.error then
        local state = require("pi.state")
        state.update("agent.paused", false)

        local events = require("pi.events")
        events.emit("agent_resumed")
      end
      if callback then callback(result) end
    end)
  end)
end

function M.stop(client, callback)
  client:request("abort", { type = "abort" }, function(result)
    vim.schedule(function()
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
  end)
end

function M.status(client, callback)
  client:request("get_state", { type = "get_state" }, function(result)
    vim.schedule(function()
      if callback then callback(result) end
    end)
  end)
end

return M

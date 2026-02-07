local M = {}

function M.list(client, callback)
  client:request("get_state", { type = "get_state" }, function(result)
    vim.schedule(function()
      if result and result.success and result.data then
        local sessions = {}
        if result.data.sessionFile then
          table.insert(sessions, {
            id = result.data.sessionId or "current",
            name = result.data.sessionName or "Current Session",
            file = result.data.sessionFile,
          })
        end
        require("pi.state").update("sessions.available", sessions)
      end
      if callback then callback({ sessions = require("pi.state").get("sessions.available") }) end
    end)
  end)
end

function M.current(client, callback)
  client:request("get_state", { type = "get_state" }, function(result)
    vim.schedule(function()
      if result and result.success then
        require("pi.state").update("sessions.current", result.data)
      end
      if callback then callback(result) end
    end)
  end)
end

function M.new(client, opts, callback)
  opts = opts or {}
  local params = { type = "new_session" }
  if opts.parentSession then
    params.parentSession = opts.parentSession
  end
  client:request("new_session", params, function(result)
    vim.schedule(function()
      if result and result.success then
        local events = require("pi.events")
        events.emit("session_changed", result.data)
      end
      if callback then callback(result) end
    end)
  end)
end

return M

local M = {}

local state = require("pi.state")
local events = require("pi.events")

--- Get current session info from state
-- @param client RPC client
-- @param callback function Called with result
function M.current(client, callback)
  client:request("get_state", { type = "get_state" }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("sessions.current", result.data)
      end
      if callback then callback(result) end
    end)
  end)
end

--- Start a new session
-- Can be cancelled by a session_before_switch extension event handler
-- @param client RPC client
-- @param opts table|nil { parentSession = "/path/to/parent.jsonl" }
-- @param callback function|nil Called with result { cancelled = bool }
function M.new(client, opts, callback)
  opts = opts or {}
  local params = { type = "new_session" }
  if opts.parentSession then
    params.parentSession = opts.parentSession
  end
  client:request("new_session", params, function(result)
    vim.schedule(function()
      if result and result.success and not (result.data and result.data.cancelled) then
        events.emit("session_changed", result.data)
        -- Clear conversation state for new session
        state.update("conversation.messages", {})
        state.update("conversation.last_assistant_text", nil)
      end
      if callback then callback(result) end
    end)
  end)
end

--- Get session statistics (token usage, cost, message counts)
-- @param client RPC client
-- @param callback function Called with result containing stats
function M.get_stats(client, callback)
  client:request("get_session_stats", { type = "get_session_stats" }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("sessions.stats", result.data)
      end
      if callback then callback(result) end
    end)
  end)
end

--- Export session to HTML file
-- @param client RPC client
-- @param opts table|nil { outputPath = "/path/to/output.html" }
-- @param callback function|nil Called with result { path = "..." }
function M.export_html(client, opts, callback)
  opts = opts or {}
  local params = { type = "export_html" }
  if opts.outputPath then
    params.outputPath = opts.outputPath
  end
  client:request("export_html", params, function(result)
    vim.schedule(function()
      if callback then callback(result) end
    end)
  end)
end

--- Switch to a different session file
-- Can be cancelled by a session_before_switch extension event handler
-- @param client RPC client
-- @param sessionPath string Path to session.jsonl file
-- @param callback function|nil Called with result { cancelled = bool }
function M.switch(client, sessionPath, callback)
  client:request("switch_session", {
    type = "switch_session",
    sessionPath = sessionPath,
  }, function(result)
    vim.schedule(function()
      if result and result.success and not (result.data and result.data.cancelled) then
        events.emit("session_switched", { path = sessionPath })
        -- Clear conversation state - will be reloaded
        state.update("conversation.messages", {})
        state.update("conversation.last_assistant_text", nil)
      end
      if callback then callback(result) end
    end)
  end)
end

--- Create a fork from a previous user message
-- Can be cancelled by a session_before_fork extension event handler
-- @param client RPC client
-- @param entryId string The entry ID to fork from
-- @param callback function|nil Called with result { text = "...", cancelled = bool }
function M.fork(client, entryId, callback)
  client:request("fork", {
    type = "fork",
    entryId = entryId,
  }, function(result)
    vim.schedule(function()
      if result and result.success and not (result.data and result.data.cancelled) then
        events.emit("session_forked", {
          entryId = entryId,
          text = result.data and result.data.text,
        })
        -- Clear conversation state - forked session starts fresh from that point
        state.update("conversation.messages", {})
      end
      if callback then callback(result) end
    end)
  end)
end

--- Get user messages available for forking
-- @param client RPC client
-- @param callback function Called with result { messages = [ { entryId, text }, ... ] }
function M.get_fork_messages(client, callback)
  client:request("get_fork_messages", { type = "get_fork_messages" }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("sessions.fork_messages", result.data and result.data.messages)
      end
      if callback then callback(result) end
    end)
  end)
end

--- Set session display name
-- @param client RPC client
-- @param name string The display name for the session
-- @param callback function|nil Called with result
function M.set_name(client, name, callback)
  client:request("set_session_name", {
    type = "set_session_name",
    name = name,
  }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("agent.session_name", name)
        events.emit("session_name_changed", { name = name })
      end
      if callback then callback(result) end
    end)
  end)
end

return M

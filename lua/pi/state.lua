local events = require("pi.events")

local M = {}

-- Single source of truth for plugin state
M.state = {
  -- RPC connection
  connected = false,
  rpc_client = nil,
  
  -- Agent state
  agent = {
    running = false,
    paused = false,
    current_task = nil,
    session_id = nil,
  },
  
  -- Files being modified
  files = {
    pending = {},      -- Files with pending changes awaiting approval
    modified = {},     -- Files already modified
    watching = {},     -- File watchers
  },
  
  -- Logs
  logs = {
    entries = {},      -- Array of log entries
    stream_active = false,
  },
  
  -- UI state
  ui = {
    control_panel_open = false,
    diff_viewer_open = false,
    logs_open = false,
    chat_open = false,
  },
  
  -- Sessions
  sessions = {
    current = nil,
    available = {},
  },
}

-- Update state and emit event
function M.update(path, value)
  -- Navigate nested path and update
  local keys = vim.split(path, ".", { plain = true })
  local current = M.state
  
  for i = 1, #keys - 1 do
    current = current[keys[i]]
  end
  
  current[keys[#keys]] = value
  
  -- Emit state change event
  events.emit("state_updated", path, value)
end

-- Get state value
function M.get(path)
  if not path then return M.state end
  
  local keys = vim.split(path, ".", { plain = true })
  local current = M.state
  
  for _, key in ipairs(keys) do
    current = current[key]
    if current == nil then return nil end
  end
  
  return current
end

return M
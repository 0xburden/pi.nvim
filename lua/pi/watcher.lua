local uv = vim.loop
local state = require("pi.state")
local events = require("pi.events")

local M = {}

-- Watch a file for changes
function M.watch(filepath)
  local watching = state.get("files.watching")
  
  -- Don't watch if already watching
  if watching[filepath] then
    return
  end
  
  -- Create file watcher
  local handle = uv.new_fs_event()
  
  handle:start(filepath, {}, vim.schedule_wrap(function(err, filename, event_type)
    if err then
      vim.notify("Watcher error: " .. err, vim.log.levels.ERROR)
      return
    end
    
    -- File changed
    events.emit("file_changed", {
      path = filepath,
      event = event_type,
    })
  end))
  
  watching[filepath] = handle
  state.update("files.watching", watching)
end

-- Stop watching a file
function M.unwatch(filepath)
  local watching = state.get("files.watching")
  local handle = watching[filepath]
  
  if handle then
    handle:stop()
    watching[filepath] = nil
    state.update("files.watching", watching)
  end
end

-- Stop watching all files
function M.unwatch_all()
  local watching = state.get("files.watching")
  
  for filepath, handle in pairs(watching) do
    handle:stop()
  end
  
  state.update("files.watching", {})
end

return M
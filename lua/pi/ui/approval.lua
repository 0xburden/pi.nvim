local state = require("pi.state")
local events = require("pi.events")
local diff_viewer = require("pi.ui.diff_viewer")

local M = {}
M.current_file = nil
M.pending_queue = {}

-- Add file to approval queue
function M.add_pending(filepath, content)
  table.insert(M.pending_queue, {
    path = filepath,
    content = content,
  })
  
  local pending = state.get("files.pending")
  pending[filepath] = content
  state.update("files.pending", pending)
  
  -- If no file currently being reviewed, start review
  if not M.current_file then
    M.review_next()
  end
end

-- Review next file in queue
function M.review_next()
  if #M.pending_queue == 0 then
    M.current_file = nil
    vim.notify("All changes reviewed!", vim.log.levels.INFO)
    return
  end
  
  local next_change = table.remove(M.pending_queue, 1)
  M.current_file = next_change
  
  -- Show diff
  diff_viewer.show(next_change.path)
  
  -- Notify user
  vim.notify(
    string.format("Review change to %s (:PiApprove / :PiReject)", next_change.path),
    vim.log.levels.INFO
  )
end

-- Approve current change
function M.approve()
  if not M.current_file then
    vim.notify("No pending changes to approve", vim.log.levels.WARN)
    return
  end
  
  local filepath = M.current_file.path
  local content = M.current_file.content
  
  -- Write content to file directly
  local ok, err = pcall(function()
    local file = io.open(filepath, "w")
    if not file then
      error("Failed to open file: " .. filepath)
    end
    file:write(content)
    file:close()
  end)
  
  if not ok then
    vim.notify("Failed to apply change: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  
  -- Mark as modified
  local modified = state.get("files.modified")
  table.insert(modified, filepath)
  state.update("files.modified", modified)
  
  -- Remove from pending
  local pending = state.get("files.pending")
  pending[filepath] = nil
  state.update("files.pending", pending)
  
  vim.notify("Change approved and applied!", vim.log.levels.INFO)
  
  -- Close diff and review next
  diff_viewer.close()
  M.review_next()
end

-- Reject current change
function M.reject()
  if not M.current_file then
    vim.notify("No pending changes to reject", vim.log.levels.WARN)
    return
  end
  
  local filepath = M.current_file.path
  
  -- Remove from pending
  local pending = state.get("files.pending")
  pending[filepath] = nil
  state.update("files.pending", pending)
  
  vim.notify("Change rejected", vim.log.levels.INFO)
  
  -- Close diff and review next
  diff_viewer.close()
  M.review_next()
end

-- Get pending count
function M.pending_count()
  return #M.pending_queue
end

return M
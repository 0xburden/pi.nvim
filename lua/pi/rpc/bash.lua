local M = {}

local state = require("pi.state")
local events = require("pi.events")

--- Execute a shell command and add output to conversation context
-- The output is included in the LLM context on the NEXT prompt, not immediately.
-- Multiple bash commands can be executed before a prompt; all outputs will be included.
-- @param client RPC client
-- @param command string The shell command to execute
-- @param callback function|nil Called with result containing { output, exitCode, cancelled, truncated, fullOutputPath }
function M.execute(client, command, callback)
  -- Track that we're running a bash command
  state.update("bash.running", true)
  state.update("bash.current_command", command)
  events.emit("bash_start", { command = command })
  
  client:request("bash", { type = "bash", command = command }, function(result)
    vim.schedule(function()
      state.update("bash.running", false)
      state.update("bash.current_command", nil)
      
      if result and result.success then
        local data = result.data or {}
        
        -- Store execution result
        local execution = {
          command = command,
          output = data.output,
          exit_code = data.exitCode,
          cancelled = data.cancelled,
          truncated = data.truncated,
          full_output_path = data.fullOutputPath,
          timestamp = vim.loop.now(),
        }
        
        -- Add to executions history
        local executions = state.get("bash.executions") or {}
        table.insert(executions, execution)
        -- Keep only last 50 executions
        if #executions > 50 then
          table.remove(executions, 1)
        end
        state.update("bash.executions", executions)
        state.update("bash.last_execution", execution)
        
        events.emit("bash_end", execution)
      else
        events.emit("bash_error", { command = command, error = result and result.error })
      end
      
      if callback then callback(result) end
    end)
  end)
end

--- Abort a running bash command
-- @param client RPC client
-- @param callback function|nil Called with result
function M.abort(client, callback)
  client:request("abort_bash", { type = "abort_bash" }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("bash.running", false)
        state.update("bash.current_command", nil)
        events.emit("bash_aborted")
      end
      if callback then callback(result) end
    end)
  end)
end

--- Check if a bash command is currently running
-- @return boolean
function M.is_running()
  return state.get("bash.running") or false
end

--- Get the last bash execution result
-- @return table|nil The last execution { command, output, exit_code, ... }
function M.get_last()
  return state.get("bash.last_execution")
end

--- Get all bash execution history
-- @return table Array of execution results
function M.get_history()
  return state.get("bash.executions") or {}
end

--- Clear bash execution history (local only)
function M.clear_history()
  state.update("bash.executions", {})
  state.update("bash.last_execution", nil)
  events.emit("bash_history_cleared")
end

return M

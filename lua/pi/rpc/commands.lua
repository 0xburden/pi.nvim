--- Command Discovery RPC
-- Get available Pi commands (extensions, prompt templates, skills)

local M = {}

local state = require("pi.state")
local events = require("pi.events")

--- Get all available commands
-- Returns extension commands, prompt templates, and skills
-- @param client RPC client
-- @param callback function Called with result { commands = [...] }
function M.get_all(client, callback)
  client:request("get_commands", { type = "get_commands" }, function(result)
    vim.schedule(function()
      if result and result.success then
        local commands = result.data and result.data.commands or {}
        state.update("commands.available", commands)
        events.emit("commands_loaded", { commands = commands })
      end
      if callback then callback(result) end
    end)
  end)
end

--- Get commands from state (doesn't fetch from server)
-- @return table Array of command objects
function M.get_cached()
  return state.get("commands.available") or {}
end

--- Filter commands by source type
-- @param source string "extension", "prompt", or "skill"
-- @return table Filtered commands
function M.filter_by_source(source)
  local commands = M.get_cached()
  local filtered = {}
  for _, cmd in ipairs(commands) do
    if cmd.source == source then
      table.insert(filtered, cmd)
    end
  end
  return filtered
end

--- Get extension commands only
-- @return table Extension commands
function M.get_extensions()
  return M.filter_by_source("extension")
end

--- Get prompt template commands only
-- @return table Prompt template commands
function M.get_prompts()
  return M.filter_by_source("prompt")
end

--- Get skill commands only
-- @return table Skill commands
function M.get_skills()
  return M.filter_by_source("skill")
end

--- Find a command by name
-- @param name string Command name (without leading /)
-- @return table|nil The command object if found
function M.find(name)
  local commands = M.get_cached()
  for _, cmd in ipairs(commands) do
    if cmd.name == name then
      return cmd
    end
  end
  return nil
end

--- Format a command for display
-- @param cmd table Command object
-- @return string Formatted display string
function M.format(cmd)
  if not cmd then return "" end
  
  local parts = { "/" .. cmd.name }
  
  if cmd.description then
    table.insert(parts, " - " .. cmd.description)
  end
  
  if cmd.source then
    table.insert(parts, " [" .. cmd.source .. "]")
  end
  
  return table.concat(parts)
end

--- Local-only commands that are handled client-side (not from the agent).
local local_commands = {
  { name = "/model", description = "Switch the active model", source = "local" },
  { name = "/thinking", description = "Set thinking / reasoning level", source = "local" },
}

--- Get command completion items for telescope/fzf
-- @return table Array of { name, description, source, location }
function M.get_completion_items()
  local commands = M.get_cached()
  local items = {}
  -- Include local (client-side) commands
  for _, cmd in ipairs(local_commands) do
    table.insert(items, {
      name = cmd.name,
      description = cmd.description,
      source = cmd.source,
    })
  end
  -- Include server-side commands
  for _, cmd in ipairs(commands) do
    table.insert(items, {
      name = "/" .. cmd.name,
      description = cmd.description or "",
      source = cmd.source or "unknown",
      location = cmd.location,
      path = cmd.path,
    })
  end
  return items
end

return M

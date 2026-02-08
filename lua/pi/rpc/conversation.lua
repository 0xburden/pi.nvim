local M = {}

local state = require("pi.state")
local events = require("pi.events")

--- Get all messages in the conversation
-- @param client RPC client
-- @param callback function Called with result containing messages array
function M.get_messages(client, callback)
  client:request("get_messages", { type = "get_messages" }, function(result)
    vim.schedule(function()
      if result and result.success then
        local messages = result.data and result.data.messages or {}
        state.update("conversation.messages", messages)
        events.emit("conversation_updated", messages)
      end
      if callback then callback(result) end
    end)
  end)
end

--- Get the text content of the last assistant message
-- @param client RPC client
-- @param callback function Called with result containing { text = "..." } or { text = nil }
function M.get_last_assistant_text(client, callback)
  client:request("get_last_assistant_text", { type = "get_last_assistant_text" }, function(result)
    vim.schedule(function()
      if result and result.success then
        state.update("conversation.last_assistant_text", result.data and result.data.text)
      end
      if callback then callback(result) end
    end)
  end)
end

--- Send a message to the conversation (alias for agent.prompt)
-- For convenience when working with conversation module
-- @param client RPC client
-- @param message string The message to send
-- @param opts table|nil Options passed to agent.prompt
-- @param callback function|nil Called with result
function M.send(client, message, opts, callback)
  local agent = require("pi.rpc.agent")
  agent.prompt(client, message, opts, callback)
end

--- Clear conversation state (local only, doesn't affect server)
-- Use session.new() to actually start a fresh session
function M.clear_local()
  state.update("conversation.messages", {})
  state.update("conversation.last_assistant_text", nil)
  events.emit("conversation_cleared")
end

--- Helper: Extract text from a message's content
-- Handles both string content and content block arrays
-- @param message table A message object (UserMessage or AssistantMessage)
-- @return string The extracted text content
function M.extract_text(message)
  if not message then return "" end
  
  local content = message.content
  if type(content) == "string" then
    return content
  end
  
  if type(content) == "table" then
    local texts = {}
    for _, block in ipairs(content) do
      if block.type == "text" then
        table.insert(texts, block.text)
      end
    end
    return table.concat(texts, "\n")
  end
  
  return ""
end

--- Helper: Extract thinking from an assistant message
-- @param message table An AssistantMessage object
-- @return string|nil The thinking content if present
function M.extract_thinking(message)
  if not message or message.role ~= "assistant" then return nil end
  
  local content = message.content
  if type(content) ~= "table" then return nil end
  
  local thoughts = {}
  for _, block in ipairs(content) do
    if block.type == "thinking" then
      table.insert(thoughts, block.thinking)
    end
  end
  
  return #thoughts > 0 and table.concat(thoughts, "\n") or nil
end

--- Helper: Extract tool calls from an assistant message
-- @param message table An AssistantMessage object
-- @return table Array of tool call objects { id, name, arguments }
function M.extract_tool_calls(message)
  if not message or message.role ~= "assistant" then return {} end
  
  local content = message.content
  if type(content) ~= "table" then return {} end
  
  local tool_calls = {}
  for _, block in ipairs(content) do
    if block.type == "toolCall" then
      table.insert(tool_calls, {
        id = block.id,
        name = block.name,
        arguments = block.arguments,
      })
    end
  end
  
  return tool_calls
end

--- Helper: Format a message for display
-- @param message table A message object
-- @return table { role = "...", text = "...", thinking = "...", tool_calls = {...} }
function M.format_message(message)
  return {
    role = message.role,
    text = M.extract_text(message),
    thinking = M.extract_thinking(message),
    tool_calls = M.extract_tool_calls(message),
    timestamp = message.timestamp,
    -- For assistant messages
    model = message.model,
    usage = message.usage,
    stop_reason = message.stopReason,
    -- For tool results
    tool_call_id = message.toolCallId,
    tool_name = message.toolName,
    is_error = message.isError,
  }
end

--- Helper: Get formatted conversation for display
-- @return table Array of formatted messages
function M.get_formatted()
  local messages = state.get("conversation.messages") or {}
  local formatted = {}
  for _, msg in ipairs(messages) do
    table.insert(formatted, M.format_message(msg))
  end
  return formatted
end

return M

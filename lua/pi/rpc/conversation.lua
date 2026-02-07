local M = {}

-- Get conversation history
function M.history(client, callback)
  client:request("conversation.history", {}, callback)
end

-- Send message to agent
function M.send(client, message, callback)
  client:request("conversation.send", { message = message }, callback)
end

-- Clear conversation
function M.clear(client, callback)
  client:request("conversation.clear", {}, callback)
end

return M
local M = {}

-- Read file content
function M.read(client, filepath, callback)
  client:request("files.read", { path = filepath }, callback)
end

-- Write file content
function M.write(client, filepath, content, callback)
  client:request("files.write", {
    path = filepath,
    content = content
  }, callback)
end

-- List files in directory
function M.list(client, dirpath, callback)
  client:request("files.list", { path = dirpath }, callback)
end

-- Get file stats
function M.stat(client, filepath, callback)
  client:request("files.stat", { path = filepath }, callback)
end

return M
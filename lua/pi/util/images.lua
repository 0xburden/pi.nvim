local M = {}

local base64 = require("pi.util.base64")
local uv = vim.loop

local function read_file(path)
  local fd, err = uv.fs_open(path, "r", 438)
  if not fd then
    return nil, err
  end

  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, stat_err
  end

  local data, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data then
    return nil, read_err
  end

  return data
end

local function detect_mime(path)
  local lower = path:lower()
  if lower:match("%.png$") then
    return "image/png"
  end
  if lower:match("%.jpe?g$") then
    return "image/jpeg"
  end
  return nil
end

--- Encode an image file for RPC payloads
-- @param path string
-- @return table|nil { data = base64, mimeType = "...", path = "..." }
-- @return string|nil error message
function M.encode_image(path)
  local mime = detect_mime(path)
  if not mime then
    return nil, "Unsupported image type (png/jpeg only)"
  end

  local data, err = read_file(path)
  if not data then
    return nil, err or "Failed to read image"
  end

  return {
    data = base64.encode(data),
    mimeType = mime,
    path = path,
  }
end

return M

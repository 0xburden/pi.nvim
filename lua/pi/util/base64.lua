local M = {}

local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Encode a binary string as base64
-- @param data string
-- @return string
function M.encode(data)
  if data == nil or data == "" then
    return ""
  end

  local encoded = ((data:gsub(".", function(char)
    local byte = char:byte()
    local bits = ""
    for i = 8, 1, -1 do
      bits = bits .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0")
    end
    return bits
  end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(chunk)
    if #chunk < 6 then
      return ""
    end
    local value = 0
    for i = 1, 6 do
      if chunk:sub(i, i) == "1" then
        value = value + 2 ^ (6 - i)
      end
    end
    return alphabet:sub(value + 1, value + 1)
  end))

  local padding = ({ "", "==", "=" })[#data % 3 + 1]
  return encoded .. padding
end

return M

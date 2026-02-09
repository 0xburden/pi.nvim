local M = {}
local bit = require("bit")

local function wrap_get_hl(group)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if not ok or not hl then
    return {}
  end
  return hl
end

function M.get_hl_color(group, attr)
  local hl = wrap_get_hl(group)
  if attr == "foreground" or attr == "fg" then
    return hl.fg
  elseif attr == "background" or attr == "bg" then
    return hl.bg
  end
  return nil
end

function M.hex_to_rgb(hex)
  if not hex then
    return 0, 0, 0
  end
  local r = bit.rshift(bit.band(hex, 0xFF0000), 16)
  local g = bit.rshift(bit.band(hex, 0x00FF00), 8)
  local b = bit.band(hex, 0x0000FF)
  return r, g, b
end

function M.rgb_to_hex(r, g, b)
  r = math.max(0, math.min(255, math.floor(r)))
  g = math.max(0, math.min(255, math.floor(g)))
  b = math.max(0, math.min(255, math.floor(b)))
  return bit.lshift(r, 16) + bit.lshift(g, 8) + b
end

function M.shade_color(hex, percent)
  if not hex or not percent then
    return hex
  end
  local r, g, b = M.hex_to_rgb(hex)
  local factor = (100 + percent) / 100
  local function adjust(value)
    return math.max(0, math.min(255, math.floor(value * factor)))
  end
  return M.rgb_to_hex(adjust(r), adjust(g), adjust(b))
end

function M.darken(hex, amount)
  if not hex then
    return nil
  end
  amount = math.max(0, math.min(1, amount))
  local r, g, b = M.hex_to_rgb(hex)
  r = math.floor(r * (1 - amount))
  g = math.floor(g * (1 - amount))
  b = math.floor(b * (1 - amount))
  return M.rgb_to_hex(r, g, b)
end

function M.lighten(hex, amount)
  if not hex then
    return nil
  end
  amount = math.max(0, math.min(1, amount))
  local r, g, b = M.hex_to_rgb(hex)
  r = math.floor(r + (255 - r) * amount)
  g = math.floor(g + (255 - g) * amount)
  b = math.floor(b + (255 - b) * amount)
  return M.rgb_to_hex(r, g, b)
end

function M.blend(hex1, hex2, ratio)
  if not hex1 then
    return hex2
  end
  if not hex2 then
    return hex1
  end
  ratio = math.max(0, math.min(1, ratio))
  local r1, g1, b1 = M.hex_to_rgb(hex1)
  local r2, g2, b2 = M.hex_to_rgb(hex2)
  local r = math.floor(r1 + (r2 - r1) * ratio)
  local g = math.floor(g1 + (g2 - g1) * ratio)
  local b = math.floor(b1 + (b2 - b1) * ratio)
  return M.rgb_to_hex(r, g, b)
end

function M.is_dark_theme()
  if vim.o.background == "dark" then
    return true
  elseif vim.o.background == "light" then
    return false
  end
  local normal_bg = M.get_hl_color("Normal", "background")
  if normal_bg then
    local r, g, b = M.hex_to_rgb(normal_bg)
    local brightness = (r * 299 + g * 587 + b * 114) / 1000
    return brightness < 128
  end
  return true
end

function M.get_code_bg()
  local normal_bg = M.get_hl_color("Normal", "background")
  if not normal_bg then
    return M.is_dark_theme() and 0x1a1a1a or 0xf0f0f0
  end
  if M.is_dark_theme() then
    return M.darken(normal_bg, 0.15)
  end
  return M.lighten(normal_bg, 0.05)
end

function M.get_user_message_bg()
  local visual_bg = M.get_hl_color("Visual", "background")
  if visual_bg then
    return visual_bg
  end
  local pmenu_bg = M.get_hl_color("Pmenu", "background")
  if pmenu_bg then
    return pmenu_bg
  end
  local normal_bg = M.get_hl_color("Normal", "background")
  if normal_bg then
    if M.is_dark_theme() then
      return M.lighten(normal_bg, 0.1)
    end
    return M.darken(normal_bg, 0.05)
  end
  return M.is_dark_theme() and 0x2a2a2a or 0xe0e0e0
end

function M.get_text_fg()
  return M.get_hl_color("Normal", "foreground") or (M.is_dark_theme() and 0xffffff or 0x000000)
end

function M.get_thinking_fg()
  return M.get_hl_color("Comment", "foreground") or (M.is_dark_theme() and 0x808080 or 0x606060)
end

function M.get_tool_fg()
  return M.get_hl_color("Special", "foreground") or M.get_hl_color("Function", "foreground")
end

function M.apply_highlight(name, def)
  local highlight = {}
  if def.link then
    vim.api.nvim_set_hl(0, name, { link = def.link })
    return
  end

  if def.fg then
    highlight.fg = def.fg
  elseif def.fg_link then
    highlight.fg = M.get_hl_color(def.fg_link, "foreground")
  elseif def.fg_link_bg then
    highlight.fg = M.get_hl_color(def.fg_link_bg, "background")
  end

  if def.bg then
    highlight.bg = def.bg
  elseif def.bg_link then
    highlight.bg = M.get_hl_color(def.bg_link, "background")
  elseif def.bg_link_fg then
    highlight.bg = M.get_hl_color(def.bg_link_fg, "foreground")
  end

  if def.bold then
    highlight.bold = true
  end
  if def.italic then
    highlight.italic = true
  end
  if def.underline then
    highlight.underline = true
  end
  if def.strikethrough then
    highlight.strikethrough = true
  end
  if def.reverse then
    highlight.reverse = true
  end

  vim.api.nvim_set_hl(0, name, highlight)
end

function M.has_user_colors(name)
  local fg = M.get_hl_color(name, "foreground")
  local bg = M.get_hl_color(name, "background")
  return fg ~= nil or bg ~= nil
end

return M

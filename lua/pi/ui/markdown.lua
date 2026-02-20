local M = {}

--- Detect if Treesitter markdown parser is available
local has_ts_markdown = (function()
  local ok, parser = pcall(vim.treesitter.get_string_parser, "", "markdown")
  return ok and parser ~= nil
end)()

local function ensure_trailing_newline(text)
  if text:sub(-1) ~= "\n" then
    return text .. "\n"
  end
  return text
end

local function parse_with_treesitter(text)
  local normalized = ensure_trailing_newline(text or "")
  local ok, parser = pcall(vim.treesitter.get_string_parser, normalized, "markdown")
  if not ok or not parser then
    return nil
  end

  local trees = parser:parse()
  local tree = trees and trees[1]
  if not tree then
    return nil
  end

  local root = tree:root()
  local query_str = [[
    (fenced_code_block
      (info_string (language) @language)?
      (code_fence_content) @content) @block
  ]]

  local query_ok, query = pcall(vim.treesitter.query.parse, "markdown", query_str)
  if not query_ok or not query then
    return nil
  end

  local lines = vim.split(normalized, "\n", { plain = true })
  local blocks = {}
  local current_block

  for id, node in query:iter_captures(root, normalized) do
    local capture = query.captures[id]
    if capture == "block" then
      local start_row, _, end_row, end_col = node:range()
      local block_end = end_col and end_col > 0 and end_row or math.max(0, (end_row or start_row + 1) - 1)
      current_block = {
        block_start = start_row,
        block_end = block_end,
        lang = nil,
        content = nil,
        incomplete = false,
      }
      table.insert(blocks, current_block)
    elseif capture == "language" and current_block then
      current_block.lang = vim.treesitter.get_node_text(node, normalized)
    elseif capture == "content" and current_block then
      local node_text = vim.treesitter.get_node_text(node, normalized)
      current_block.content = node_text:gsub("\n$", "")
    end
  end

  local filtered = {}
  for _, block in ipairs(blocks) do
    if block.content and not block.content:match("^```%s*$") then
      local closing_line = lines[block.block_end + 1]
      if not closing_line or not closing_line:match("^%s*```%s*$") then
        block.incomplete = true
      end
      table.insert(filtered, block)
    end
  end

  return filtered
end

--- Parse a single line into inline segments.
--- Recognises: bold (**/..), italic (*/_..), bold-italic (***), strikethrough (~~),
--- inline code (`), and links ([text](url)).
--- Each segment has: type, content, and optionally open_marker / close_marker.
function M.parse_inline_segments(line)
  local segments = {}
  local pos = 1
  local len = #line

  while pos <= len do
    local found_special = false
    local ch  = line:sub(pos, pos)
    local ch2 = line:sub(pos, pos + 1)
    local ch3 = line:sub(pos, pos + 2)

    -- Bold-italic:  ***text***
    if not found_special and ch3 == "***" then
      local close = line:find("%*%*%*", pos + 3, true)
      if close then
        table.insert(segments, {
          type = "bold_italic",
          content = line:sub(pos + 3, close - 1),
          open_marker = "***",
          close_marker = "***",
        })
        pos = close + 3
        found_special = true
      end
    end

    -- Bold:  **text**  or  __text__
    if not found_special and (ch2 == "**" and line:sub(pos + 2, pos + 2) ~= "*") then
      local close = line:find("%*%*", pos + 2, true)
      if close and line:sub(close + 2, close + 2) ~= "*" then
        table.insert(segments, {
          type = "bold",
          content = line:sub(pos + 2, close - 1),
          open_marker = "**",
          close_marker = "**",
        })
        pos = close + 2
        found_special = true
      end
    end
    if not found_special and ch2 == "__" and line:sub(pos + 2, pos + 2) ~= "_" then
      local close = line:find("__", pos + 2, true)
      if close and line:sub(close + 2, close + 2) ~= "_" then
        table.insert(segments, {
          type = "bold",
          content = line:sub(pos + 2, close - 1),
          open_marker = "__",
          close_marker = "__",
        })
        pos = close + 2
        found_special = true
      end
    end

    -- Italic:  *text*  or  _text_
    if not found_special and ch == "*" and line:sub(pos + 1, pos + 1) ~= "*" then
      local close = line:find("%*", pos + 1, true)
      if close and line:sub(close + 1, close + 1) ~= "*" then
        table.insert(segments, {
          type = "italic",
          content = line:sub(pos + 1, close - 1),
          open_marker = "*",
          close_marker = "*",
        })
        pos = close + 1
        found_special = true
      end
    end
    if not found_special and ch == "_" and line:sub(pos + 1, pos + 1) ~= "_" then
      local close = line:find("_", pos + 1, true)
      if close and line:sub(close + 1, close + 1) ~= "_" then
        table.insert(segments, {
          type = "italic",
          content = line:sub(pos + 1, close - 1),
          open_marker = "_",
          close_marker = "_",
        })
        pos = close + 1
        found_special = true
      end
    end

    -- Strikethrough:  ~~text~~
    if not found_special and ch2 == "~~" then
      local close = line:find("~~", pos + 2, true)
      if close then
        table.insert(segments, {
          type = "strike",
          content = line:sub(pos + 2, close - 1),
          open_marker = "~~",
          close_marker = "~~",
        })
        pos = close + 2
        found_special = true
      end
    end

    -- Inline code:  `text`
    if not found_special and ch == "`" then
      local close = line:find("`", pos + 1, true)
      if close then
        table.insert(segments, {
          type = "code",
          content = line:sub(pos + 1, close - 1),
        })
        pos = close + 1
        found_special = true
      end
    end

    -- Link:  [text](url)
    if not found_special and ch == "[" then
      local bracket_close = line:find("]%(", pos + 1, true)
      if bracket_close then
        local url_end = line:find(")", bracket_close + 2, true)
        if url_end then
          table.insert(segments, {
            type = "link",
            content = line:sub(pos + 1, bracket_close - 1),
            url = line:sub(bracket_close + 2, url_end - 1),
          })
          pos = url_end + 1
          found_special = true
        end
      end
    end

    if not found_special then
      -- Advance to next potential special character
      local next_pos = line:find("[%*~`%[_]", pos + 1, false)
      local last = segments[#segments]
      if next_pos then
        local chunk = line:sub(pos, next_pos - 1)
        if last and last.type == "text" then
          last.content = last.content .. chunk
        else
          table.insert(segments, { type = "text", content = chunk })
        end
        pos = next_pos
      else
        local chunk = line:sub(pos)
        if last and last.type == "text" then
          last.content = last.content .. chunk
        else
          table.insert(segments, { type = "text", content = chunk })
        end
        break
      end
    end
  end

  if #segments == 0 then
    table.insert(segments, { type = "text", content = line })
  end

  return segments
end

-- Backward-compat alias
M.parse_inline_code = M.parse_inline_segments

local function should_highlight_inline(line)
  if not line then return false end
  return line:match("`[^`]+`") ~= nil
    or line:match("%*%*.+%*%*") ~= nil
    or line:match("%*[^%*].-%*") ~= nil
    or line:match("__[^_].+__") ~= nil
    or line:match("_[^_].+_") ~= nil
    or line:match("~~.+~~") ~= nil
    or line:match("%[.+%]%(.+%)") ~= nil
end

local function build_result_blocks(text, ts_blocks)
  local lines = vim.split(text or "", "\n", { plain = true })
  local result = {}
  local line_idx = 1
  local block_idx = 1

  local function push_line(line)
    -- Check for heading
    local hashes, hcontent = line:match("^(#+)%s+(.-)%s*$")
    if hashes then
      table.insert(result, {
        type = "heading",
        level = math.min(#hashes, 6),
        content = hcontent,
        start_line = line_idx,
        end_line = line_idx,
      })
      return
    end

    if should_highlight_inline(line) then
      table.insert(result, {
        type = "text_with_inline",
        raw = line,
        segments = M.parse_inline_segments(line),
        start_line = line_idx,
        end_line = line_idx,
      })
    else
      table.insert(result, {
        type = "text",
        content = line,
        start_line = line_idx,
        end_line = line_idx,
      })
    end
  end

  while line_idx <= #lines do
    local block = ts_blocks and ts_blocks[block_idx]
    if block and line_idx == block.block_start + 1 then
      table.insert(result, {
        type = "code",
        content = block.content or "",
        lang = block.lang,
        start_line = line_idx,
        end_line = (block.block_end or line_idx) + 1,
        incomplete = block.incomplete or false,
      })
      line_idx = (block.block_end or line_idx) + 2
      block_idx = block_idx + 1
    else
      local line = lines[line_idx] or ""
      push_line(line)
      line_idx = line_idx + 1
    end
  end

  return result
end

function M.parse(text, allow_incomplete)
  allow_incomplete = allow_incomplete == true
  if has_ts_markdown then
    local ts_blocks = parse_with_treesitter(text)
    if ts_blocks then
      if not allow_incomplete then
        for _, block in ipairs(ts_blocks) do
          if block.incomplete then
            return M.parse_regex(text, allow_incomplete)
          end
        end
      end
      return build_result_blocks(text, ts_blocks)
    end
  end
  return M.parse_regex(text, allow_incomplete)
end

function M.parse_regex(text, allow_incomplete)
  allow_incomplete = allow_incomplete == true
  local lines = vim.split(text or "", "\n", { plain = true })
  local result = {}
  local i = 1

  while i <= #lines do
    local line = lines[i] or ""

    -- Fenced code block
    local fence_lang = line:match("^%s*```%s*([^%s`]*)")
    if fence_lang then
      local lang = fence_lang ~= "" and fence_lang or nil
      local code_lines = {}
      local start_line = i
      local found_closing = false
      i = i + 1

      while i <= #lines do
        if lines[i]:match("^%s*```%s*$") then
          found_closing = true
          break
        end
        table.insert(code_lines, lines[i])
        i = i + 1
      end

      if not found_closing then
        if allow_incomplete then
          table.insert(result, {
            type = "code",
            content = table.concat(code_lines, "\n"),
            lang = lang,
            start_line = start_line,
            end_line = #lines,
            incomplete = true,
          })
        else
          for idx = start_line, #lines do
            local literal = lines[idx] or ""
            local hashes, hcontent = literal:match("^(#+)%s+(.-)%s*$")
            if hashes then
              table.insert(result, {
                type = "heading",
                level = math.min(#hashes, 6),
                content = hcontent,
                start_line = idx,
                end_line = idx,
              })
            elseif should_highlight_inline(literal) then
              table.insert(result, {
                type = "text_with_inline",
                raw = literal,
                segments = M.parse_inline_segments(literal),
                start_line = idx,
                end_line = idx,
              })
            else
              table.insert(result, {
                type = "text",
                content = literal,
                start_line = idx,
                end_line = idx,
              })
            end
          end
          return result
        end
      else
        table.insert(result, {
          type = "code",
          content = table.concat(code_lines, "\n"),
          lang = lang,
          start_line = start_line,
          end_line = i,
          incomplete = not found_closing,
        })
        if found_closing then
          i = i + 1
        end
      end

    else
      -- Heading
      local hashes, hcontent = line:match("^(#+)%s+(.-)%s*$")
      if hashes then
        table.insert(result, {
          type = "heading",
          level = math.min(#hashes, 6),
          content = hcontent,
          start_line = i,
          end_line = i,
        })
      elseif should_highlight_inline(line) then
        table.insert(result, {
          type = "text_with_inline",
          raw = line,
          segments = M.parse_inline_segments(line),
          start_line = i,
          end_line = i,
        })
      else
        table.insert(result, {
          type = "text",
          content = line,
          start_line = i,
          end_line = i,
        })
      end
      i = i + 1
    end
  end

  return result
end

return M

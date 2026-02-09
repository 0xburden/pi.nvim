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

function M.parse_inline_code(line)
  local segments = {}
  local pos = 1

  while pos <= #line do
    local backtick = line:find("`", pos, true)
    if not backtick then
      if pos <= #line then
        table.insert(segments, { type = "text", content = line:sub(pos) })
      end
      break
    end

    if backtick > pos then
      table.insert(segments, { type = "text", content = line:sub(pos, backtick - 1) })
    end

    local close = line:find("`", backtick + 1, true)
    if close then
      table.insert(segments, { type = "code", content = line:sub(backtick + 1, close - 1) })
      pos = close + 1
    else
      table.insert(segments, { type = "text", content = line:sub(backtick) })
      break
    end
  end

  if #segments == 0 then
    table.insert(segments, { type = "text", content = line })
  end

  return segments
end

local function should_highlight_inline(line)
  return line and line:match("`[^`]+`") ~= nil
end

local function build_result_blocks(text, ts_blocks)
  local lines = vim.split(text or "", "\n", { plain = true })
  local result = {}
  local line_idx = 1
  local block_idx = 1

  local function push_line(line)
    if should_highlight_inline(line) then
      table.insert(result, {
        type = "text_with_inline",
        raw = line,
        segments = M.parse_inline_code(line),
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
    local fence_lang = line:match("^%s*```([%w_+%-]*)")
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
            if should_highlight_inline(literal) then
              table.insert(result, {
                type = "text_with_inline",
                raw = literal,
                segments = M.parse_inline_code(literal),
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
      if should_highlight_inline(line) then
        table.insert(result, {
          type = "text_with_inline",
          raw = line,
          segments = M.parse_inline_code(line),
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

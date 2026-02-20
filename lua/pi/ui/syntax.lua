local M = {}

local lang_available = {}

local function normalize_lang(lang)
  if type(lang) ~= "string" then
    return nil
  end

  lang = lang:match("^%s*(.-)%s*$")
  if lang == "" then
    return nil
  end

  lang = lang:match("^(%S+)") or lang
  lang = lang:lower()

  local aliases = {
    sh = "bash",
    shell = "bash",
    zsh = "bash",
    fish = "fish",
    js = "javascript",
    jsx = "javascript",
    ts = "typescript",
    tsx = "tsx",
    py = "python",
    rb = "ruby",
    yml = "yaml",
    ["c#"] = "c_sharp",
    csharp = "c_sharp",
    ["c++"] = "cpp",
    ["objective-c"] = "objc",
    ["objective-c++"] = "objcpp",
  }

  lang = aliases[lang] or lang

  local ok, normalized = pcall(function()
    if vim.treesitter.language and vim.treesitter.language.get_lang then
      return vim.treesitter.language.get_lang(lang)
    end
  end)

  if ok and normalized then
    lang = normalized
  end

  return lang
end

local function has_ts_highlights(lang)
  lang = normalize_lang(lang)
  if not lang then
    return false
  end
  if lang_available[lang] ~= nil then
    return lang_available[lang]
  end

  local ok = pcall(function()
    vim.treesitter.get_string_parser("", lang)
    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then
      error("missing highlights query")
    end
  end)

  lang_available[lang] = ok
  return ok
end

local function create_range_entries(highlights, code, capture_name, node)
  local start_row, start_col, end_row, end_col = node:range()
  if capture_name == nil or capture_name == "" then
    return
  end
  local group = "@" .. capture_name

  local lines = vim.split(code, "\n", { plain = true })

  if start_row == end_row then
    if end_col <= start_col then
      return
    end
    table.insert(highlights, {
      line = start_row,
      col_start = start_col,
      col_end = end_col,
      hl_group = group,
    })
    return
  end

  local last_row = end_col > 0 and end_row or math.max(0, end_row - 1)
  last_row = math.min(last_row, #lines - 1)

  for row = start_row, last_row do
    local line_text = lines[row + 1] or ""
    local cs = (row == start_row) and start_col or 0
    local ce
    if row == end_row then
      if end_col > 0 then
        ce = end_col
      else
        ce = #line_text
      end
    else
      ce = #line_text
    end
    if ce > cs then
      table.insert(highlights, {
        line = row,
        col_start = cs,
        col_end = ce,
        hl_group = group,
      })
    end
  end
end

function M.get_highlights(code, lang)
  lang = normalize_lang(lang)
  if not lang then
    return {}
  end

  if not has_ts_highlights(lang) then
    return {}
  end

  local ok, parser = pcall(vim.treesitter.get_string_parser, code or "", lang)
  if not ok or not parser then
    return {}
  end

  local trees = parser:parse()
  local tree = trees and trees[1]
  if not tree then
    return {}
  end

  local query_ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not query_ok or not query then
    return {}
  end

  local root = tree:root()
  local highlights = {}

  for id, node in query:iter_captures(root, code or "") do
    local capture = query.captures[id]
    create_range_entries(highlights, code or "", capture, node)
  end

  return highlights
end

function M.cleanup()
  -- No-op: Treesitter string parsers clean up automatically
end

return M

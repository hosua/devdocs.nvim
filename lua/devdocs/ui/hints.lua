--- Key hints: "key action" pairs shown in the list's hint line, menu
--- footers, float footers and help screens. A hint is { key, action }; this
--- module turns a list of them into text plus highlight spans (byte columns,
--- for extmarks) or into nvim_open_win footer chunks, so every key is drawn in
--- DevDocsKey and every action in DevDocsDim. Pure.
local M = {}

M.KEY_HL = "DevDocsKey"
M.ACTION_HL = "DevDocsDim"
M.SEP = "  "

--- @alias DevDocsHint { [1]: string, [2]: string } key, action

--- "o browser  y url"
--- @param hints DevDocsHint[]
--- @param sep string|nil between hints (default two spaces)
--- @return string
function M.text(hints, sep)
  local parts = {}
  for _, h in ipairs(hints) do
    parts[#parts + 1] = h[1] .. " " .. h[2]
  end
  return table.concat(parts, sep or M.SEP)
end

--- Pieces of a hint line in order: { text, hl } with keys in KEY_HL and
--- everything else (actions, separators, prefix) in ACTION_HL.
local function pieces(hints, sep, prefix)
  local out = {}
  if prefix and prefix ~= "" then
    out[#out + 1] = { prefix, M.ACTION_HL }
  end
  for i, h in ipairs(hints) do
    out[#out + 1] = { h[1], M.KEY_HL }
    out[#out + 1] = { " " .. h[2] .. (i < #hints and sep or ""), M.ACTION_HL }
  end
  -- merge neighbours of the same highlight (the prefix into the first gap)
  local merged = {}
  for _, p in ipairs(out) do
    local last = merged[#merged]
    if last and last[2] == p[2] then
      last[1] = last[1] .. p[1]
    else
      merged[#merged + 1] = { p[1], p[2] }
    end
  end
  return merged
end

--- One line of hints and its spans { col_start, col_end, hl } (0-based byte
--- columns, end exclusive). The spans tile the whole line. With
--- opts.width the line is cut to that many display cells (with …) and the
--- spans are clipped to it.
--- @param hints DevDocsHint[]
--- @param opts { prefix?: string, sep?: string, width?: integer }|nil
--- @return string line, table[] spans
function M.line(hints, opts)
  opts = opts or {}
  local line, spans = "", {}
  for _, p in ipairs(pieces(hints, opts.sep or M.SEP, opts.prefix)) do
    spans[#spans + 1] = { col_start = #line, col_end = #line + #p[1], hl = p[2] }
    line = line .. p[1]
  end
  if opts.width and vim.fn.strdisplaywidth(line) > opts.width then
    local n = vim.fn.strchars(line)
    local cut = line
    while n > 0 and vim.fn.strdisplaywidth(cut) > opts.width - 1 do
      n = n - 1
      cut = vim.fn.strcharpart(line, 0, n)
    end
    local kept = {}
    for _, s in ipairs(spans) do
      if s.col_start < #cut then
        kept[#kept + 1] = { col_start = s.col_start, col_end = math.min(s.col_end, #cut), hl = s.hl }
      end
    end
    line, spans = cut .. "…", kept
  end
  return line, spans
end

--- Chunks for nvim_open_win's `footer` ({ text, hl } pairs), padded with a
--- space on each side like a plain footer. Trailing hints are dropped until
--- it fits `width` display cells.
--- @param hints DevDocsHint[]
--- @param width integer
--- @return table[] chunks
function M.chunks(hints, width)
  local n = #hints
  while n > 1 and vim.fn.strdisplaywidth(" " .. M.text(vim.list_slice(hints, 1, n)) .. " ") > width do
    n = n - 1
  end
  local out = pieces(vim.list_slice(hints, 1, n), M.SEP, " ")
  if #out > 0 then
    out[#out][1] = out[#out][1] .. " "
  end
  return out
end

--- Key column spans of a help screen: in a section whose heading (an
--- unindented line) mentions "keys", a line indented by exactly two spaces
--- starts with a key, which ends at the first run of two or more spaces.
--- Continuation lines (deeper indent) and other sections get nothing.
--- @param lines string[]
--- @return table[] spans { row (1-based), col_start, col_end, hl }
function M.help_spans(lines)
  local spans, in_keys = {}, false
  for row, line in ipairs(lines) do
    if line ~= "" and not line:match "^%s" then
      in_keys = line:find("keys", 1, true) ~= nil
    elseif in_keys then
      local key = line:match "^  (%S.-)%s%s+%S"
      if key then
        spans[#spans + 1] = { row = row, col_start = 2, col_end = 2 + #key, hl = M.KEY_HL }
      end
    end
  end
  return spans
end

return M

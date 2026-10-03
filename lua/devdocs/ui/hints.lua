--- Key hints: "key action" pairs shown in the list's hint line, menu
--- footers, float footers and help screens. A hint is { key, action }; this
--- module turns a list of them into text plus highlight spans (byte columns,
--- for extmarks) or into nvim_open_win footer chunks, so every key is drawn in
--- DevDocsKey and every action in DevDocsDim. Pure.
local M = {}

M.KEY_HL = "DevDocsKey"
M.ACTION_HL = "DevDocsDim"
M.SEP = "  "

--- @alias DevDocsHint { [1]: string, [2]: string, keep?: boolean } key, action; keep: never dropped from a narrow footer

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
--- it fits `width` display cells, except hints marked `keep = true` (the
--- ones that must stay visible, like the help and close keys).
--- @param hints DevDocsHint[]
--- @param width integer
--- @return table[] chunks
function M.chunks(hints, width)
  local shown = vim.list_slice(hints)
  while #shown > 1 and vim.fn.strdisplaywidth(" " .. M.text(shown) .. " ") > width do
    local drop
    for i = #shown, 1, -1 do
      if not shown[i].keep then
        drop = i
        break
      end
    end
    if not drop then
      break
    end
    table.remove(shown, drop)
  end
  local out = pieces(shown, M.SEP, " ")
  if #out > 0 then
    out[#out][1] = out[#out][1] .. " "
  end
  return out
end

M.HEADER_HL = "DevDocsHelpHeader"
M.TITLE_HL = "DevDocsHeader"

local dw = vim.fn.strdisplaywidth

--- Word wrap by display width. A word longer than the width stays whole;
--- "" gives { "" }.
--- @param text string
--- @param width integer
--- @return string[]
function M.wrap(text, width)
  local out, cur = {}, ""
  for word in text:gmatch "%S+" do
    if cur == "" then
      cur = word
    elseif dw(cur .. " " .. word) <= width then
      cur = cur .. " " .. word
    else
      out[#out + 1] = cur
      cur = word
    end
  end
  out[#out + 1] = cur
  return out
end

--- @alias DevDocsHelpRow { [1]: string, [2]: string } key (or first column), action
--- @class DevDocsHelpTable
--- @field header { [1]: string, [2]: string }|nil
--- @field rows DevDocsHelpRow[]
--- @field keys boolean|nil  first column holds keys, drawn in DevDocsKey (default true)

--- A two-column table as aligned lines: indent, the key padded to the key
--- column, gap, the action. With opts.width, actions wrap under the action
--- column (when at least 20 cells are left for them). Spans are
--- { row (1-based), col_start, col_end (0-based bytes), hl }: keys in
--- DevDocsKey, the header cells in DevDocsHelpHeader, actions plain.
--- @param tbl DevDocsHelpTable
--- @param opts { indent?: integer, gap?: integer, key_width?: integer, width?: integer }|nil
--- @return string[] lines, table[] spans
function M.table(tbl, opts)
  opts = opts or {}
  local indent, gap = opts.indent or 2, opts.gap or 3
  local key_width = opts.key_width
  if not key_width then
    key_width = tbl.header and dw(tbl.header[1]) or 0
    for _, r in ipairs(tbl.rows) do
      key_width = math.max(key_width, dw(r[1]))
    end
  end
  local lead = string.rep(" ", indent)
  local col = indent + key_width + gap
  local avail = opts.width and opts.width - col
  local lines, spans = {}, {}
  local function cells(first, second, first_hl, second_hl, wrap)
    local pad = string.rep(" ", key_width - dw(first) + gap)
    local pieces = wrap and avail and avail >= 20 and M.wrap(second, avail) or { second }
    lines[#lines + 1] = lead .. first .. pad .. pieces[1]
    local row = #lines
    if first_hl then
      spans[#spans + 1] = { row = row, col_start = indent, col_end = indent + #first, hl = first_hl }
    end
    if second_hl then
      local start = indent + #first + #pad
      spans[#spans + 1] = { row = row, col_start = start, col_end = start + #pieces[1], hl = second_hl }
    end
    for k = 2, #pieces do
      lines[#lines + 1] = string.rep(" ", col) .. pieces[k]
    end
  end
  if tbl.header then
    cells(tbl.header[1], tbl.header[2], M.HEADER_HL, M.HEADER_HL, false)
  end
  for _, r in ipairs(tbl.rows) do
    cells(r[1], r[2], tbl.keys ~= false and M.KEY_HL or nil, nil, true)
  end
  return lines, spans
end

--- A whole help screen from blocks: "" (blank line), { title = s }
--- (DevDocsHeader), { text = s } (a wrapped paragraph, indent 2) or a
--- DevDocsHelpTable. Every table shares one key column width so all the
--- actions line up.
--- @param blocks (string|table)[]
--- @param opts { indent?: integer, gap?: integer, width?: integer }|nil
--- @return string[] lines, table[] spans
function M.help(blocks, opts)
  opts = opts or {}
  local key_width = 0
  for _, b in ipairs(blocks) do
    if type(b) == "table" and b.rows then
      key_width = math.max(key_width, b.header and dw(b.header[1]) or 0)
      for _, r in ipairs(b.rows) do
        key_width = math.max(key_width, dw(r[1]))
      end
    end
  end
  local lines, spans = {}, {}
  local topt = { indent = opts.indent, gap = opts.gap, width = opts.width, key_width = key_width }
  for _, b in ipairs(blocks) do
    if b == "" then
      lines[#lines + 1] = ""
    elseif b.title then
      lines[#lines + 1] = b.title
      spans[#spans + 1] = { row = #lines, col_start = 0, col_end = #b.title, hl = M.TITLE_HL }
    elseif b.text then
      local indent = string.rep(" ", opts.indent or 2)
      for _, piece in ipairs(M.wrap(b.text, opts.width and opts.width - #indent or math.huge)) do
        lines[#lines + 1] = indent .. piece
      end
    else
      local tl, ts = M.table(b, topt)
      for _, sp in ipairs(ts) do
        sp.row = sp.row + #lines
        spans[#spans + 1] = sp
      end
      vim.list_extend(lines, tl)
    end
  end
  return lines, spans
end

return M

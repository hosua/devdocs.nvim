--- Glossary render: the lines and highlight spans of the doc index
--- (glossary.lua's rows), its title, footer hints and help screen. Pure.
--- Line i is row i, so a cursor line is a row index.
local hints = require "devdocs.ui.hints"
local index = require "devdocs.index"
local render = require "devdocs.ui.render"

local M = {}

M.FOOTER = {
  { "⏎", "open" },
  { "l/h", "expand/fold" },
  { "/", "filter" },
  { "I", "page" },
  { "⌫", "back", keep = true },
  { "s", "search" },
  { "?", "help", keep = true },
  { "q", "close", keep = true },
  -- least used last: a narrow float drops trailing hints, and ? lists them
  { "d", "doc" },
  { "o", "browser" },
  { "y", "url" },
}

M.HELP = {
  { title = "DevDocs index keys" },
  "",
  {
    header = { "Key", "Action" },
    rows = {
      { "Enter (<CR>)", "open the entry; on a type, expand / collapse it" },
      { "l / h", "expand / collapse; l on an entry opens it, h folds its type" },
      { "Tab", "expand / collapse" },
      { "zR / zM", "expand / collapse every type" },
      { "} / {", "next / previous type" },
      { "/", "filter entries by name (Esc clears, Enter keeps)" },
      { "I", "back to the page you came from" },
      { "Backspace (<BS>), u", "back" },
      { "s", "search inside this doc" },
      { "d", "another installed doc's index" },
      { "o / y", "open on devdocs.io / yank its url" },
      { "j / k, gg / G", "move" },
      { "?", "this help" },
      { "q, Esc", "close" },
    },
  },
}

--- The help screen's lines and highlight spans, wrapped to `width` cells.
--- @param width integer|nil
--- @return string[] lines, table[] spans
function M.help_lines(width)
  return hints.help(M.HELP, { width = width })
end

--- Display width, asking Vim only for lines with non-ASCII bytes.
local function width_of(s)
  if s:find "[\128-\255]" then
    return vim.fn.strdisplaywidth(s)
  end
  return #s
end

--- `text` cut to `avail` cells with a trailing … when it does not fit.
--- @return string text, boolean cut
local function fit(text, avail)
  if width_of(text) <= avail then
    return text, false
  end
  return (render.cell(text, avail):gsub("%s+$", "")), true
end

--- left, then right at the right edge (one space apart at least).
local function split_line(left, right, width)
  local pad = math.max(1, width - width_of(left) - width_of(right))
  return left .. string.rep(" ", pad) .. right
end

--- Spans of every occurrence of `needle` (lowercase) in the first `limit`
--- bytes of `text`, starting at byte offset `base`.
local function hits(text, needle, limit, base, row, out)
  local lower, from = text:lower(), 1
  while true do
    local s, e = lower:find(needle, from, true)
    if not s or e > limit then
      return
    end
    out[#out + 1] = { row = row, col_start = base + s - 1, col_end = base + e, hl = "DevDocsMatch" }
    from = e + 1
  end
end

--- The lines and spans for the rows of a tree, `opts.width` cells wide. The
--- doc row carries the version at the right edge, a type row its entry count
--- (matches/total while filtering), an entry row its name with ● in the
--- indent when it is `opts.current` and the filter hits highlighted.
--- @param tree DevDocsGlossary
--- @param rows DevDocsGlossaryRow[]
--- @param opts { width: integer, current?: DevDocsEntry|nil, filter?: string }
--- @return { lines: string[], spans: table[] }
function M.render(tree, rows, opts)
  local width = math.max(opts.width, 10)
  local needle = (opts.filter or ""):lower()
  local cur = opts.current
  local lines, spans = {}, {}
  for i, row in ipairs(rows) do
    if row.kind == "doc" then
      local left = (row.expanded and render.CHEVRON.open or render.CHEVRON.closed) .. tree.name
      lines[i] = split_line(left, tree.version, width)
      spans[#spans + 1] = { row = i, col_start = 0, col_end = #left, hl = "DevDocsHeader" }
      if tree.version ~= "" then
        spans[#spans + 1] = { row = i, col_start = #lines[i] - #tree.version, col_end = #lines[i], hl = "DevDocsDim" }
      end
    elseif row.kind == "group" then
      local count = needle ~= "" and ("%d/%d"):format(row.count, row.total) or tostring(row.count)
      local left = "  " .. (row.expanded and render.CHEVRON.open or render.CHEVRON.closed)
      local name = fit(tree.groups[row.group].name, width - vim.fn.strdisplaywidth(left) - #count - 1)
      lines[i] = split_line(left .. name, count, width)
      spans[#spans + 1] = { row = i, col_start = #lines[i] - #count, col_end = #lines[i], hl = "DevDocsDim" }
    else
      local e = row.entry
      local indent = string.rep(" ", row.depth == 1 and 4 or 6)
      local is_cur = cur ~= nil and (e == cur or (e.path == cur.path and e.name == cur.name))
      local lead = is_cur and (indent:sub(1, -3) .. "● ") or indent
      local name, cut = fit(e.name, width - #indent)
      lines[i] = lead .. name
      if is_cur then
        local s = #indent - 2
        spans[#spans + 1] = { row = i, col_start = s, col_end = s + #"●", hl = "DevDocsMark" }
      end
      if needle ~= "" then
        hits(name, needle, #name - (cut and #"…" or 0), #lead, i, spans)
      end
    end
  end
  return { lines = lines, spans = spans }
end

--- "Lua 5.4 › index", or "Lua 5.4 › index › /assert (12)" while filtering.
--- @param tree DevDocsGlossary
--- @param state DevDocsGlossaryState
--- @param nmatches integer|nil
--- @return string
function M.title(tree, state, nmatches)
  local title = index.breadcrumb(tree.slug, nil) .. " › index"
  if state.filter ~= "" then
    title = ("%s › /%s (%d)"):format(title, state.filter, nmatches or 0)
  end
  return title
end

--- The line shown for a doc without entries.
--- @param tree DevDocsGlossary
--- @return string
function M.empty(tree)
  return ("  no entries in %s (reinstall the doc)"):format(tree.slug)
end

return M

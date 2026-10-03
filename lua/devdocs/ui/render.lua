--- List manager renderer: state -> { lines, spans, regions }. Pure.
--- Header lines are fixed; only the visible window of rows is emitted so a
--- list of 800 docs scrolls without moving the header. Byte columns
--- throughout, which is what extmarks and getmousepos() use.
local model = require "devdocs.ui.model"

local M = {}

M.HEADER_LINES = 3

local ICON = {
  installing = "↓",
  error = "✗",
  installed = "✓",
  outdated = "↑",
  available = "·",
  disabled = "○",
}
local ICON_HL = {
  installing = "DevDocsProgress",
  error = "DevDocsError",
  installed = "DevDocsInstalled",
  outdated = "DevDocsOutdated",
  available = "DevDocsDim",
  disabled = "DevDocsDim",
}

--- "18.1 MB", "958 kB", "2.3 GB"
--- @param bytes number|nil
--- @return string
function M.size(bytes)
  if not bytes or bytes <= 0 then
    return ""
  end
  if bytes >= 1e9 then
    return ("%.1f GB"):format(bytes / 1e9)
  elseif bytes >= 1e6 then
    return ("%.1f MB"):format(bytes / 1e6)
  end
  return ("%d kB"):format(math.floor(bytes / 1e3))
end

--- @param s string
--- @param width integer display cells
--- @return string padded or truncated with …
function M.cell(s, width)
  s = s or ""
  local w = vim.fn.strdisplaywidth(s)
  if w > width then
    local n = vim.fn.strchars(s)
    local cut = vim.fn.strcharpart(s, 0, n)
    while n > 0 and vim.fn.strdisplaywidth(cut) > width - 1 do
      n = n - 1
      cut = vim.fn.strcharpart(s, 0, n)
    end
    cut = cut .. "…"
    return cut .. string.rep(" ", width - vim.fn.strdisplaywidth(cut))
  end
  return s .. string.rep(" ", width - w)
end

--- A 10-cell progress bar.
--- @param p number 0..1
--- @return string
function M.bar(p)
  local n = math.floor(math.max(0, math.min(1, p)) * 10 + 0.5)
  return string.rep("█", n) .. string.rep("░", 10 - n)
end

--- The note column: what is happening or what pressing i/u would do.
--- @param row DevDocsListRow
--- @return string
function M.note(row)
  if row.status == "installing" then
    local j = row.job
    local stage = j.stage == "queued" and "queued" or j.stage
    if j.err then
      return ("%s  %s"):format(stage, j.err)
    end
    return ("%s %3d%% %s"):format(stage, math.floor((j.progress or 0) * 100), M.bar(j.progress or 0))
  elseif row.status == "error" then
    return "failed: " .. tostring(row.job and row.job.err or "?")
  elseif row.status == "outdated" then
    return "update available (u)"
  elseif row.status == "disabled" then
    return "disabled (e enables)"
  elseif row.status == "installed" then
    local m = row.meta or {}
    local when = m.installed_at and os.date("%Y-%m-%d", m.installed_at) or ""
    local pages = m.page_count and (m.page_count .. " pages") or ""
    return vim.trim(pages .. "  " .. when)
  elseif row.versions and row.versions > 1 then
    return ("+%d versions (Tab)"):format(row.versions - 1)
  end
  return ""
end

--- Column widths for a window width.
--- @param width integer
--- @return { name: integer, version: integer, size: integer, note: integer }
function M.columns(width)
  local name = math.max(12, math.min(28, math.floor(width * 0.3)))
  local version = 10
  local size = 9
  local note = math.max(8, width - 4 - name - 1 - version - 1 - size - 1)
  return { name = name, version = version, size = size, note = note }
end

--- @param state DevDocsListState
--- @return { lines: string[], spans: table[], regions: table[], rows: DevDocsListRow[] }
function M.render(state)
  local lines, spans, regions = {}, {}, {}
  local width = math.max(40, state.width)
  local c = model.counts(state)

  local status = ("%d installed · %d available"):format(c.installed, c.available)
  if c.outdated > 0 then
    status = status .. (" · %d outdated"):format(c.outdated)
  end
  if c.installing > 0 then
    status = status .. (" · %d installing"):format(c.installing)
  end
  if state.loading then
    status = "loading the docs list…"
  elseif state.error then
    status = state.error
  end
  local right = ("sort: %s"):format(state.sort)
  if state.filter ~= "" then
    right = ("filter: %s  %s"):format(state.filter, right)
  end
  local left = " DevDocs  " .. status
  local pad = width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right) - 1
  lines[1] = left .. string.rep(" ", math.max(1, pad)) .. right
  spans[#spans + 1] = { row = 1, col_start = 0, col_end = #" DevDocs ", hl = "DevDocsHeader" }
  if state.error then
    spans[#spans + 1] = { row = 1, col_start = #" DevDocs  ", col_end = #left, hl = "DevDocsError" }
  end
  lines[2] = M.cell(
    " i install  X uninstall  m mark  D prune  u update  e enable  ⏎ open  Tab versions  / filter  s sort  ? help  q",
    width
  )
  spans[#spans + 1] = { row = 2, col_start = 0, col_end = #lines[2], hl = "DevDocsDim" }
  lines[3] = string.rep("─", width)
  spans[#spans + 1] = { row = 3, col_start = 0, col_end = #lines[3], hl = "DevDocsDim" }

  local rows = model.rows(state)
  local cols = M.columns(width)
  local last = math.min(#rows, state.top + math.max(1, state.height) - 1)
  if #rows == 0 then
    local msg = state.loading and ""
      or (
        state.filter ~= "" and ("  nothing matches %q"):format(state.filter)
        or "  no docs known yet; r fetches the list"
      )
    lines[#lines + 1] = msg
    return { lines = lines, spans = spans, regions = regions, rows = rows }
  end
  for i = state.top, last do
    local row = rows[i]
    local line_no = #lines + 1
    if row.kind == "group" then
      local text = ("▾ %s (%d)"):format(row.label, row.count)
      lines[line_no] = M.cell(text, width)
      spans[#spans + 1] = { row = line_no, col_start = 0, col_end = #text, hl = "DevDocsHeader" }
    else
      local icon = ICON[row.status] or "·"
      local doc = row.doc or {}
      local name = doc.name or row.slug
      local version = doc.version or ""
      if version == "" then
        version = "current"
      end
      local parts = {
        "  " .. icon .. " ",
        M.cell(name, cols.name),
        " ",
        M.cell(version, cols.version),
        " ",
        M.cell(M.size(doc.db_size), cols.size),
        " ",
        M.cell(M.note(row), cols.note),
      }
      local line = table.concat(parts)
      lines[line_no] = line
      spans[#spans + 1] =
        { row = line_no, col_start = 2, col_end = 2 + #icon, hl = ICON_HL[row.status] or "DevDocsDim" }
      if row.status == "disabled" or row.status == "available" then
        spans[#spans + 1] = { row = line_no, col_start = 2 + #icon + 1, col_end = #line, hl = "DevDocsDim" }
      elseif row.status == "installing" then
        local note_start = #line - #parts[8]
        spans[#spans + 1] = { row = line_no, col_start = note_start, col_end = #line, hl = "DevDocsProgress" }
      elseif row.status == "error" then
        local note_start = #line - #parts[8]
        spans[#spans + 1] = { row = line_no, col_start = note_start, col_end = #line, hl = "DevDocsError" }
      elseif row.status == "outdated" then
        local note_start = #line - #parts[8]
        spans[#spans + 1] = { row = line_no, col_start = note_start, col_end = #line, hl = "DevDocsOutdated" }
      end
      regions[#regions + 1] = { row = line_no, col_start = 0, col_end = #line, kind = "doc", id = i }
    end
  end
  return { lines = lines, spans = spans, regions = regions, rows = rows }
end

--- Buffer line (1-based) of the cursor row, for the window cursor.
--- @param state DevDocsListState
--- @return integer
function M.cursor_line(state)
  return M.HEADER_LINES + (state.cursor - state.top) + 1
end

M.HELP = {
  "DevDocs manager keys",
  "",
  "  j/k, ↑/↓, gg/G, <C-d>/<C-u>, PgUp/PgDn   move",
  "  }/{          next / previous group",
  "  <Tab>        expand or collapse the versions of a doc",
  "  i            install the doc under the cursor (or the version shown)",
  "  X            uninstall it (asks first)",
  "  u            update it;  U updates every outdated doc",
  "  e            enable / disable it for lookups and search",
  "  <CR>         open the doc in the viewer;  o opens it on devdocs.io",
  "  /            filter (type, <Esc> clears, <CR> keeps);  s toggles name/size sort",
  "  r            refresh the docs list from devdocs.io",
  "  A            install every doc (asks first)",
  "",
  "  m            mark / unmark the doc (or every version of a language), move down",
  "  V … m        mark every doc in a visual selection (again: unmark)",
  "  M            clear every mark",
  "  X            with marks: delete every marked doc (asks first, lists them)",
  "  V … X, V … d delete the installed docs in a visual selection (asks first)",
  "  D            delete every installed version of this language but the current",
  "  gD           the same for every language (:DevDocs prune)",
  "  ?            this help;  q closes",
}

return M

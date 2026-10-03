--- List manager renderer: state -> { lines, spans, regions }. Pure.
--- Header lines are fixed; only the visible window of rows is emitted so a
--- list of 800 docs scrolls without moving the header. Byte columns
--- throughout, which is what extmarks and getmousepos() use.
local model = require "devdocs.ui.model"
local selection = require "devdocs.ui.selection"

local M = {}

M.HEADER_LINES = 4

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

--- Notes column: what is happening, or what a key would do.
--- @param row DevDocsListRow
--- @return string
function M.note(row)
  if row.kind == "lang" then
    local children = row.children or {}
    if row.status ~= "installed" and row.status ~= "available" then
      for _, c in ipairs(children) do
        if c.status == row.status then
          return M.note(c)
        end
      end
    end
    -- collapsed: say there is more to see, unless every version is installed
    -- (the Version column already says "N installed" then)
    if not row.expanded and #children > 1 and (row.installed_count or 0) < #children then
      return ("%d versions"):format(#children)
    end
    return ""
  end
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
  end
  return ""
end

--- "3.12" for a versioned slug; "22.2.1 (current)" for the unversioned one,
--- which DevDocs keeps at the latest release.
local function version_of(row)
  local doc = row.doc or {}
  if (doc.version or "") ~= "" then
    return doc.version
  end
  local release = doc.release or ""
  if release == "" then
    release = row.meta and row.meta.release or ""
  end
  return release ~= "" and (release .. " (current)") or "current"
end

--- Version column. A language shows its installed version, "N installed"
--- when there are several, or its newest version when none is.
--- @param row DevDocsListRow
--- @return string
function M.version(row)
  if row.kind ~= "lang" then
    return version_of(row)
  end
  if row.installed_count and row.installed_count > 1 then
    return ("%d installed"):format(row.installed_count)
  end
  for _, c in ipairs(row.children) do
    if c.meta then
      return version_of(c)
    end
  end
  return version_of(row.children[1])
end

--- Released column: when this version of the docs was released. Exact
--- dates come from state.release_dates; otherwise DevDocs' last update of the
--- docs (manifest mtime) stands in, marked ≈. A language shows its target's.
--- @param state DevDocsListState
--- @param row DevDocsListRow
--- @return string
function M.released(state, row)
  local r = model.target(row)
  if not r then
    return ""
  end
  local known = (state.release_dates or {})[r.slug]
  if known and known.date then
    return (known.exact and "" or "≈") .. known.date
  end
  local mtime = r.doc and r.doc.mtime or 0
  if mtime > 0 then
    return "≈" .. os.date("!%Y-%m-%d", mtime)
  end
  return ""
end

--- Mark column: ● marked (installed or not); on a language ● when every
--- version `m` on it would mark is marked (selection.mark_slugs: its shown
--- installed versions, else its newest shown one), ◐ when only some of its
--- versions are.
--- @param state DevDocsListState
--- @param row DevDocsListRow
--- @return string
function M.mark(state, row)
  local marked = state.marked or {}
  if row.kind ~= "lang" then
    return marked[row.slug] and "●" or ""
  end
  local pool = selection.mark_slugs(row)
  local n, any = 0, false
  for _, c in ipairs(row.children) do
    any = any or marked[c.slug] == true
  end
  for _, slug in ipairs(pool) do
    n = n + (marked[slug] and 1 or 0)
  end
  if n > 0 and n == #pool then
    return "●"
  end
  return any and "◐" or ""
end

local function size_of(row)
  if row.kind == "lang" then
    return row.installed_count > 0 and row.installed_size or row.size_hint
  end
  return (row.meta and row.meta.db_size) or (row.doc and row.doc.db_size)
end

local function pages_of(row)
  if row.kind ~= "lang" then
    return row.meta and row.meta.page_count
  end
  local n = 0
  for _, c in ipairs(row.children) do
    n = n + (c.meta and c.meta.page_count or 0)
  end
  return n > 0 and n or nil
end

--- Name column: chevron + name for a language, tree glyph + slug for a version.
local function name_of(row, last)
  if row.kind == "lang" then
    local chevron = "  "
    if #row.children > 1 then
      chevron = row.expanded and "▾ " or "▸ "
    end
    return chevron .. row.name
  end
  return (last and "  └ " or "  ├ ") .. row.slug
end

--- Column widths and display offsets for a window width. Every cell goes
--- through M.cell, so the offsets hold whatever glyphs a row carries.
--- @param width integer
--- @return table { mark, icon, name, version, size, released, pages, note: integer, at: table<string, integer> }
function M.columns(width)
  local c = { mark = 2, icon = 2, version = 18, size = 8, released = 11, pages = 5 }
  c.name = math.max(14, math.min(28, math.floor(width * 0.25)))
  local fixed = c.mark + c.icon + c.name + 1 + c.version + 1 + c.size + 1 + c.released + 1 + c.pages + 1
  c.note = math.max(8, width - fixed)
  c.at = { mark = 0, icon = c.mark, name = c.mark + c.icon }
  c.at.version = c.at.name + c.name + 1
  c.at.size = c.at.version + c.version + 1
  c.at.released = c.at.size + c.size + 1
  c.at.pages = c.at.released + c.released + 1
  c.at.note = c.at.pages + c.pages + 1
  return c
end

--- Cells of one line, in column order (separators included).
local function cells(cols, mark, icon, name, version, size, released, pages, note)
  return {
    M.cell(mark, cols.mark),
    M.cell(icon, cols.icon),
    M.cell(name, cols.name),
    " ",
    M.cell(version, cols.version),
    " ",
    M.cell(size, cols.size),
    " ",
    M.cell(released, cols.released),
    " ",
    M.cell(pages, cols.pages),
    " ",
    M.cell(note, cols.note),
  }
end

--- Byte offset where cell `i` starts.
local function offset(parts, i)
  local n = 0
  for k = 1, i - 1 do
    n = n + #parts[k]
  end
  return n
end

local NOTE_HL = { installing = "DevDocsProgress", error = "DevDocsError", outdated = "DevDocsOutdated" }

local function render_row(state, rows, i, cols, line_no, spans)
  local row = rows[i]
  local next_row = rows[i + 1]
  local last = row.kind == "doc" and not (next_row and next_row.kind == "doc" and next_row.base == row.base)
  local released = M.released(state, row)
  local pages = pages_of(row)
  local mark, icon = M.mark(state, row), ICON[row.status] or "·"
  local parts = cells(
    cols,
    mark,
    icon,
    name_of(row, last),
    M.version(row),
    M.size(size_of(row)),
    released,
    pages and tostring(pages) or "",
    M.note(row)
  )
  local line = table.concat(parts)
  if mark ~= "" then
    spans[#spans + 1] = { row = line_no, col_start = 0, col_end = #mark, hl = "DevDocsMark" }
  end
  local icon_at = offset(parts, 2)
  spans[#spans + 1] =
    { row = line_no, col_start = icon_at, col_end = icon_at + #icon, hl = ICON_HL[row.status] or "DevDocsDim" }
  if row.status == "disabled" or row.status == "available" then
    spans[#spans + 1] = { row = line_no, col_start = offset(parts, 3), col_end = #line, hl = "DevDocsDim" }
    return line
  end
  if vim.startswith(released, "≈") then
    local at = offset(parts, 9)
    spans[#spans + 1] = { row = line_no, col_start = at, col_end = at + #parts[9], hl = "DevDocsDim" }
  end
  if NOTE_HL[row.status] then
    spans[#spans + 1] = { row = line_no, col_start = offset(parts, 13), col_end = #line, hl = NOTE_HL[row.status] }
  end
  return line
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
  local status_end = #left
  -- marks survive filter changes, so say they exist even when none is shown
  local nmarked = selection.count(state.marked)
  local marks_at
  if nmarked > 0 then
    left = left .. " · "
    marks_at = #left
    left = left .. ("%d marked"):format(nmarked)
  end
  local pad = width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right) - 1
  lines[1] = left .. string.rep(" ", math.max(1, pad)) .. right
  spans[#spans + 1] = { row = 1, col_start = 0, col_end = #" DevDocs ", hl = "DevDocsHeader" }
  if state.error then
    spans[#spans + 1] = { row = 1, col_start = #" DevDocs  ", col_end = status_end, hl = "DevDocsError" }
  end
  if marks_at then
    spans[#spans + 1] = { row = 1, col_start = marks_at, col_end = #left, hl = "DevDocsMark" }
  end
  lines[2] = M.cell(
    " i install  X delete  m/M mark/clear  S/:w apply  D prune  u update  e enable  ⏎ open  Tab versions  / filter  ? help",
    width
  )
  spans[#spans + 1] = { row = 2, col_start = 0, col_end = #lines[2], hl = "DevDocsDim" }
  local cols = M.columns(width)
  lines[3] = table.concat(cells(cols, "", "", "Name", "Version", "Size", "Released", "Pages", "Notes"))
  spans[#spans + 1] = { row = 3, col_start = 0, col_end = #lines[3], hl = "DevDocsHeader" }
  lines[4] = string.rep("─", width)
  spans[#spans + 1] = { row = 4, col_start = 0, col_end = #lines[4], hl = "DevDocsDim" }

  local rows = model.rows(state)
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
      local line = render_row(state, rows, i, cols, line_no, spans)
      lines[line_no] = line
      regions[#regions + 1] = { row = line_no, col_start = 0, col_end = #line, kind = row.kind, id = i }
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

--- Row index shown on buffer line `line` (1-based), clamped to the rows
--- drawn in the window; nil for a header line or when there are no rows.
--- @param state DevDocsListState
--- @param nrows integer #model.rows(state)
--- @param line integer
--- @return integer|nil
function M.line_to_row(state, nrows, line)
  if nrows <= 0 or line <= M.HEADER_LINES then
    return nil
  end
  local last = math.min(nrows, state.top + math.max(1, state.height) - 1)
  return math.max(state.top, math.min(state.top + line - M.HEADER_LINES - 1, last))
end

--- Row indexes of a visual selection between buffer lines `a` and `b` (in
--- that order). A header endpoint snaps to the first row; a selection made
--- only of header lines selects nothing (nil).
--- @param state DevDocsListState
--- @param nrows integer
--- @param a integer
--- @param b integer
--- @return integer|nil from, integer|nil to
function M.visual_range(state, nrows, a, b)
  if nrows <= 0 or (a <= M.HEADER_LINES and b <= M.HEADER_LINES) then
    return nil
  end
  local first = M.HEADER_LINES + 1
  return M.line_to_row(state, nrows, math.max(a, first)), M.line_to_row(state, nrows, math.max(b, first))
end

-- ---------------------------------------------------------------- plan menu

M.PLAN_FOOTER = " y/⏎ apply   n/q/Esc cancel"

local function signed(sign, bytes)
  local s = M.size(bytes)
  return sign .. (s ~= "" and s or "0 kB")
end

local function wrap(text, width)
  local out, line = {}, ""
  for word in text:gmatch "%S+" do
    if line ~= "" and vim.fn.strdisplaywidth(line .. " " .. word) > width then
      out[#out + 1] = line
      line = "   " .. word
    else
      line = line == "" and (" " .. word) or (line .. " " .. word)
    end
  end
  if line ~= "" then
    out[#out + 1] = line
  end
  return out
end

--- Lines and highlight spans of the apply-marks menu (:w / S): an
--- "Install (N)" group with the disk it takes ("-12.3 MB", DevDocsCost) and
--- an "Uninstall (N)" group with the disk it frees ("+45.6 MB",
--- DevDocsFreed), one line per doc (slug, name and version, size; "?" when
--- unknown), an empty group left out; then `notes` and the key footer.
--- Every line is at most `width` display cells. Pure.
--- @param plan { install: table[], uninstall: table[] } selection.plan()
--- @param sizes table<string, number> slug -> bytes
--- @param width integer
--- @param notes string[]|nil
--- @return string[] lines, table[] spans { row, col_start, col_end, hl }
function M.plan_lines(plan, sizes, width, notes)
  sizes = sizes or {}
  local lines, spans = {}, {}
  local size_w = 9
  local rest = math.max(8, width - 3 - size_w - 2)
  local slug_w = 0
  for _, group in ipairs { plan.install or {}, plan.uninstall or {} } do
    for _, e in ipairs(group) do
      slug_w = math.max(slug_w, vim.fn.strdisplaywidth(e.slug))
    end
  end
  slug_w = math.min(slug_w, math.floor(rest / 2))
  local label_w = rest - slug_w

  local function group(label, entries, sign, hl)
    if #entries == 0 then
      return
    end
    local total = 0
    for _, e in ipairs(entries) do
      total = total + (sizes[e.slug] or 0)
    end
    local left = (" %s (%d)"):format(label, #entries)
    local right = signed(sign, total)
    local pad = math.max(1, width - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right))
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    local line = left .. string.rep(" ", pad) .. right
    lines[#lines + 1] = line
    spans[#spans + 1] = { row = #lines, col_start = 1, col_end = #left, hl = "DevDocsHeader" }
    spans[#spans + 1] = { row = #lines, col_start = #line - #right, col_end = #line, hl = hl }
    for _, e in ipairs(entries) do
      local name = e.version ~= "" and (e.name .. " " .. e.version) or e.name
      local sz = M.size(sizes[e.slug])
      sz = sz ~= "" and sz or "?"
      local item = "   " .. M.cell(e.slug, slug_w) .. " " .. M.cell(name, label_w) .. " "
      item = item .. string.rep(" ", size_w - vim.fn.strdisplaywidth(sz)) .. sz
      lines[#lines + 1] = item
      spans[#spans + 1] = { row = #lines, col_start = #item - #sz, col_end = #item, hl = "DevDocsDim" }
    end
  end
  group("Install", plan.install or {}, "-", "DevDocsCost")
  group("Uninstall", plan.uninstall or {}, "+", "DevDocsFreed")
  if notes and #notes > 0 then
    lines[#lines + 1] = ""
    for _, n in ipairs(notes) do
      for _, l in ipairs(wrap(n, width)) do
        lines[#lines + 1] = l
        spans[#spans + 1] = { row = #lines, col_start = 0, col_end = #l, hl = "DevDocsOutdated" }
      end
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = M.PLAN_FOOTER
  spans[#spans + 1] = { row = #lines, col_start = 0, col_end = #M.PLAN_FOOTER, hl = "DevDocsDim" }
  return lines, spans
end

M.HELP = {
  "DevDocs manager keys",
  "",
  "  j/k, ↑/↓, gg/G, <C-d>/<C-u>, PgUp/PgDn   move",
  "  }/{          next / previous section",
  "  <Tab>        expand (▸) or collapse (▾) a language's versions",
  "  l / h        expand / collapse; h on a version folds its language",
  "  i            install the version under the cursor; on a language,",
  "               its installed current version or else the newest",
  "  X            uninstall it (asks first); on a language, every installed",
  "               version the filter shows",
  "  u            update it (a language: its outdated versions);",
  "               U updates every outdated doc",
  "  e            enable / disable it for lookups and search",
  "  <CR>         open the doc in the viewer;  o opens it on devdocs.io",
  "  /            filter (type, <Esc> clears, <CR> keeps);  s toggles name/size sort",
  "  r            refresh the docs list from devdocs.io",
  "  A            install every doc (asks first)",
  "",
  "  m            mark / unmark the doc, installed or not (a language: its",
  "               shown installed versions, else its newest version)",
  "  V … m        mark every doc in a visual selection (again: unmark)",
  "  M            clear every mark; the status line shows how many are marked",
  "  S, :w        apply the marks: install the marked docs that are not",
  "               installed, uninstall the installed ones (a menu lists both",
  "               with the disk used / freed; y or ⏎ applies, n/q/Esc cancels)",
  "  X            with marks: delete every marked installed doc (asks first,",
  "               lists them and says how many the filter hides; marks",
  "               outlive filters; marks on docs not installed are ignored)",
  "  V … X, V … d delete the installed docs in a visual selection (asks first)",
  "  D            prune this language: keep its newest enabled installed",
  "               version and any version a project pins, delete the rest",
  "  gD           the same for every language (:DevDocs prune)",
  "  ?            this help;  q closes",
  "",
  "Columns",
  "  Version      (current) is DevDocs' rolling latest; a language shows",
  "               its installed version, or how many are installed",
  "  Size         download size; a language sums its installed versions",
  "  Released     when that version of the docs was released;",
  "               ≈ is an estimate from DevDocs' last update of it",
  "  Pages        pages installed",
}

return M

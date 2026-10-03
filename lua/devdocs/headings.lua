--- Headings of markdown lines, for the viewer's n/N (section) and c/C
--- (chapter) moves and for index.section's slice bounds: which lines are
--- headings (fenced code excluded), which level is a page's chapter level,
--- where a move lands, and how a page is cut into the screens of the
--- paginated view. Pure.
local M = {}

--- @class DevDocsHeading
--- @field line integer 1-based
--- @field level integer 1..6

--- ATX heading level of a line: 1-6 for "# x" .. "###### x" in column 1,
--- else 0 (indented, quoted, 7+ hashes, "#include"). Fences not considered.
--- @param line string
--- @return integer
function M.level(line)
  local hashes = line:match "^(#+)%s"
  if hashes and #hashes <= 6 then
    return #hashes
  end
  return 0
end

--- Lines inside fenced code, fence lines included (same rule as
--- viewer.display: ``` or ```` after optional indent opens; only the same
--- fence alone on a line closes; an unclosed fence runs to the end).
--- @param lines string[]
--- @return table<integer, true>
function M.fenced(lines)
  local out, fence = {}, nil
  for i, line in ipairs(lines) do
    local stripped = line:gsub("^%s+", "")
    local f = stripped:match "^(````?)"
    if fence then
      out[i] = true
      if f and stripped:match("^" .. fence .. "%s*$") then
        fence = nil
      end
    elseif f then
      fence = f
      out[i] = true
    end
  end
  return out
end

--- Headings outside fenced code, in line order.
--- @param lines string[]
--- @return DevDocsHeading[]
function M.parse(lines)
  local code, out = M.fenced(lines), {}
  for i, line in ipairs(lines) do
    local level = not code[i] and M.level(line) or 0
    if level > 0 then
      out[#out + 1] = { line = i, level = level }
    end
  end
  return out
end

--- One level-1 pseudo-heading per fenced block of an examples view
--- (index.examples_markdown): its "**caption**" line when the line before
--- the opening fence is one, else the fence line.
--- @param lines string[]
--- @return DevDocsHeading[]
function M.blocks(lines)
  local out, fence = {}, nil
  for i, line in ipairs(lines) do
    local stripped = line:gsub("^%s+", "")
    local f = stripped:match "^(````?)"
    if fence then
      if f and stripped:match("^" .. fence .. "%s*$") then
        fence = nil
      end
    elseif f then
      fence = f
      local caption = i > 1 and lines[i - 1]:match "^%*%*.+%*%*%s*$"
      out[#out + 1] = { line = caption and i - 1 or i, level = 1 }
    end
  end
  return out
end

--- The page's chapter level: ignoring the first heading (the title), the
--- shallowest level that occurs at least twice, else the shallowest level
--- of the rest; a lone heading's own level; nil without headings. Headings
--- at this level or shallower are chapters.
--- @param headings DevDocsHeading[]
--- @return integer|nil
function M.chapter_level(headings)
  if #headings == 0 then
    return nil
  end
  if #headings == 1 then
    return headings[1].level
  end
  local count, shallowest = {}, math.huge
  for i = 2, #headings do
    local l = headings[i].level
    count[l] = (count[l] or 0) + 1
    shallowest = math.min(shallowest, l)
  end
  for l = 1, 6 do
    if (count[l] or 0) >= 2 then
      return l
    end
  end
  return shallowest
end

--- Line to move to: the count-th heading strictly below (dir 1) or above
--- (dir -1) the cursor line, clamped to the farthest one; kind "chapter"
--- only counts headings at the chapter level or shallower. nil when there
--- is none in that direction.
--- @param headings DevDocsHeading[] in line order
--- @param cursor integer 1-based
--- @param dir integer 1 or -1
--- @param kind "section"|"chapter"
--- @param count integer|nil default 1; values < 1 count as 1
--- @return integer|nil
function M.target(headings, cursor, dir, kind, count)
  local max = 6
  if kind == "chapter" then
    max = M.chapter_level(headings)
    if not max then
      return nil
    end
  end
  local hits = {}
  for _, h in ipairs(headings) do
    if h.level <= max and ((dir > 0 and h.line > cursor) or (dir < 0 and h.line < cursor)) then
      hits[#hits + 1] = h.line
    end
  end
  if #hits == 0 then
    return nil
  end
  local n = math.min(math.max(count or 1, 1), #hits)
  return dir > 0 and hits[n] or hits[#hits - n + 1]
end

--- A page of the paginated view shows at least this many non-blank lines
--- under its title; shorter ones are merged with what follows.
M.MIN_BODY = 5

--- @class DevDocsPage
--- @field first integer   1-based page line
--- @field last integer    inclusive; pages tile 1..#lines contiguously

--- @param lines string[]
--- @param first integer
--- @param last integer
--- @return integer
local function non_blank(lines, first, last)
  local n = 0
  for i = first, last do
    if lines[i]:match "%S" then
      n = n + 1
    end
  end
  return n
end

--- Cut a page into the pages of the paginated view. A page starts at every
--- heading outside fences, at every line of opts.breaks (soft: ignored
--- inside fences) and at opts.hard (the entry's own anchor, never merged
--- into the page before it). A unit runs from one start to the line before
--- the next; one with fewer than min_body non-blank lines (its first line
--- excluded when that is a start) is merged with the following units until
--- it has enough, the next one is the hard break, or the lines end. Lines
--- before the first start form a preamble unit that merges forward. The
--- pages tile 1..#lines.
--- @param lines string[]
--- @param opts { breaks?: table<integer, true>, hard?: integer, min_body?: integer }|nil
--- @return DevDocsPage[]
function M.pages(lines, opts)
  opts = opts or {}
  local n = #lines
  if n == 0 then
    return {}
  end
  local min = opts.min_body or M.MIN_BODY
  local code = M.fenced(lines)
  local mark = {}
  for _, h in ipairs(M.parse(lines)) do
    mark[h.line] = true
  end
  for line in pairs(opts.breaks or {}) do
    if line >= 1 and line <= n and not code[line] then
      mark[line] = true
    end
  end
  local hard = opts.hard and opts.hard >= 1 and opts.hard <= n and opts.hard or nil
  if hard then
    mark[hard] = true
  end
  local units = {}
  for line = 1, n do
    if mark[line] then
      units[#units + 1] = { first = line, start = true }
    end
  end
  if #units == 0 or units[1].first ~= 1 then
    table.insert(units, 1, { first = 1, start = false })
  end
  for i, u in ipairs(units) do
    u.last = units[i + 1] and units[i + 1].first - 1 or n
  end
  local pages, i = {}, 1
  while i <= #units do
    local u = units[i]
    local body = non_blank(lines, u.start and u.first + 1 or u.first, u.last)
    local j = i
    while body < min and units[j + 1] and units[j + 1].first ~= hard do
      j = j + 1
      body = body + non_blank(lines, units[j].first, units[j].last)
    end
    pages[#pages + 1] = { first = u.first, last = units[j].last }
    i = j + 1
  end
  return pages
end

--- Index of the page containing a line (clamped into the pages) and the
--- page; nil, nil without pages.
--- @param pages DevDocsPage[]
--- @param line integer
--- @return integer|nil i, DevDocsPage|nil page
function M.page_at(pages, line)
  if #pages == 0 then
    return nil, nil
  end
  for i, p in ipairs(pages) do
    if line <= p.last then
      return i, p
    end
  end
  return #pages, pages[#pages]
end

--- The lines of a page, trailing blank lines trimmed (one line is kept).
--- @param lines string[]
--- @param page DevDocsPage
--- @return string[]
function M.page_lines(lines, page)
  local last = page.last
  while last > page.first and not lines[last]:match "%S" do
    last = last - 1
  end
  return vim.list_slice(lines, page.first, last)
end

--- The n/N targets of the paginated view: the headings plus the first line
--- of every page that is not a heading (as level 6), in line order.
--- @param list DevDocsHeading[]
--- @param pages DevDocsPage[]
--- @return DevDocsHeading[]
function M.stops(list, pages)
  local out, have = {}, {}
  for _, h in ipairs(list) do
    out[#out + 1] = h
    have[h.line] = true
  end
  for _, p in ipairs(pages) do
    if not have[p.first] then
      out[#out + 1] = { line = p.first, level = 6 }
    end
  end
  table.sort(out, function(a, b)
    return a.line < b.line
  end)
  return out
end

return M

--- Headings of markdown lines, for the viewer's n/N (section) and c/C
--- (chapter) moves and for index.section's slice bounds: which lines are
--- headings (fenced code excluded), which level is a page's chapter level,
--- and where a move lands. Pure.
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

return M

--- Rank: scoring of index entries against a symbol or a search query. Pure.
---
--- Lookup of the symbol under the cursor tries several candidate names in
--- order ("std::cout" then "cout"); entries from the buffer's own docs
--- outrank the same name elsewhere (tier bonus). Scores are 0..100 before
--- the tier bonus so tests can reason about them.
local M = {}

M.TIER_BONUS = { [1] = 30, [2] = 10, [3] = 0 }

--- @param s string
--- @return string
function M.normalize(s)
  local n = s:lower():gsub("%(%)$", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return n
end

-- separators that end a qualifier: "std::cout", "os.path.join", "Array.prototype.map", "fs#readFile"
local SEP = "[%.:#/%s%-]"

--- Score how well an entry name matches one query. nil = no match.
--- @param name string
--- @param query string
--- @return number|nil
function M.score_name(name, query)
  if query == "" then
    return nil
  end
  if name == query then
    return 100
  end
  local n, q = M.normalize(name), M.normalize(query)
  if n == q then
    return 95
  end
  -- "join" against "os.path.join()": a qualified entry ending in the query
  local best
  local at = n:find(q, 1, true)
  while at do
    local before = at > 1 and n:sub(at - 1, at - 1) or ""
    local after = n:sub(at + #q, at + #q)
    if (before == "" or before:match(SEP)) and (after == "" or after:match(SEP) or after == "(") then
      local score
      if at + #q > #n or n:sub(at + #q) == "()" then
        -- ends the name: the strongest partial match; shorter qualifiers first
        score = math.max(60, 85 - (at - 1) / 2)
      else
        -- starts or sits inside: "os.path" against "os.path.join()"
        score = math.max(35, 60 - (at - 1) / 2 - (#n - #q) / 10)
      end
      best = math.max(best or 0, score)
    end
    at = n:find(q, at + 1, true)
  end
  if best then
    return best
  end
  -- plain substring, anywhere
  if n:find(q, 1, true) then
    return 30
  end
  -- subsequence fuzzy: every query char in order
  local score, pos, streak = 0, 1, 0
  for i = 1, #q do
    local c = q:sub(i, i)
    local at = n:find(c, pos, true)
    if not at then
      return nil
    end
    streak = (at == pos) and streak + 1 or 0
    score = score + 1 + streak
    pos = at + 1
  end
  return math.min(25, 5 + score / #q * 4)
end

--- @class DevDocsHit
--- @field slug string
--- @field entry DevDocsEntry
--- @field score number
--- @field candidate integer index of the candidate that matched

--- Rank entries from several docs against ordered candidate names.
--- @param candidates string[] most specific first ("std::cout", "cout")
--- @param sources { slug: string, entries: DevDocsEntry[], tier: integer }[]
--- @param opts { limit?: integer, min_score?: number }|nil
--- @return DevDocsHit[]
function M.lookup(candidates, sources, opts)
  opts = opts or {}
  local min_score = opts.min_score or 30
  local best = {}
  for ci, cand in ipairs(candidates) do
    for _, src in ipairs(sources) do
      local bonus = M.TIER_BONUS[src.tier] or 0
      for _, e in ipairs(src.entries) do
        local s = M.score_name(e.name, cand)
        if s and s >= min_score then
          -- earlier candidates are more specific: a hit on them is worth more
          s = s + bonus - (ci - 1) * 5
          local key = src.slug .. "\0" .. e.path .. "\0" .. e.name
          if not best[key] or best[key].score < s then
            best[key] = { slug = src.slug, entry = e, score = s, candidate = ci }
          end
        end
      end
    end
  end
  local hits = vim.tbl_values(best)
  table.sort(hits, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    if #a.entry.name ~= #b.entry.name then
      return #a.entry.name < #b.entry.name
    end
    if a.slug ~= b.slug then
      return a.slug < b.slug
    end
    return a.entry.name < b.entry.name
  end)
  if opts.limit and #hits > opts.limit then
    return vim.list_slice(hits, 1, opts.limit)
  end
  return hits
end

--- True when the top hit is unambiguous enough to open without asking.
--- @param hits DevDocsHit[]
--- @return boolean
function M.decisive(hits)
  if #hits == 0 then
    return false
  end
  if #hits == 1 then
    return true
  end
  local a, b = hits[1], hits[2]
  -- same page (different anchors of one entry are common): open the best
  if a.slug == b.slug and a.entry.path == b.entry.path then
    return true
  end
  return a.score - b.score >= 15
end

return M

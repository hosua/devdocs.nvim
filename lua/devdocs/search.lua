--- Search: full-text search over installed docs with ripgrep, plus the
--- entry-name matches that go on top of it. rg is streamed with --json so
--- the picker can show hits as they arrive; results carry slug + page so
--- the viewer can open them and the browser link can be built.
local config = require "devdocs.config"
local index = require "devdocs.index"
local paths = require "devdocs.paths"
local rank = require "devdocs.rank"
local store = require "devdocs.store"

local M = {}

--- @class DevDocsGrepHit
--- @field slug string
--- @field page string
--- @field line integer
--- @field col integer 1-based byte column of the first submatch
--- @field text string the matched line, trimmed
--- @field priority integer position of the slug in the requested order

--- "@css grid gap" -> "css", "grid gap"; "grid" -> nil, "grid".
--- @param query string
--- @return string|nil slug_filter, string text
function M.parse_query(query)
  local slug, rest = query:match "^@([%w%.%-_~+]+)%s*(.*)$"
  if slug then
    return slug, rest
  end
  return nil, query
end

--- Entry-name hits for a query over the given slugs (synchronous, cached data).
--- @param query string
--- @param slugs string[] ordered, most relevant first
--- @param opts { limit?: integer }|nil
--- @return DevDocsHit[]
function M.entries(query, slugs, opts)
  if query == "" then
    return {}
  end
  local tiers = {}
  for i, slug in ipairs(slugs) do
    tiers[slug] = i == 1 and 1 or 2
  end
  return rank.lookup({ query }, index.sources(slugs, tiers), { limit = (opts or {}).limit or 50, min_score = 20 })
end

--- @param cmd string[]
--- @param slugs string[]
--- @return string[] cmd with one pages dir per installed slug appended
local function with_dirs(cmd, slugs)
  local out = vim.list_slice(cmd)
  for _, slug in ipairs(slugs) do
    if store.is_installed(slug) then
      out[#out + 1] = paths.pages_dir(slug)
    end
  end
  return out
end

--- Run ripgrep over the pages of `slugs`. Results arrive in `cb` once, sorted
--- by slug priority then page then line. Returns the process so a picker can
--- kill a superseded search.
--- @param query string
--- @param slugs string[] ordered, most relevant first
--- @param opts { max_results?: integer, regex?: boolean, rg?: string }|nil
--- @param cb fun(hits: DevDocsGrepHit[], err: string|nil)
--- @return vim.SystemObj|nil
function M.grep(query, slugs, opts, cb)
  opts = opts or {}
  local cfg = config.get()
  local rg = opts.rg or cfg.search.rg
  if query == "" then
    cb({}, nil)
    return nil
  end
  if vim.fn.executable(rg) ~= 1 then
    cb({}, ("%s is not installed"):format(rg))
    return nil
  end
  local max_results = opts.max_results or cfg.search.max_results
  local cmd = {
    rg,
    "--json",
    "--smart-case",
    "--max-count",
    "3",
    "--max-columns",
    "240",
    "--max-columns-preview",
    "--no-messages",
    "-g",
    "*.md",
  }
  if not opts.regex then
    cmd[#cmd + 1] = "--fixed-strings"
  end
  cmd[#cmd + 1] = "-e"
  cmd[#cmd + 1] = query
  local n = #cmd
  cmd = with_dirs(cmd, slugs)
  if #cmd == n then
    cb({}, "none of the requested docs is installed")
    return nil
  end
  local priority = {}
  for i, slug in ipairs(slugs) do
    priority[slug] = i
  end
  local hits, count, buffer = {}, 0, ""
  local function consume(line)
    if count >= max_results then
      return
    end
    local ok, ev = pcall(vim.json.decode, line)
    if not ok or type(ev) ~= "table" or ev.type ~= "match" then
      return
    end
    local d = ev.data
    local file = d.path and d.path.text
    if not file then
      return
    end
    local slug, page = paths.page_from_file(file)
    if not slug or not page then
      return
    end
    local sub = d.submatches and d.submatches[1]
    count = count + 1
    hits[count] = {
      slug = slug,
      page = page,
      line = d.line_number,
      col = sub and (sub.start + 1) or 1,
      text = vim.trim((d.lines and d.lines.text or ""):gsub("\n", "")),
      priority = priority[slug] or #slugs + 1,
    }
  end
  return vim.system(cmd, {
    text = true,
    stdout = function(_, data)
      if not data then
        return
      end
      buffer = buffer .. data
      while true do
        local nl = buffer:find("\n", 1, true)
        if not nl then
          break
        end
        consume(buffer:sub(1, nl - 1))
        buffer = buffer:sub(nl + 1)
      end
    end,
  }, function(res)
    if buffer ~= "" then
      consume(buffer)
    end
    vim.schedule(function()
      -- rg exits 1 when nothing matched, 2 on error (partial results still valid)
      local err
      if res.code == 2 and #hits == 0 then
        err = vim.trim(res.stderr or "")
        err = err ~= "" and err or "ripgrep failed"
      end
      table.sort(hits, function(a, b)
        if a.priority ~= b.priority then
          return a.priority < b.priority
        end
        if a.page ~= b.page then
          return a.page < b.page
        end
        return a.line < b.line
      end)
      cb(hits, err)
    end)
  end)
end

return M

--- Index: reading installed docs for display. Entries of several docs
--- merged for lookup, a page's lines, the slice of a page an entry points
--- at (via anchors.json), the fenced code blocks of a slice (examples), and
--- the breadcrumb shown as a viewer title. Reads files; caches through store.
local headings = require "devdocs.headings"
local paths = require "devdocs.paths"
local store = require "devdocs.store"

local M = {}

--- @param slugs string[]
--- @param tiers table<string, integer>|nil slug -> tier (default 2)
--- @return { slug: string, entries: DevDocsEntry[], names: string[], tier: integer }[]
function M.sources(slugs, tiers)
  local out = {}
  for _, slug in ipairs(slugs) do
    if store.is_installed(slug) then
      out[#out + 1] = {
        slug = slug,
        entries = store.entries(slug),
        names = store.names(slug),
        tier = tiers and tiers[slug] or 2,
      }
    end
  end
  return out
end

--- @param slug string
--- @param path string page path, fragment ignored
--- @return string[]|nil lines, string|nil err
function M.page(slug, path)
  local file = paths.page_file(slug, path)
  local content = store.read_file(file)
  if not content then
    return nil, ("page %s of %s is not on disk (reinstall the doc)"):format(path, slug)
  end
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

--- Heading level of a markdown line (0 when not a heading).
--- @param line string
--- @return integer
local function heading_level(line)
  local hashes = line:match "^(#+)%s"
  return hashes and #hashes or 0
end

--- A definition-list term line ("**os.path.join(path)**") at the given indent.
local function is_term(line)
  return line:match "^%s*%*%*.+%*%*%s*$" ~= nil
end

--- The slice of a page an entry points at.
--- With a fragment: from the anchor line to the next heading of the same or a
--- higher level (or, when the anchor is a definition term, to the next term
--- at the same indent or any heading). Without: the whole page. Lines in
--- fenced code are never boundaries.
--- @param slug string
--- @param path string "library/os.path#os.path.join"
--- @return string[]|nil lines, integer|nil start 1-based line in the page, string|nil err
function M.section(slug, path)
  local page, frag = paths.split_fragment(path)
  local lines, err = M.page(slug, page)
  if not lines then
    return nil, nil, err
  end
  if not frag or frag == "" then
    return lines, 1
  end
  local anchors = store.anchors(slug)[page] or {}
  local start = anchors[frag]
  if not start or not lines[start] then
    -- unknown fragment: whole page, but say where we would have gone
    return lines, 1
  end
  local code = headings.fenced(lines)
  local function level_at(i)
    return code[i] and 0 or heading_level(lines[i])
  end
  local level = heading_level(lines[start])
  local stop = #lines
  if level > 0 then
    for i = start + 1, #lines do
      local l = level_at(i)
      if l > 0 and l <= level then
        stop = i - 1
        break
      end
    end
  elseif is_term(lines[start]) then
    local indent = #(lines[start]:match "^(%s*)")
    for i = start + 1, #lines do
      local line = lines[i]
      if level_at(i) > 0 then
        stop = i - 1
        break
      end
      if not code[i] and is_term(line) and #(line:match "^(%s*)") <= indent then
        stop = i - 1
        break
      end
    end
  else
    -- an anchor on plain text: until the next heading
    for i = start + 1, #lines do
      if level_at(i) > 0 then
        stop = i - 1
        break
      end
    end
  end
  while stop > start and lines[stop]:match "^%s*$" do
    stop = stop - 1
  end
  return vim.list_slice(lines, start, stop), start
end

--- @class DevDocsCodeBlock
--- @field lang string
--- @field lines string[]
--- @field caption string the last text line before the fence, markdown stripped

--- Fenced code blocks of some markdown lines, in order.
--- @param lines string[]
--- @return DevDocsCodeBlock[]
function M.code_blocks(lines)
  local out, cur, fence = {}, nil, nil
  local last_text = ""
  for _, raw in ipairs(lines) do
    local line = raw:gsub("^%s+", "")
    if cur then
      if line:match("^" .. fence .. "%s*$") then
        out[#out + 1] = cur
        cur, fence = nil, nil
      else
        cur.lines[#cur.lines + 1] = raw
      end
    else
      local f, lang = line:match "^(````?)([%w%+#-]*)%s*$"
      if f then
        fence = f
        cur = { lang = lang or "", lines = {}, caption = last_text, indent = #raw - #line }
      elseif line ~= "" then
        last_text = line:gsub("^#+%s*", ""):gsub("%*%*", ""):gsub("`", "")
      end
    end
  end
  for _, b in ipairs(out) do
    -- pre inside a list keeps the list's indent: strip it so the block reads flat
    if b.indent > 0 then
      local pat = "^" .. string.rep(" ", b.indent)
      for i, l in ipairs(b.lines) do
        b.lines[i] = l:gsub(pat, "")
      end
    end
    b.indent = nil
  end
  return out
end

--- Markdown for the examples of a section: each block with its caption.
--- @param blocks DevDocsCodeBlock[]
--- @return string[]
function M.examples_markdown(blocks)
  local out = {}
  for i, b in ipairs(blocks) do
    if b.caption ~= "" then
      out[#out + 1] = ("**%s**"):format(b.caption)
    end
    out[#out + 1] = "```" .. b.lang
    vim.list_extend(out, b.lines)
    out[#out + 1] = "```"
    if i < #blocks then
      out[#out + 1] = ""
    end
  end
  return out
end

--- First heading of a page, or nil.
--- @param lines string[]
--- @return string|nil
function M.title(lines)
  for _, l in ipairs(lines) do
    local t = l:match "^#+%s+(.-)%s*$"
    if t then
      return (t:gsub("`", ""))
    end
  end
  return nil
end

--- "Python 3.12 › File & Directory Access › os.path.join()"
--- @param slug string
--- @param entry DevDocsEntry|nil
--- @return string
function M.breadcrumb(slug, entry)
  local meta = store.meta(slug) or {}
  local parts =
    { (meta.name or slug) .. ((meta.doc_version and meta.doc_version ~= "") and (" " .. meta.doc_version) or "") }
  if entry then
    if entry.type and entry.type ~= "" then
      parts[#parts + 1] = entry.type
    end
    parts[#parts + 1] = entry.name
  end
  return table.concat(parts, " › ")
end

--- The entry of `slug` whose path is exactly `path`, else the first sharing its page.
--- @param slug string
--- @param path string
--- @return DevDocsEntry|nil
function M.entry_for_path(slug, path)
  local page = paths.split_fragment(path)
  local same_page
  for _, e in ipairs(store.entries(slug)) do
    if e.path == path then
      return e
    end
    if not same_page and paths.split_fragment(e.path) == page then
      same_page = e
    end
  end
  return same_page
end

return M

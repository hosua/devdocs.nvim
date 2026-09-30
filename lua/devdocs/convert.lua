--- Convert: devdocs' normalized HTML -> markdown lines + anchors. Pure.
---
--- devdocs runs every doc through its own filters, so the HTML is small and
--- regular: h1-h6 with ids, <pre data-language>, plain lists, tables, <dl>
--- for API signatures, relative <a href> between pages. This is a
--- single-pass tag walker, not a DOM: no treesitter, no external tool, and
--- it runs inside a child `nvim --headless -l` (scripts/convert_doc.lua) so a
--- 40 MB doc never blocks the editor.
---
--- convert.html(html, { slug = "cpp", page = "io/cout" }) returns
---   lines   string[]                 the markdown, one entry per line
---   anchors table<string, integer>   element id -> 1-based line it starts on
---
--- Links to other pages become devdocs://<slug>/<page>#<fragment> so the
--- viewer can follow them offline; http(s) links are kept as they are.
local M = {}

-- ---------------------------------------------------------------- entities

local NAMED = {
  amp = "&",
  lt = "<",
  gt = ">",
  quot = '"',
  apos = "'",
  nbsp = " ",
  copy = "©",
  reg = "®",
  trade = "™",
  ndash = "–",
  mdash = "—",
  hellip = "…",
  laquo = "«",
  raquo = "»",
  lsquo = "‘",
  rsquo = "’",
  ldquo = "“",
  rdquo = "”",
  larr = "←",
  rarr = "→",
  uarr = "↑",
  darr = "↓",
  harr = "↔",
  times = "×",
  middot = "·",
  bull = "•",
  deg = "°",
  para = "¶",
  sect = "§",
  ne = "≠",
  le = "≤",
  ge = "≥",
  minus = "−",
  plusmn = "±",
  infin = "∞",
  ensp = " ",
  emsp = " ",
  thinsp = " ",
  zwnj = "",
  zwj = "",
  shy = "",
}

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

--- @param s string
--- @return string
function M.decode_entities(s)
  if not s:find("&", 1, true) then
    return s
  end
  return (
    s:gsub("&(#?[%w]+);", function(ent)
      if ent:sub(1, 2):lower() == "#x" then
        local n = tonumber(ent:sub(3), 16)
        return n and utf8_char(n) or ("&" .. ent .. ";")
      elseif ent:sub(1, 1) == "#" then
        local n = tonumber(ent:sub(2))
        return n and utf8_char(n) or ("&" .. ent .. ";")
      end
      return NAMED[ent] or ("&" .. ent .. ";")
    end)
  )
end

-- ---------------------------------------------------------------- attributes / urls

--- @param raw string the text between the tag name and '>'
--- @param name string
--- @return string|nil
function M.attr(raw, name)
  if raw == "" then
    return nil
  end
  local n = vim.pesc(name)
  local v = raw:match("[%s]" .. n .. '%s*=%s*"([^"]*)"') or raw:match("[%s]" .. n .. "%s*=%s*'([^']*)'")
  if not v then
    v = raw:match("[%s]" .. n .. "%s*=%s*([^%s\"'>]+)")
  end
  return v and M.decode_entities(v) or nil
end

--- Resolve a relative page href against the current page's directory:
--- page "io/cout", href "../header/iostream" -> "header/iostream".
--- @param page string
--- @param href string
--- @return string
function M.resolve(page, href)
  local dir = page:match "^(.*)/[^/]*$" or ""
  local parts = {}
  if dir ~= "" then
    for seg in vim.gsplit(dir, "/", { plain = true }) do
      parts[#parts + 1] = seg
    end
  end
  for seg in vim.gsplit(href, "/", { plain = true }) do
    if seg == ".." then
      parts[#parts] = nil
    elseif seg ~= "." and seg ~= "" then
      parts[#parts + 1] = seg
    end
  end
  return table.concat(parts, "/")
end

--- @param href string
--- @param ctx { slug: string, page: string }
--- @return string
function M.link(href, ctx)
  if href:match "^%a[%w+.-]*:" or href:sub(1, 2) == "//" then
    return href
  end
  if href:sub(1, 1) == "#" then
    return ("devdocs://%s/%s%s"):format(ctx.slug, ctx.page, href)
  end
  local path, frag = href:match "^([^#]*)(#?.*)$"
  if path:sub(1, 1) == "/" then
    path = path:sub(2)
  else
    path = M.resolve(ctx.page, path)
  end
  return ("devdocs://%s/%s%s"):format(ctx.slug, path, frag)
end

-- ---------------------------------------------------------------- tokenizer

local RAW = { pre = true, script = true, style = true, textarea = true }

--- Iterate over tokens: { "text", s } | { "open", name, attrs, selfclosing } | { "close", name }.
--- Raw elements (<pre>...) yield one "raw" token: { "raw", name, attrs, inner }.
--- @param html string
--- @return fun(): table|nil
function M.tokens(html)
  local pos, len = 1, #html
  return function()
    if pos > len then
      return nil
    end
    local lt = html:find("<", pos, true)
    if not lt then
      local s = html:sub(pos)
      pos = len + 1
      return { "text", s }
    end
    if lt > pos then
      local s = html:sub(pos, lt - 1)
      pos = lt
      return { "text", s }
    end
    -- comment
    if html:sub(lt, lt + 3) == "<!--" then
      local e = html:find("-->", lt + 4, true)
      pos = (e or len) + 3
      return { "text", "" }
    end
    -- doctype / processing instruction
    if html:sub(lt + 1, lt + 1) == "!" or html:sub(lt + 1, lt + 1) == "?" then
      local e = html:find(">", lt, true)
      pos = (e or len) + 1
      return { "text", "" }
    end
    local close, name, attrs, selfc, e = html:match("^<(/?)([%w:%-]+)(.-)(/?)>()", lt)
    if not name then
      pos = lt + 1
      return { "text", "<" }
    end
    pos = e
    name = name:lower()
    if close == "/" then
      return { "close", name }
    end
    if RAW[name] and selfc ~= "/" then
      local s, f = html:find("</" .. name .. "%s*>", pos)
      local inner = html:sub(pos, (s or len + 1) - 1)
      pos = (f or len) + 1
      return { "raw", name, attrs, inner }
    end
    return { "open", name, attrs, selfc == "/" }
  end
end

-- ---------------------------------------------------------------- writer

local BLOCK = {
  p = true,
  div = true,
  section = true,
  article = true,
  header = true,
  footer = true,
  main = true,
  aside = true,
  nav = true,
  figure = true,
  figcaption = true,
  details = true,
  summary = true,
  address = true,
  form = true,
  fieldset = true,
  center = true,
  hr = true,
}
local HEADING = { h1 = 1, h2 = 2, h3 = 3, h4 = 4, h5 = 5, h6 = 6 }
local SKIP = { script = true, style = true, svg = true, noscript = true, template = true, iframe = true }

local Writer = {}
Writer.__index = Writer

local function new_writer(ctx)
  return setmetatable({
    ctx = ctx,
    lines = {},
    anchors = {},
    buf = {}, -- inline pieces of the paragraph being built
    prefix = {}, -- per-line prefixes (blockquote, list indent)
    lists = {}, -- stack of { kind = "ul"|"ol", n = counter }
    pending_marker = nil, -- list marker to put in front of the next flushed paragraph
    tables = {}, -- stack of table builders
    dt = 0,
    skip = 0,
    inline = {}, -- stack of inline wrappers to close: "**", "*", "`", link table
    code_depth = 0,
    inline_block = 0, -- >0 while inside <dt>/<summary>: block tags act as spaces
    trim_next = false,
    last_blank = true,
  }, Writer)
end

function Writer:prefix_str()
  return table.concat(self.prefix)
end

function Writer:emit(line)
  self.lines[#self.lines + 1] = line
  -- a line holding only blockquote markers counts as blank
  self.last_blank = line:match "^[>%s]*$" ~= nil
end

--- Ensure a blank separator line (with any blockquote prefix).
function Writer:blank()
  if #self.lines == 0 or self.last_blank then
    return
  end
  local p = self:prefix_str():gsub("%s+$", "")
  self:emit(p)
end

--- Current paragraph text, whitespace collapsed.
function Writer:paragraph_text()
  local s = table.concat(self.buf)
  s = s:gsub("[ \t\r\n]+", " ")
  s = s:gsub("^ ", ""):gsub(" $", "")
  -- inline wrappers leave "** **"-style empties behind; drop them
  s = s:gsub("%*%*%s*%*%*", ""):gsub("`%s*`", "")
  s = s:gsub("[ \t\r\n]+", " ")
  return s
end

--- Write the pending paragraph as one line (or a few, on <br>).
function Writer:flush()
  local text = self:paragraph_text()
  self.buf = {}
  if text == "" then
    if self.pending_marker then
      -- an empty <li>: still emit the marker so numbering stays right
      self:emit(self:prefix_str() .. self.pending_marker)
      self.pending_marker = nil
    end
    return
  end
  local first = true
  for part in vim.gsplit(text, "\0", { plain = true }) do
    part = part:gsub("^ ", ""):gsub(" $", "")
    local p = self:prefix_str()
    if first and self.pending_marker then
      p = p .. self.pending_marker
      self.pending_marker = nil
    elseif #self.lists > 0 then
      p = p .. "  "
    end
    if part ~= "" or not first then
      self:emit(p .. part)
    end
    first = false
  end
end

--- Drop trailing whitespace from the paragraph buffer (before closing a wrapper).
--- @return boolean trimmed whether any whitespace was removed
function Writer:trim_tail()
  local trimmed = false
  while #self.buf > 0 do
    local piece = self.buf[#self.buf]
    local last = piece:gsub("[ \t\r\n]+$", "")
    trimmed = trimmed or last ~= piece
    if last ~= "" then
      self.buf[#self.buf] = last
      return trimmed
    end
    self.buf[#self.buf] = nil
  end
  return trimmed
end

--- Close an inline wrapper; whitespace that was trimmed inside moves after it.
function Writer:unwrap(mark)
  local trimmed = self:trim_tail()
  self.buf[#self.buf + 1] = mark
  self.trim_next = false
  if trimmed then
    self.buf[#self.buf + 1] = " "
  end
end

--- Open an inline wrapper: text right after it has its leading whitespace dropped.
function Writer:wrap(mark)
  self.buf[#self.buf + 1] = mark
  self.trim_next = true
end

function Writer:anchor(id)
  if id and id ~= "" and not self.anchors[id] then
    local line = #self.lines + 1
    if #self.buf > 0 and self:paragraph_text() ~= "" then
      line = #self.lines + 1
    end
    self.anchors[id] = line
  end
end

function Writer:text(s)
  if self.skip > 0 then
    return
  end
  if #self.tables > 0 then
    self.tables[#self.tables]:text(s)
    return
  end
  if self.trim_next then
    s = s:gsub("^[ \t\r\n]+", "")
    if s == "" then
      return
    end
    self.trim_next = false
  end
  self.buf[#self.buf + 1] = M.decode_entities(s)
end

function Writer:fence(inner, lang)
  local code = M.decode_entities(inner):gsub("\r\n", "\n"):gsub("^\n+", ""):gsub("%s+$", "")
  -- pre inside a list item: keep it under the item
  self:flush()
  self:blank()
  local p = self:prefix_str() .. (#self.lists > 0 and "  " or "")
  local fence = code:find("```", 1, true) and "````" or "```"
  self:emit(p .. fence .. (lang or ""))
  for line in vim.gsplit(code, "\n", { plain = true }) do
    self:emit(p .. line)
  end
  self:emit(p .. fence)
  self:blank()
end

--- Language for a <pre> from data-language / class="language-x" / class="lang-x".
--- @param attrs string
--- @return string
function M.code_lang(attrs)
  local lang = M.attr(attrs, "data-language")
  if not lang then
    local class = M.attr(attrs, "class") or ""
    lang = class:match "language%-([%w%+#-]+)" or class:match "lang%-([%w%+#-]+)"
  end
  return lang or ""
end

-- ---------------------------------------------------------------- tables

local Table = {}
Table.__index = Table

local function new_table(attrs)
  return setmetatable({
    rows = {},
    row = nil,
    cell = nil,
    header_rows = 0,
    dcl = (M.attr(attrs, "class") or ""):find "t%-dcl" ~= nil, -- cppreference declaration table
    pres = {},
  }, Table)
end

function Table:text(s)
  if self.cell then
    self.cell[#self.cell + 1] = M.decode_entities(s)
  end
end

function Table:cell_text(cell)
  local s = table.concat(cell):gsub("[ \t\r\n]+", " "):gsub("^ ", ""):gsub(" $", "")
  return (s:gsub("|", "\\|"))
end

--- @return string[] lines
function Table:render()
  local rows = {}
  for _, r in ipairs(self.rows) do
    local cells = {}
    for _, c in ipairs(r.cells) do
      cells[#cells + 1] = self:cell_text(c)
    end
    if #cells > 0 then
      rows[#rows + 1] = { cells = cells, th = r.th }
    end
  end
  if #rows == 0 then
    return {}
  end
  local ncol = 0
  for _, r in ipairs(rows) do
    ncol = math.max(ncol, #r.cells)
  end
  local widths = {}
  for c = 1, ncol do
    widths[c] = 3
    for _, r in ipairs(rows) do
      widths[c] = math.max(widths[c], vim.fn.strdisplaywidth(r.cells[c] or ""))
    end
  end
  local function fmt(cells)
    local out = {}
    for c = 1, ncol do
      local v = cells[c] or ""
      out[c] = v .. string.rep(" ", widths[c] - vim.fn.strdisplaywidth(v))
    end
    return "| " .. table.concat(out, " | ") .. " |"
  end
  local out = { fmt(rows[1].cells) }
  local sep = {}
  for c = 1, ncol do
    sep[c] = string.rep("-", widths[c])
  end
  out[2] = "| " .. table.concat(sep, " | ") .. " |"
  for i = 2, #rows do
    out[#out + 1] = fmt(rows[i].cells)
  end
  return out
end

-- ---------------------------------------------------------------- element handlers

function Writer:open(name, attrs, selfclosing)
  if self.skip > 0 then
    if SKIP[name] and not selfclosing then
      self.skip = self.skip + 1
    end
    return
  end
  if SKIP[name] then
    if not selfclosing then
      self.skip = self.skip + 1
    end
    return
  end
  local id = M.attr(attrs, "id") or (name == "a" and M.attr(attrs, "name")) or nil
  local tbl = self.tables[#self.tables]

  if tbl then
    -- inside a table: only structure and inline code/links matter
    if name == "tr" then
      tbl.row = { cells = {}, th = false }
      tbl.rows[#tbl.rows + 1] = tbl.row
    elseif name == "td" or name == "th" then
      if not tbl.row then
        tbl.row = { cells = {}, th = false }
        tbl.rows[#tbl.rows + 1] = tbl.row
      end
      tbl.cell = {}
      tbl.row.cells[#tbl.row.cells + 1] = tbl.cell
      if name == "th" then
        tbl.row.th = true
      end
    elseif name == "code" and tbl.cell then
      tbl.cell[#tbl.cell + 1] = "`"
    elseif name == "br" and tbl.cell then
      tbl.cell[#tbl.cell + 1] = " "
    elseif name == "table" then
      -- nested table: flatten into the current cell
      self.tables[#self.tables + 1] = new_table(attrs)
      self.tables[#self.tables].cell = tbl.cell
    end
    if id then
      self.anchors[id] = self.anchors[id] or (#self.lines + 1)
    end
    return
  end

  if HEADING[name] then
    self:flush()
    self:blank()
    self:anchor(id)
    self.buf = {}
    self:wrap(string.rep("#", HEADING[name]) .. " ")
    return
  end
  if id then
    self:anchor(id)
  end
  if name == "table" then
    self:flush()
    self:blank()
    self.tables[#self.tables + 1] = new_table(attrs)
  elseif name == "ul" or name == "ol" then
    self:flush()
    if #self.lists == 0 then
      self:blank()
    end
    self.lists[#self.lists + 1] = { kind = name, n = tonumber(M.attr(attrs, "start")) or 1 }
    if #self.lists > 1 then
      self.prefix[#self.prefix + 1] = "  "
    end
  elseif name == "li" then
    self:flush()
    local l = self.lists[#self.lists]
    if l then
      if l.kind == "ol" then
        self.pending_marker = ("%d. "):format(l.n)
        l.n = l.n + 1
      else
        self.pending_marker = "- "
      end
    end
  elseif name == "dt" then
    self:flush()
    self:blank()
    self.buf = {}
    self:wrap "**"
    self.dt = self.dt + 1
    self.inline_block = self.inline_block + 1
  elseif name == "dd" then
    self:flush()
    self.prefix[#self.prefix + 1] = "  "
  elseif name == "dl" then
    self:flush()
    self:blank()
  elseif name == "blockquote" then
    self:flush()
    self:blank()
    self.prefix[#self.prefix + 1] = "> "
  elseif name == "br" then
    self.buf[#self.buf + 1] = "\0"
  elseif name == "hr" then
    self:flush()
    self:blank()
    self:emit(self:prefix_str() .. "---")
    self:blank()
  elseif name == "img" then
    local alt = M.attr(attrs, "alt") or ""
    local src = M.attr(attrs, "src") or ""
    self.buf[#self.buf + 1] = ("![%s](%s)"):format(alt, src)
  elseif name == "a" then
    local href = M.attr(attrs, "href")
    if href and href ~= "" then
      if self.code_depth > 0 then
        -- a link inside <code>: close the code span around the link so it renders
        self:trim_tail()
        self.buf[#self.buf + 1] = "`"
      end
      self:wrap "["
      self.inline[#self.inline + 1] = { "a", M.link(href, self.ctx), #self.buf, self.code_depth > 0 }
      if self.code_depth > 0 then
        self.buf[#self.buf + 1] = "`"
      end
    else
      self.inline[#self.inline + 1] = { "none" }
    end
  elseif name == "code" or name == "kbd" or name == "samp" or name == "var" or name == "tt" then
    if self.code_depth == 0 then
      self:wrap "`"
    end
    self.code_depth = self.code_depth + 1
    self.inline[#self.inline + 1] = { "code" }
  elseif name == "strong" or name == "b" then
    if self.dt == 0 and self.code_depth == 0 then
      self:wrap "**"
      self.inline[#self.inline + 1] = { "**" }
    else
      self.inline[#self.inline + 1] = { "none" }
    end
  elseif name == "em" or name == "i" or name == "cite" or name == "dfn" then
    if self.code_depth == 0 then
      self:wrap "*"
      self.inline[#self.inline + 1] = { "*" }
    else
      self.inline[#self.inline + 1] = { "none" }
    end
  elseif name == "summary" then
    self:flush()
    self:blank()
    self.buf = {}
    self:wrap "**"
    self.inline[#self.inline + 1] = { "summary" }
    self.inline_block = self.inline_block + 1
  elseif BLOCK[name] then
    if self.inline_block > 0 then
      if not self.trim_next then
        self.buf[#self.buf + 1] = " "
      end
      return
    end
    self:flush()
    if name == "p" or name == "figure" or name == "details" then
      self:blank()
    end
  end
end

function Writer:close(name)
  if self.skip > 0 then
    if SKIP[name] then
      self.skip = self.skip - 1
    end
    return
  end
  local tbl = self.tables[#self.tables]
  if tbl then
    if name == "table" then
      self.tables[#self.tables] = nil
      if #self.tables > 0 then
        return -- nested table flattened into its parent cell
      end
      if tbl.dcl then
        -- declaration table: the <pre> blocks were fenced as they came; drop the grid
        for _, pre in ipairs(tbl.pres) do
          self:fence(pre[1], pre[2])
        end
        self:blank()
        return
      end
      self:blank()
      for _, line in ipairs(tbl:render()) do
        self:emit(self:prefix_str() .. line)
      end
      self:blank()
    elseif name == "td" or name == "th" then
      tbl.cell = nil
    elseif name == "tr" then
      tbl.row = nil
    elseif name == "code" and tbl.cell then
      tbl.cell[#tbl.cell + 1] = "`"
    end
    return
  end

  if HEADING[name] then
    self:flush()
    self:blank()
    return
  end
  if name == "ul" or name == "ol" then
    self:flush()
    self.lists[#self.lists] = nil
    if #self.lists > 0 then
      self.prefix[#self.prefix] = nil
    else
      self:blank()
    end
  elseif name == "li" then
    self:flush()
  elseif name == "dt" then
    self:trim_tail()
    self.buf[#self.buf + 1] = "**"
    self.dt = math.max(0, self.dt - 1)
    self.inline_block = math.max(0, self.inline_block - 1)
    self:flush()
  elseif name == "dd" then
    self:flush()
    self.prefix[#self.prefix] = nil
    self:blank()
  elseif name == "dl" then
    self:flush()
    self:blank()
  elseif name == "blockquote" then
    self:flush()
    self.prefix[#self.prefix] = nil
    self:blank()
  elseif name == "a" or name == "code" or name == "kbd" or name == "samp" or name == "var" or name == "tt" then
    local top = self.inline[#self.inline]
    if top and (top[1] == "a" or top[1] == "none" or top[1] == "code") then
      self.inline[#self.inline] = nil
      if top[1] == "a" then
        local text = table.concat(self.buf, "", top[3] + 1)
        if text:match "^[%s`]*$" then
          -- empty link text: drop the bracket, keep nothing
          for i = #self.buf, top[3], -1 do
            self.buf[i] = nil
          end
          if top[4] then
            self.buf[#self.buf + 1] = "`"
          end
        else
          local trimmed = self:trim_tail()
          if top[4] then
            self.buf[#self.buf + 1] = "`"
          end
          self.buf[#self.buf + 1] = ("](%s)"):format(top[2])
          self.trim_next = false
          if top[4] then
            self:wrap "`"
          end
          if trimmed then
            self.buf[#self.buf + 1] = " "
          end
        end
      elseif top[1] == "code" then
        self.code_depth = self.code_depth - 1
        if self.code_depth == 0 then
          self:unwrap "`"
        end
      end
    end
  elseif name == "strong" or name == "b" or name == "em" or name == "i" or name == "cite" or name == "dfn" then
    local top = self.inline[#self.inline]
    if top then
      self.inline[#self.inline] = nil
      if top[1] == "**" or top[1] == "*" then
        self:unwrap(top[1])
      end
    end
  elseif name == "summary" then
    local top = self.inline[#self.inline]
    if top and top[1] == "summary" then
      self.inline[#self.inline] = nil
    end
    self.inline_block = math.max(0, self.inline_block - 1)
    self:trim_tail()
    self.buf[#self.buf + 1] = "**"
    self:flush()
    self:blank()
  elseif BLOCK[name] then
    if self.inline_block > 0 then
      if not self.trim_next then
        self.buf[#self.buf + 1] = " "
      end
      return
    end
    self:flush()
    if name == "p" or name == "figure" or name == "details" then
      self:blank()
    end
  end
end

function Writer:raw(name, attrs, inner)
  if self.skip > 0 or name == "script" or name == "style" then
    return
  end
  local tbl = self.tables[#self.tables]
  if tbl then
    if tbl.dcl then
      tbl.pres[#tbl.pres + 1] = { inner, M.code_lang(attrs) }
    elseif tbl.cell then
      tbl.cell[#tbl.cell + 1] = "`" .. M.decode_entities(inner):gsub("%s+", " ") .. "`"
    end
    return
  end
  if name == "pre" then
    -- <pre><code class="language-x"> nests the language one level down
    local lang = M.code_lang(attrs)
    local code_attrs, body = inner:match "^%s*<code([^>]*)>(.*)</code>%s*$"
    if code_attrs then
      inner = body
      if lang == "" then
        lang = M.code_lang(code_attrs)
      end
    end
    -- strip any remaining inline markup (syntax-highlight spans)
    inner = inner:gsub("<[^>]->", "")
    self:fence(inner, lang)
  else
    self:text(M.decode_entities(inner))
  end
end

-- ---------------------------------------------------------------- entry point

--- @param html string
--- @param ctx { slug: string, page: string }
--- @return string[] lines, table<string, integer> anchors
function M.html(html, ctx)
  local w = new_writer(ctx)
  for tok in M.tokens(html) do
    local kind = tok[1]
    if kind == "text" then
      w:text(tok[2])
    elseif kind == "open" then
      w:open(tok[2], tok[3], tok[4])
    elseif kind == "close" then
      w:close(tok[2])
    elseif kind == "raw" then
      w:raw(tok[2], tok[3], tok[4])
    end
  end
  w:flush()
  -- trim trailing blank lines
  while #w.lines > 0 and w.lines[#w.lines]:match "^[>%s]*$" do
    w.lines[#w.lines] = nil
  end
  -- anchors may point past the end when the element produced no text
  for id, line in pairs(w.anchors) do
    if line > #w.lines then
      w.anchors[id] = math.max(1, #w.lines)
    end
  end
  return w.lines, w.anchors
end

return M

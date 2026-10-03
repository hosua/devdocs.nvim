--- Viewer: shows one doc page (or one page of it at a time, starting at the
--- entry, or only its examples) in a float. Rendering of the header/footer is pure
--- (render()) so it is tested; one viewer is reused while open and keeps a
--- history for following devdocs:// links.
---
--- Keys inside: q/<Esc> close · o browser · y yank url · <CR> follow link
--- · <BS> back · n/N next/previous section · c/C next/previous chapter · e
--- examples · p toggle paginated / whole page · s search this doc · I the
--- index of the doc · ? help
--- The index (mode "index", glossary.lua) shares the float and the history:
--- a doc's types and entries, expanded and filtered in place, an entry
--- opening as a page that <BS> leaves again.
local config = require "devdocs.config"
local float = require "devdocs.ui.float"
local glossary = require "devdocs.ui.glossary"
local glossary_render = require "devdocs.ui.glossary_render"
local headings = require "devdocs.headings"
local index = require "devdocs.index"
local paths = require "devdocs.paths"
local store = require "devdocs.store"

local M = {}

--- @class DevDocsView
--- @field slug string
--- @field path string      page path with optional fragment
--- @field entry DevDocsEntry|nil
--- @field mode "section"|"page"|"examples"|"help"|"index"  "section" is the paginated view
--- @field line integer|nil       line of the shown text to put the cursor on
--- @field top boolean|nil         also scroll that line to the top of the window
--- @field topline integer|nil     first visible line to restore (history entries)
--- @field page_at integer|nil     whole-page line to return to on p / e from the examples
--- @field page_start integer|nil  paginated: first page line of the shown page; nil = the page of the entry's anchor
--- @field under "section"|"page"|"examples"|"index"|nil  help only: the mode under the help screen
--- @field index DevDocsGlossaryState|nil  index only: what is expanded and filtered (path is "", entry the ● mark, line the cursor row)
--- @field view_mode "float"|"split"|"vsplit"|"tab"|nil  window kind override

local hints = require "devdocs.ui.hints"
M.FOOTER = {
  { "⏎", "follow" },
  { "⌫", "back" },
  { "I", "index" },
  { "e", "examples" },
  { "p", "pages", keep = true },
  { "n/N", "section" },
  { "c/C", "chapter" },
  { "s", "search" },
  { "?", "help", keep = true },
  { "q", "close", keep = true },
  -- least used last: a narrow float drops trailing hints, and ? lists them
  { "o", "browser" },
  { "y", "url" },
}

--- The footer hints for a mode: p names the view it switches to, so
--- "paginated" in the whole-page view and "pages" otherwise.
--- @param mode string
--- @return DevDocsHint[]
function M.footer(mode)
  local out = {}
  for _, h in ipairs(M.FOOTER) do
    out[#out + 1] = h[1] == "p" and { "p", mode == "page" and "paginated" or "pages", keep = true } or h
  end
  return out
end

M.HELP = {
  { title = "DevDocs viewer keys" },
  "",
  {
    header = { "Key", "Action" },
    rows = {
      { "q, Esc", "close the viewer" },
      { "o", "open this page on devdocs.io" },
      { "y", "yank (copy) the devdocs.io url" },
      { "Enter (<CR>), double-click", "follow the link under the cursor (devdocs:// links stay in the viewer)" },
      { "Backspace (<BS>), u", "back to the previous view (links, e, p and ? go on the history)" },
      { "e", "only the examples of this entry or page (e again: back)" },
      { "p", "toggle paginated / pages (the whole doc page), keeping your place" },
      { "s", "search inside this doc" },
      { "I", "the index of this doc (I again returns)" },
      {
        "n / N",
        "next / previous section: any heading (3n moves three); paginated, past the page's end it turns the page",
      },
      { "c / C", "next / previous chapter: the page's top-level headings" },
      { "Ctrl-f / Ctrl-b", "scroll a screen down / up" },
      { "Ctrl-d / Ctrl-u", "scroll half a screen down / up" },
      { "j / k", "a line down / up" },
      { "gg / G", "top / bottom of the page" },
      { "/ Enter, ? Enter", "repeat the last search forward / backward (n and N move by section here)" },
      { "?", "this help (Backspace returns)" },
    },
  },
}

--- The help screen's lines and highlight spans, wrapped to `width` cells.
--- @param width integer|nil
--- @return string[] lines, table[] spans
function M.help_lines(width)
  return hints.help(M.HELP, { width = width })
end

--- The page of a view's pages that its cursor line falls on.
--- @param view DevDocsView
--- @return DevDocsPage[]|nil pages, integer|nil i, DevDocsPage|nil page, string[]|nil all, string|nil err
local function shown_page(view)
  local pages, all, err = index.pages(view.slug, view.path)
  if not pages then
    return nil, nil, nil, nil, err
  end
  local i, page = headings.page_at(pages, M.page_line(view))
  return pages, i, page, all, nil
end

--- The lines to show for a view, plus a title. Pure given the page data.
--- Paginated ("section"): the page holding the view's page line, with
--- (i/n) in the title when there are several. Examples: the code blocks of
--- the shown page (the entry's own slice until a page was turned to),
--- falling back to the whole page's.
--- @param view DevDocsView
--- @return string[] lines, string title, string|nil err
function M.render(view)
  local title = index.breadcrumb(view.slug, view.entry)
  local lines, err
  if view.mode == "page" then
    lines, err = index.page(view.slug, view.path)
  elseif view.mode == "section" or view.page_start then
    local pages, i, page, all
    pages, i, page, all, err = shown_page(view)
    if pages and page then
      lines = headings.page_lines(all, page)
      if view.mode == "section" and #pages > 1 then
        title = ("%s (%d/%d)"):format(title, i, #pages)
      end
    end
  else
    local _
    lines, _, err = index.section(view.slug, view.path)
  end
  if not lines then
    return { "", "  " .. tostring(err), "", "  Press q to close." }, title, err
  end
  if view.mode == "examples" then
    local blocks = index.code_blocks(lines)
    if #blocks == 0 then
      local whole = index.page(view.slug, view.path) or {}
      blocks = index.code_blocks(whole)
      if #blocks == 0 then
        return {
          "",
          ("  No examples in %s."):format(view.entry and view.entry.name or view.path),
          "",
          "  o opens the page on devdocs.io, p shows the whole page.",
        },
          title .. " › examples",
          nil
      end
      title = title .. " › examples (whole page)"
    else
      title = title .. " › examples"
    end
    return index.examples_markdown(blocks), title, nil
  end
  return lines, title, nil
end

--- The 1-based page line the paginated view is at: the first line of the
--- page it was turned to, else the entry's anchor, else 1 (no fragment, an
--- unknown anchor or a missing page). Pure given the page data.
--- @param view DevDocsView
--- @return integer
function M.page_line(view)
  return view.page_start or index.anchor(view.slug, view.path) or 1
end

--- A view whose paginated mode has nothing to start at (no fragment or an
--- unknown one, and no page turned to) is the whole page. Returns the view
--- itself unless it has to change.
--- @param view DevDocsView
--- @return DevDocsView
function M.normalize(view)
  if view.mode == "section" and view.page_start == nil and index.anchor(view.slug, view.path) == nil then
    return vim.tbl_extend("force", view, { mode = "page" })
  end
  return view
end

local current
local last = {} -- slug -> the index state it was left in
local last_row = {} -- slug -> the cursor row it was left on
local NS = vim.api.nvim_create_namespace "devdocs_viewer"

--- @class DevDocsLink
--- @field s integer 1-based byte column where the link text starts
--- @field e integer 1-based byte column where it ends (inclusive)
--- @field url string

--- Markdown links shown as their text only (so wrapping follows what is
--- visible), with the targets remembered per line. Lines inside fenced code
--- are left alone. Pure.
--- @param lines string[]
--- @return string[] display, table<integer, DevDocsLink[]> links by 1-based row
function M.display(lines)
  local out, links = {}, {}
  local fence
  for i, line in ipairs(lines) do
    local stripped = line:gsub("^%s+", "")
    local f = stripped:match "^(````?)"
    if fence then
      if f and stripped:match("^" .. fence .. "%s*$") then
        fence = nil
      end
      out[i] = line
    elseif f then
      fence = f
      out[i] = line
    else
      local parts, row, pos, width = {}, {}, 1, 0
      while true do
        local s, e, bang, text, url = line:find("(!?)%[([^%]]*)%]%(([^)]+)%)", pos)
        if not s then
          parts[#parts + 1] = line:sub(pos)
          break
        end
        local before = line:sub(pos, s - 1)
        parts[#parts + 1] = before
        width = width + #before
        parts[#parts + 1] = text
        if bang == "" and text ~= "" then
          row[#row + 1] = { s = width + 1, e = width + #text, url = url }
        end
        width = width + #text
        pos = e + 1
      end
      out[i] = table.concat(parts)
      -- bare urls stay visible and clickable
      for s, url in out[i]:gmatch "()(%a[%w+.-]*://[^%s%)%]]+)" do
        local u = url:gsub("[%.,;:]+$", "")
        row[#row + 1] = { s = s, e = s + #u - 1, url = u }
      end
      if #row > 0 then
        table.sort(row, function(a, b)
          return a.s < b.s
        end)
        links[i] = row
      end
    end
  end
  return out, links
end

--- The link under the cursor on a line, else the first link of the line.
--- @param row_links DevDocsLink[]|nil
--- @param col integer 0-based cursor column
--- @return string|nil url
function M.link_at(row_links, col)
  if not row_links or #row_links == 0 then
    return nil
  end
  for _, l in ipairs(row_links) do
    if col + 1 >= l.s and col + 1 <= l.e then
      return l.url
    end
  end
  return row_links[1].url
end

local function apply_links(buf, links)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for row, list in pairs(links) do
    for _, l in ipairs(list) do
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, row - 1, l.s - 1, { end_col = l.e, hl_group = "DevDocsLink" })
    end
  end
end

local function notify(msg, level)
  vim.notify("devdocs: " .. msg, level or vim.log.levels.INFO)
end

--- @param url string
--- @return string|nil slug, string|nil path
function M.parse_devdocs_url(url)
  local slug, path = url:match "^devdocs://([^/]+)/(.*)$"
  if slug and paths.valid_slug(slug) then
    return slug, path
  end
  return nil
end

--- Cursor on view.line (clamped); with view.topline the scroll position a
--- history entry saved, else with view.top that line at the top of the
--- window like `zt` (the viewer window has 'scrolloff' 0, so it really is
--- the top).
local function place_cursor(win, view, count)
  local line = math.max(1, math.min(view.line or 1, count))
  pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  if view.topline then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview { lnum = line, col = 0, topline = math.max(1, math.min(view.topline, line)) }
    end)
  elseif view.top then
    vim.api.nvim_win_call(win, function()
      vim.cmd "normal! zt"
    end)
  end
end

--- The current view with the cursor line and scroll position it has now, for
--- the history, so <BS> returns to the same place. A copy; the view is not
--- changed.
--- @return DevDocsView
local function snapshot()
  local view = current.view
  if not current.float:valid() then
    return view
  end
  local win = current.float.win
  local cursor = vim.api.nvim_win_get_cursor(win)
  local top = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topline
  end)
  if view.mode == "index" then
    last_row[view.slug] = cursor[1]
  end
  return vim.tbl_extend("force", view, { line = cursor[1], topline = top, top = false })
end

local function push_history()
  current.history[#current.history + 1] = snapshot()
end

-- ---------------------------------------------------------------- index

local trees = {} -- slug -> DevDocsGlossary, dropped when docs change
store.on_invalidate(function()
  trees = {}
end)

--- The index tree of a doc, built once per install.
--- @param slug string
--- @return DevDocsGlossary
local function tree_for(slug)
  if not trees[slug] then
    trees[slug] = glossary.build(slug, store.meta(slug), store.entries(slug))
  end
  return trees[slug]
end

--- Draw the index view of `self` (rows, spans, title, footer, cursor) for
--- the window's current width.
local function draw_index(self)
  local view, f = self.view, self.float
  local tree = tree_for(view.slug)
  local rows = glossary.rows(tree, view.index)
  local lines, spans = { glossary_render.empty(tree) }, {}
  if tree.total > 0 then
    local drawn = glossary_render.render(
      tree,
      rows,
      { width = vim.api.nvim_win_get_width(f.win), current = view.entry, filter = view.index.filter }
    )
    lines, spans = drawn.lines, drawn.spans
  end
  self.rows = rows
  self.links = {}
  -- redrawn on every filter key: keep tens of thousands of old lines out of undo
  vim.bo[f.buf].undolevels = -1
  f:set_lines(lines)
  apply_links(f.buf, {})
  float.highlight(f.buf, NS, spans)
  f:set_title(glossary_render.title(tree, view.index, rows[1].count), glossary_render.FOOTER)
  -- Neovim 0.11 re-applies style = "minimal" (cursorline off) on a float's reconfiguration
  vim.wo[f.win].cursorline = true
  place_cursor(f.win, view, #lines)
end

--- Switch the float between the page and the index look: the index has no
--- markdown, no wrapping or concealing, and a cursor line. Window options,
--- treesitter and the key set follow; nothing happens when the kind is
--- already right.
--- @param kind "page"|"index"
local function apply_kind(self, kind)
  if self.kind == kind then
    return
  end
  local first = self.kind == nil
  self.kind = kind
  local buf, win = self.float.buf, self.float.win
  if kind == "index" then
    pcall(vim.treesitter.stop, buf)
    vim.bo[buf].filetype = ""
    vim.wo[win].conceallevel = 0
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
  elseif not first then
    local cfg = config.get().view
    vim.bo[buf].filetype = "markdown"
    pcall(vim.treesitter.start, buf, "markdown")
    vim.wo[win].conceallevel = cfg.conceal and 2 or 0
    vim.wo[win].wrap = cfg.wrap
    vim.wo[win].cursorline = false
  end
  local old, new = self.keys[first and kind or (kind == "index" and "page" or "index")], self.keys[kind]
  for lhs in pairs(old) do
    if new[lhs] == nil then
      pcall(vim.keymap.del, "n", lhs, { buffer = buf })
    end
  end
  if not first then
    for lhs, fn in pairs(new) do
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
    end
  end
end

--- The buffer-local keys of the page views and of the index, lhs -> fn.
local function key_sets()
  local function act(fn)
    return function()
      fn()
    end
  end
  local common = {
    ["q"] = act(M.close),
    ["<Esc>"] = act(M.close),
    ["o"] = act(M.browser),
    ["y"] = act(M.yank),
    ["<BS>"] = act(M.back),
    ["u"] = act(M.back),
    ["I"] = act(M.index),
    ["?"] = act(M.help),
    ["s"] = act(function()
      local slug = current.view.slug
      M.close()
      vim.schedule(function()
        require("devdocs").search("@" .. slug .. " ")
      end)
    end),
  }
  local page = vim.tbl_extend("error", common, {
    ["<CR>"] = act(M.follow),
    ["<2-LeftMouse>"] = act(M.follow),
    ["e"] = act(function()
      local view = current.view
      if view.mode ~= "examples" then
        M.set_mode "examples"
      else
        -- back to the view e came from: page_at is only set from the whole page
        M.set_mode(view.page_at and "page" or "section")
      end
    end),
    ["p"] = act(M.toggle),
    ["n"] = act(function()
      M.jump("section", 1, vim.v.count1)
    end),
    ["N"] = act(function()
      M.jump("section", -1, vim.v.count1)
    end),
    ["c"] = act(function()
      M.jump("chapter", 1, vim.v.count1)
    end),
    ["C"] = act(function()
      M.jump("chapter", -1, vim.v.count1)
    end),
  })
  local function step(type)
    return act(function()
      M.index_act { type = type }
    end)
  end
  local idx = vim.tbl_extend("error", common, {
    ["<CR>"] = act(function()
      M.index_enter()
    end),
    ["<2-LeftMouse>"] = act(function()
      M.index_enter()
    end),
    ["l"] = act(function()
      M.index_enter "expand"
    end),
    ["h"] = step "collapse",
    ["<Tab>"] = step "toggle",
    ["zR"] = step "expand_all",
    ["zM"] = step "collapse_all",
    ["}"] = step "next_group",
    ["{"] = step "prev_group",
    ["/"] = act(M.index_filter),
    ["d"] = act(M.index_doc),
  })
  return { page = page, index = idx }
end

local function show(view, push)
  local is_index = view.mode == "index"
  local lines, title, display, links = {}, "", {}, {}
  if not is_index then
    local err
    lines, title, err = M.render(view)
    if err then
      notify(err, vim.log.levels.WARN)
    end
    display, links = M.display(lines)
  end
  if view.view_mode and current and current.float:valid() and current.float.mode ~= view.view_mode then
    M.close()
  end
  if current and current.float:valid() then
    if push then
      push_history()
    end
    current.view = view
    apply_kind(current, is_index and "index" or "page")
    if is_index then
      draw_index(current)
    else
      current.links = links
      current.float:set_lines(display)
      apply_links(current.float.buf, links)
      current.float:set_title(title, M.footer(view.mode))
      place_cursor(current.float.win, view, #lines)
    end
  else
    local self = { view = view, history = {}, keys = key_sets(), origin = vim.api.nvim_get_current_buf() }
    self.float = float.open {
      lines = display,
      title = title,
      footer = is_index and glossary_render.FOOTER or M.footer(view.mode),
      filetype = (not is_index) and "markdown" or nil,
      mode = view.view_mode,
      name = ("devdocs://%s/%s"):format(view.slug, view.path),
      keys = self.keys[is_index and "index" or "page"],
      on_close = function()
        if current == self then
          current = nil
        end
      end,
    }
    current = self
    self.links = links
    -- 'scrolloff' would push a `zt` heading down (or center it with 999);
    -- window-local, so the user's other windows keep theirs
    vim.wo[self.float.win].scrolloff = 0
    if is_index then
      apply_kind(self, "index")
      draw_index(self)
    else
      self.kind = "page"
      apply_links(self.float.buf, links)
      if view.line then
        place_cursor(self.float.win, view, #lines)
      end
    end
  end
  if is_index then
    return
  end
  store.push_recent(view.slug, view.path, view.entry and view.entry.name or index.title(lines))
  local hook = config.get().hooks.on_open
  if type(hook) == "function" then
    pcall(hook, view.slug, view.path)
  end
end

--- Open a paginated/page/examples view.
--- @param view DevDocsView
function M.open(view)
  view.mode = view.mode or "section"
  if not store.is_installed(view.slug) then
    notify(("%s is not installed (:DevDocs install %s)"):format(view.slug, view.slug), vim.log.levels.WARN)
    return
  end
  show(M.normalize(view), current ~= nil)
end

function M.close()
  if current then
    current.float:close()
    current = nil
  end
end

--- @return DevDocsView|nil
function M.current_view()
  return current and current.view or nil
end

--- The cursor line and top line of the viewer window, or of the view
--- snapshot a help screen stands over.
--- @param from DevDocsView
--- @return integer|nil cur, integer|nil top
local function window_position(from)
  if from.mode == "help" then
    return from.line, from.topline
  end
  if not current.float:valid() then
    return nil, nil
  end
  local win = current.float.win
  local top = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().topline
  end)
  return vim.api.nvim_win_get_cursor(win)[1], top
end

--- Switch the current view to another mode (p and e). "page" is the whole
--- doc page and "section" the paginated view; the position carries over
--- (the same text stays under the cursor and, when possible, at the same
--- scroll position). Into the examples the page line is remembered for the
--- way back. The view switched from goes on the history (help already put
--- its view there), so <BS> walks back through e and p alike.
--- @param mode "section"|"page"|"examples"
function M.set_mode(mode)
  if not current or current.view.mode == mode then
    return
  end
  local from = current.view
  local src = from.mode == "help" and from.under or from.mode
  local cur, top = window_position(from)
  local v = vim.tbl_extend("force", from, { mode = mode })
  -- a `nil` in tbl_extend's table is no key at all: clear the scroll
  -- position a history entry carried, or place_cursor restores it over `zt`
  v.topline, v.under = nil, nil
  if mode == "page" then
    if src == "section" then
      local _, _, page = shown_page(from)
      local first = page and page.first or 1
      v.line, v.top = first + (cur or 1) - 1, nil
      v.topline = top and first + top - 1 or nil
    elseif from.page_at then
      v.line, v.top = from.page_at, nil
    else
      v.line, v.top = M.page_line(from), true
    end
    v.page_start = nil
  elseif mode == "section" then
    if src == "page" then
      local line = cur or 1
      local pages = index.pages(from.slug, from.path)
      local _, page = headings.page_at(pages or {}, line)
      local first = page and page.first or 1
      v.page_start, v.line, v.top = first, line - first + 1, nil
      v.topline = top and top >= first and top - first + 1 or nil
    else
      -- from the examples: the page the whole-page cursor was on, if any
      if from.page_at then
        local pages = index.pages(from.slug, from.path)
        local _, page = headings.page_at(pages or {}, from.page_at)
        v.page_start = page and page.first or v.page_start
      end
      v.line, v.top = nil, nil
    end
    v.page_at = nil
  else
    -- view.line is a line of the shown text; remember the whole-page one
    -- for the way back
    if src == "page" then
      v.page_at = cur
    end
    v.line, v.top = nil, nil
  end
  show(v, from.mode ~= "help")
end

--- p: toggle between the paginated view and the whole page. From the help
--- screen it acts on the view under it; from the examples it goes to the
--- whole page.
function M.toggle()
  if not current then
    return
  end
  local view = current.view
  local base = view.mode == "help" and view.under or view.mode
  M.set_mode(base == "page" and "section" or "page")
end

--- The page o and y act on: the entry under the cursor in the index (the
--- doc's own page when the cursor is on a type), else the view's page.
--- @return string|nil
local function url_path()
  local view = current.view
  if view.mode ~= "index" then
    return view.path
  end
  local row = current.rows and current.float:valid() and current.rows[vim.api.nvim_win_get_cursor(current.float.win)[1]]
  local e = glossary.target(row)
  return e and e.path or nil
end

function M.browser()
  if not current then
    return
  end
  local url = paths.browser_url(current.view.slug, url_path())
  local ok, err = pcall(vim.ui.open, url)
  if not ok then
    notify("could not open a browser: " .. tostring(err), vim.log.levels.ERROR)
  else
    notify("opened " .. url)
  end
end

function M.yank()
  if not current then
    return
  end
  local url = paths.browser_url(current.view.slug, url_path())
  vim.fn.setreg("+", url)
  vim.fn.setreg('"', url)
  notify("yanked " .. url)
end

function M.follow()
  if not current or not current.float:valid() then
    return
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(current.float.win))
  local url = M.link_at((current.links or {})[row], col)
  if not url then
    notify "no link under the cursor"
    return
  end
  local slug, path = M.parse_devdocs_url(url)
  if slug then
    if not store.is_installed(slug) then
      notify(("%s is not installed; opening on devdocs.io"):format(slug), vim.log.levels.WARN)
      pcall(vim.ui.open, paths.browser_url(slug, path))
      return
    end
    show(M.normalize { slug = slug, path = path, entry = index.entry_for_path(slug, path), mode = "section" }, true)
    return
  end
  local ok = pcall(vim.ui.open, url)
  if not ok then
    notify("could not open " .. url, vim.log.levels.ERROR)
  end
end

function M.back()
  if not current then
    return
  end
  local prev = table.remove(current.history)
  if not prev then
    -- opened from somewhere with its own way back (the manager's <CR>)
    local on_back = current.on_back
    if on_back then
      M.close()
      vim.schedule(on_back)
      return
    end
    notify "no previous page"
    return
  end
  show(prev, false)
end

--- Move to the next (dir 1) or previous (dir -1) heading, count times.
--- kind "section": any heading (paginated: also the start of every page);
--- "chapter": one at the page's chapter level or shallower
--- (headings.chapter_level, of the whole doc page's headings). The target
--- goes to the top of the window and the jump on the jumplist. Paginated:
--- a target outside the shown page turns to the page that holds it, the
--- target at its top (not on the history). Examples view: each example is a
--- section and a chapter. Help: nothing.
--- @param kind "section"|"chapter"
--- @param dir integer 1 or -1
--- @param count integer|nil
function M.jump(kind, dir, count)
  if not current or not current.float:valid() then
    return
  end
  local view, win, buf = current.view, current.float.win, current.float.buf
  if view.mode == "help" then
    return
  end
  local list, offset, pages = nil, 0, nil
  if view.mode == "examples" then
    list = headings.blocks(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  else
    local all
    pages, all = index.pages(view.slug, view.path)
    if pages and all then
      local real = headings.parse(all)
      list = kind == "section" and headings.stops(real, pages) or real
      if view.mode == "section" then
        local _, page = headings.page_at(pages, M.page_line(view))
        offset = page and page.first - 1 or 0
      end
    else
      pages = nil
      list = headings.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    end
  end
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local target = headings.target(list, cursor + offset, dir, kind, count)
  if not target then
    local what = view.mode == "examples" and "example" or kind
    notify(("no %s %s"):format(dir > 0 and "next" or "previous", what))
    return
  end
  local line = target - offset
  if line >= 1 and line <= vim.api.nvim_buf_line_count(buf) then
    vim.api.nvim_win_call(win, function()
      vim.cmd "normal! m'"
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      vim.cmd "normal! zt"
    end)
    return
  end
  if view.mode ~= "section" or not pages then
    return
  end
  -- paginated, target on another page: turn to it
  local _, page = headings.page_at(pages, target)
  local v = vim.tbl_extend("force", view, { page_start = page.first, line = target - page.first + 1, top = true })
  v.topline = nil
  show(v, false)
end

function M.help()
  if not current or not current.float:valid() or current.view.mode == "help" then
    return
  end
  local v = vim.tbl_extend("force", snapshot(), { mode = "help", under = current.view.mode })
  push_history()
  current.view = v
  current.links = {}
  local width = vim.api.nvim_win_get_width(current.float.win)
  local lines, spans
  if v.under == "index" then
    lines, spans = glossary_render.help_lines(width)
  else
    lines, spans = M.help_lines(width)
  end
  current.float:set_lines(lines)
  apply_links(current.float.buf, {})
  float.highlight(current.float.buf, NS, spans)
  -- the page under may have been scrolled: show the help from its title
  vim.api.nvim_win_call(current.float.win, function()
    vim.fn.winrestview { topline = 1, lnum = 1, col = 0 }
  end)
  current.float:set_title("DevDocs help", { { "⌫", "back" }, { "q", "close" } })
end

-- ---------------------------------------------------------------- index

--- Open the index of a doc: its types and entries, in the state it was left
--- in. With `opts.path` (and `opts.name`) the entry's type is expanded, the
--- cursor lands on the entry and it is marked ●. Goes on the history when a
--- viewer is open (and is not already this doc's index).
--- `opts.on_back` is what <BS> does once the history is empty (the manager
--- passes itself), kept only when this opens a new float.
--- @param slug string
--- @param opts { path?: string, name?: string, on_back?: fun() }|nil
function M.open_index(slug, opts)
  opts = opts or {}
  if not store.is_installed(slug) then
    notify(("%s is not installed (:DevDocs install %s)"):format(slug, slug), vim.log.levels.WARN)
    return
  end
  local tree = tree_for(slug)
  local state, row, mark = last[slug] or glossary.new(), last_row[slug] or 1, nil
  local gi, ei
  if opts.path then
    gi, ei = glossary.find(tree, opts.path, opts.name)
  end
  if gi then
    mark = tree.groups[gi].entries[ei]
    state, row = glossary.reveal(tree, state, opts.path, opts.name)
  end
  last[slug], last_row[slug] = state, row
  local view = { slug = slug, path = "", mode = "index", index = state, entry = mark, line = row }
  local here = current and current.view
  local fresh = current == nil
  show(view, current ~= nil and not (here.mode == "index" and here.slug == slug))
  if fresh and current then
    current.on_back = opts.on_back
  end
end

--- I: from a page, the index of its doc with the page's entry shown; in the
--- index, back to the page it was opened from.
function M.index()
  if not current or not current.float:valid() then
    return
  end
  local view = current.view
  if view.mode == "help" then
    return
  end
  if view.mode == "index" then
    local prev = current.history[#current.history]
    if prev and prev.mode ~= "index" then
      M.back()
    else
      notify "no page to return to"
    end
    return
  end
  local entry = view.entry or index.entry_for_path(view.slug, view.path)
  M.open_index(view.slug, { path = view.path, name = entry and entry.name })
end

--- Apply an action (glossary.reduce) to the index on screen, redrawing in
--- place; the history is untouched.
--- @param action { type: string, text?: string }
function M.index_act(action)
  local c = current
  if not c or not c.float:valid() or c.view.mode ~= "index" then
    return
  end
  local view = snapshot()
  local state, line = glossary.reduce(tree_for(view.slug), view.index, view.line, action)
  last[view.slug], last_row[view.slug] = state, line
  view.index, view.line = state, line
  c.view = view
  draw_index(c)
end

--- <CR>, l and a double-click: open the entry under the cursor as a page;
--- on a type or the doc row, expand / collapse it (l only expands).
--- @param on_fold "toggle"|"expand"|nil what a type or the doc row does (default toggle)
function M.index_enter(on_fold)
  local c = current
  if not c or not c.float:valid() or c.view.mode ~= "index" then
    return
  end
  local row = c.rows[vim.api.nvim_win_get_cursor(c.float.win)[1]]
  local e = glossary.target(row)
  if not e then
    M.index_act { type = on_fold or "toggle" }
    return
  end
  show(M.normalize { slug = c.view.slug, path = e.path, entry = e, mode = "section" }, true)
end

--- /: read a filter live (Esc clears it, Enter keeps it, Backspace edits).
function M.index_filter()
  local c = current
  if not c or not c.float:valid() or c.view.mode ~= "index" then
    return
  end
  local text = c.view.index.filter
  local bs = vim.api.nvim_replace_termcodes("<BS>", true, false, true)
  local function apply()
    M.index_act { type = "filter", text = text }
    vim.api.nvim_echo({ { "/" .. text } }, false, {})
    vim.cmd.redraw()
  end
  apply()
  while current == c and c.float:valid() do
    local ok, ch = pcall(vim.fn.getcharstr)
    if not ok or ch == "\27" or ch == "\3" then
      text = ""
      break
    elseif ch == "\r" or ch == "\n" then
      break
    elseif ch == bs or ch == "\8" or ch == "\127" then
      text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
    elseif #ch == 1 and ch:match "[%w%p ]" or (ch:byte(1) or 0) >= 0xC2 then
      text = text .. ch
    end
    -- typed ahead: filter once for the whole burst, not per key
    if vim.fn.getchar(1) == 0 then
      apply()
    end
  end
  vim.api.nvim_echo({ { "" } }, false, {})
  if current == c and c.float:valid() then
    M.index_act { type = "filter", text = text }
  end
end

--- d: the index of another installed doc (this buffer's docs first).
function M.index_doc()
  if not current or not current.float:valid() or current.view.mode ~= "index" then
    return
  end
  local origin = current.origin
  local slugs, seen = {}, {}
  local function add(slug)
    if not seen[slug] and store.is_installed(slug) then
      seen[slug] = true
      slugs[#slugs + 1] = slug
    end
  end
  if origin and vim.api.nvim_buf_is_valid(origin) then
    local ok, b = pcall(require("devdocs.detect").buffer, origin)
    for _, slug in ipairs(ok and b.slugs or {}) do
      add(slug)
    end
  end
  for _, slug in ipairs(store.installed()) do
    add(slug)
  end
  vim.ui.select(slugs, {
    prompt = "DevDocs index of:",
    format_item = function(slug)
      return index.breadcrumb(slug, nil)
    end,
  }, function(choice)
    if choice then
      M.open_index(choice)
    end
  end)
end

vim.api.nvim_create_autocmd("VimResized", {
  group = vim.api.nvim_create_augroup("devdocs_viewer", { clear = true }),
  callback = function()
    -- after the float re-laid itself out: the index is as wide as the window
    vim.schedule(function()
      if current and current.float:valid() and current.view.mode == "index" then
        current.view = snapshot()
        draw_index(current)
      end
    end)
  end,
})

return M

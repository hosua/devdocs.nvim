--- Viewer: shows one doc page (or one page of it at a time, starting at the
--- entry, or only its examples) in a float. Rendering of the header/footer is pure
--- (render()) so it is tested; one viewer is reused while open and keeps a
--- history for following devdocs:// links.
---
--- Keys inside: q/<Esc> close · o browser · y yank url · <CR> follow link
--- · <BS> back · n/N next/previous section · c/C next/previous chapter · e
--- examples · p toggle paginated / whole page · s search this doc · ? help
local config = require "devdocs.config"
local float = require "devdocs.ui.float"
local headings = require "devdocs.headings"
local index = require "devdocs.index"
local paths = require "devdocs.paths"
local store = require "devdocs.store"

local M = {}

--- @class DevDocsView
--- @field slug string
--- @field path string      page path with optional fragment
--- @field entry DevDocsEntry|nil
--- @field mode "section"|"page"|"examples"|"help"  "section" is the paginated view
--- @field line integer|nil       line of the shown text to put the cursor on
--- @field top boolean|nil         also scroll that line to the top of the window
--- @field topline integer|nil     first visible line to restore (history entries)
--- @field page_at integer|nil     whole-page line to return to on p / e from the examples
--- @field page_start integer|nil  paginated: first page line of the shown page; nil = the page of the entry's anchor
--- @field under "section"|"page"|"examples"|nil  help only: the mode under the help screen
--- @field view_mode "float"|"split"|"vsplit"|"tab"|nil  window kind override

local hints = require "devdocs.ui.hints"
M.FOOTER = {
  { "⏎", "follow" },
  { "⌫", "back" },
  { "e", "examples" },
  { "p", "pages" },
  { "n/N", "section" },
  { "c/C", "chapter" },
  { "s", "search" },
  { "?", "help" },
  { "q", "close" },
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
    out[#out + 1] = h[1] == "p" and { "p", mode == "page" and "paginated" or "pages" } or h
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
  return vim.tbl_extend("force", view, { line = cursor[1], topline = top, top = false })
end

local function push_history()
  current.history[#current.history + 1] = snapshot()
end

local function show(view, push)
  local lines, title, err = M.render(view)
  if err then
    notify(err, vim.log.levels.WARN)
  end
  if view.view_mode and current and current.float:valid() and current.float.mode ~= view.view_mode then
    M.close()
  end
  local display, links = M.display(lines)
  if current and current.float:valid() then
    if push then
      push_history()
    end
    current.view = view
    current.links = links
    current.float:set_lines(display)
    apply_links(current.float.buf, links)
    current.float:set_title(title, M.footer(view.mode))
    place_cursor(current.float.win, view, #lines)
  else
    local keys = {}
    local self = { view = view, history = {} }
    local function act(fn)
      return function()
        fn(self)
      end
    end
    keys["q"] = act(M.close)
    keys["<Esc>"] = act(M.close)
    keys["o"] = act(M.browser)
    keys["y"] = act(M.yank)
    keys["<CR>"] = act(M.follow)
    keys["<2-LeftMouse>"] = act(M.follow)
    keys["<BS>"] = act(M.back)
    keys["u"] = act(M.back)
    keys["e"] = act(function()
      local view = self.view
      if view.mode ~= "examples" then
        M.set_mode "examples"
      else
        -- back to the view e came from: page_at is only set from the whole page
        M.set_mode(view.page_at and "page" or "section")
      end
    end)
    keys["p"] = act(M.toggle)
    keys["s"] = act(function()
      local slug = self.view.slug
      M.close()
      vim.schedule(function()
        require("devdocs").search("@" .. slug .. " ")
      end)
    end)
    keys["n"] = act(function()
      M.jump("section", 1, vim.v.count1)
    end)
    keys["N"] = act(function()
      M.jump("section", -1, vim.v.count1)
    end)
    keys["c"] = act(function()
      M.jump("chapter", 1, vim.v.count1)
    end)
    keys["C"] = act(function()
      M.jump("chapter", -1, vim.v.count1)
    end)
    keys["?"] = act(M.help)
    self.float = float.open {
      lines = display,
      title = title,
      footer = M.footer(view.mode),
      filetype = "markdown",
      mode = view.view_mode,
      name = ("devdocs://%s/%s"):format(view.slug, view.path),
      keys = keys,
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
    apply_links(self.float.buf, links)
    if view.line then
      place_cursor(self.float.win, view, #lines)
    end
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

function M.browser()
  if not current then
    return
  end
  local url = paths.browser_url(current.view.slug, current.view.path)
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
  local url = paths.browser_url(current.view.slug, current.view.path)
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
  local lines, spans = M.help_lines(vim.api.nvim_win_get_width(current.float.win))
  current.float:set_lines(lines)
  apply_links(current.float.buf, {})
  float.highlight(current.float.buf, NS, spans)
  -- the page under may have been scrolled: show the help from its title
  vim.api.nvim_win_call(current.float.win, function()
    vim.fn.winrestview { topline = 1, lnum = 1, col = 0 }
  end)
  current.float:set_title("DevDocs help", { { "⌫", "back" }, { "q", "close" } })
end

return M

--- Viewer: shows one doc page (or the section an entry points at, or only
--- its examples) in a float. Rendering of the header/footer is pure
--- (render()) so it is tested; one viewer is reused while open and keeps a
--- history for following devdocs:// links.
---
--- Keys inside: q/<Esc> close · o browser · y yank url · <CR> follow link
--- · <BS> back · e examples · p whole page (at this section) · s search this
--- doc · ? help
local config = require "devdocs.config"
local float = require "devdocs.ui.float"
local index = require "devdocs.index"
local paths = require "devdocs.paths"
local store = require "devdocs.store"

local M = {}

--- @class DevDocsView
--- @field slug string
--- @field path string      page path with optional fragment
--- @field entry DevDocsEntry|nil
--- @field mode "section"|"page"|"examples"
--- @field line integer|nil       line of the shown text to put the cursor on
--- @field top boolean|nil         also scroll that line to the top of the window
--- @field topline integer|nil     first visible line to restore (history entries)
--- @field page_at integer|nil     page line to return to on p from e (no fragment)
--- @field view_mode "float"|"split"|"vsplit"|"tab"|nil  window kind override

M.FOOTER = "o browser  y url  ⏎ follow  ⌫ back  e examples  p page  s search  ? help  q close"

M.HELP = {
  "DevDocs viewer keys",
  "",
  "  q, <Esc>   close",
  "  o          open this page on devdocs.io",
  "  y          yank the devdocs.io url",
  "  <CR>       follow the link under the cursor (devdocs:// stays in the viewer)",
  "  <BS>, u    back to the previous page",
  "  e          only the examples of this section",
  "  p          the whole page, scrolled to this section",
  "  s          search inside this doc",
  "  <C-f>/<C-b>, j/k, gg/G  scroll",
  "  ?          this help",
}

--- The lines to show for a view, plus a title. Pure given the page data.
--- @param view DevDocsView
--- @return string[] lines, string title, string|nil err
function M.render(view)
  local title = index.breadcrumb(view.slug, view.entry)
  local lines, err
  if view.mode == "page" then
    lines, err = index.page(view.slug, view.path)
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

--- The 1-based page line the section a view shows starts at (its anchor),
--- so the whole page can open there. 1 without a fragment, for an unknown
--- anchor or a missing page. Pure given the page data.
--- @param view DevDocsView
--- @return integer
function M.page_line(view)
  local _, start = index.section(view.slug, view.path)
  return start or 1
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
    current.float:set_title(title, M.FOOTER)
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
      M.set_mode(self.view.mode == "examples" and "section" or "examples")
    end)
    keys["p"] = act(function()
      M.set_mode "page"
    end)
    keys["s"] = act(function()
      local slug = self.view.slug
      M.close()
      vim.schedule(function()
        require("devdocs").search("@" .. slug .. " ")
      end)
    end)
    keys["?"] = act(M.help)
    self.float = float.open {
      lines = display,
      title = title,
      footer = M.FOOTER,
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

--- Open a page/section/examples view.
--- @param view DevDocsView
function M.open(view)
  view.mode = view.mode or "section"
  if not store.is_installed(view.slug) then
    notify(("%s is not installed (:DevDocs install %s)"):format(view.slug, view.slug), vim.log.levels.WARN)
    return
  end
  show(view, current ~= nil)
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

--- Switch the current view to another mode (e and p). Into "page" from a
--- section, its examples or the help screen, the page opens at that
--- section's heading; a page without a fragment (a search hit) opens at the
--- line it was left at. The view switched from goes on the history (help
--- already put its view there), so <BS> walks back through e and p alike.
--- @param mode "section"|"page"|"examples"
function M.set_mode(mode)
  if not current or current.view.mode == mode then
    return
  end
  local from = current.view
  local v = vim.tbl_extend("force", from, { mode = mode, topline = nil })
  if mode ~= "page" then
    -- view.line is a line of the page; remember it for the way back to p
    if from.mode == "page" and current.float:valid() then
      v.page_at = vim.api.nvim_win_get_cursor(current.float.win)[1]
    end
    v.line, v.top = nil, nil
  elseif from.path:find("#", 1, true) then
    v.line, v.top = M.page_line(from), true
  else
    v.line, v.top = from.page_at or (from.mode == "help" and from.line) or 1, nil
  end
  show(v, from.mode ~= "help")
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
    show({ slug = slug, path = path, entry = index.entry_for_path(slug, path), mode = "section" }, true)
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

function M.help()
  if not current then
    return
  end
  local v = vim.tbl_extend("force", current.view, { mode = "help" })
  push_history()
  current.view = v
  current.links = {}
  current.float:set_lines(M.HELP)
  apply_links(current.float.buf, {})
  current.float:set_title("DevDocs help", "⌫ back  q close")
end

return M

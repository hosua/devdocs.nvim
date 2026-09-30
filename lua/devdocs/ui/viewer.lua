--- Viewer: shows one doc page (or the section an entry points at, or only
--- its examples) in a float. Rendering of the header/footer is pure
--- (render()) so it is tested; one viewer is reused while open and keeps a
--- history for following devdocs:// links.
---
--- Keys inside: q/<Esc> close · o browser · y yank url · <CR> follow link
--- · <BS> back · e examples · p whole page · s search this doc · ? help
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
  "  p          the whole page",
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

local current

--- The devdocs:// or http(s) link under the cursor in the viewer buffer.
--- @param line string
--- @param col integer 0-based cursor column
--- @return string|nil url
function M.link_at(line, col)
  local best
  for s, url, e in line:gmatch "()%b[]%((%S-)%)()" do
    if col + 1 >= s and col + 1 < e then
      return url
    end
    best = best or url
  end
  for s, url, e in line:gmatch "()(%a[%w+.-]*://%S+)()" do
    if col + 1 >= s and col + 1 < e then
      return (url:gsub("[%.,;:)%]]+$", ""))
    end
  end
  return best
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

local function show(view, push_history)
  local lines, title, err = M.render(view)
  if err then
    notify(err, vim.log.levels.WARN)
  end
  if current and current.float:valid() then
    if push_history then
      current.history[#current.history + 1] = current.view
    end
    current.view = view
    current.float:set_lines(lines)
    current.float:set_title(title, M.FOOTER)
    vim.api.nvim_win_set_cursor(current.float.win, { 1, 0 })
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
      lines = lines,
      title = title,
      footer = M.FOOTER,
      filetype = "markdown",
      name = ("devdocs://%s/%s"):format(view.slug, view.path),
      keys = keys,
      on_close = function()
        if current == self then
          current = nil
        end
      end,
    }
    current = self
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

function M.set_mode(mode)
  if not current then
    return
  end
  local v = vim.tbl_extend("force", current.view, { mode = mode })
  show(v, false)
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
  local line = vim.api.nvim_buf_get_lines(current.float.buf, row - 1, row, false)[1] or ""
  local url = M.link_at(line, col)
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
  current.history[#current.history + 1] = current.view
  current.view = v
  current.float:set_lines(M.HELP)
  current.float:set_title("DevDocs help", "⌫ back  q close")
end

return M

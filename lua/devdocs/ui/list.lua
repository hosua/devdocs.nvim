--- List manager window (:DevDocs list). Holds one state, re-renders on
--- every action and on installer events, and runs the effects (install,
--- uninstall, update, enable, open). Everything visual comes from
--- ui/render.lua; everything about rows from ui/model.lua.
local config = require "devdocs.config"
local float = require "devdocs.ui.float"
local installer = require "devdocs.installer"
local manifest = require "devdocs.manifest"
local model = require "devdocs.ui.model"
local paths = require "devdocs.paths"
local render = require "devdocs.ui.render"
local selection = require "devdocs.ui.selection"
local store = require "devdocs.store"

local M = {}

local NS = vim.api.nvim_create_namespace "devdocs_list"
local ui -- { float, state, render, listener }

local function notify(msg, level)
  vim.notify("devdocs: " .. msg, level or vim.log.levels.INFO)
end

local function installed_metas()
  local out = {}
  for _, slug in ipairs(store.installed()) do
    out[slug] = store.meta(slug)
  end
  return out
end

local function jobs_by_slug()
  local out = {}
  for _, j in ipairs(installer.status()) do
    out[j.slug] = j
  end
  return out
end

local function disabled_slugs()
  local out = {}
  for slug, on in pairs(store.state().enabled) do
    if on == false then
      out[slug] = true
    end
  end
  return out
end

local function draw()
  if not ui or not ui.float:valid() then
    return
  end
  local r = render.render(ui.state)
  ui.render = r
  ui.float:set_lines(r.lines)
  vim.api.nvim_buf_clear_namespace(ui.float.buf, NS, 0, -1)
  for _, s in ipairs(r.spans) do
    pcall(
      vim.api.nvim_buf_set_extmark,
      ui.float.buf,
      NS,
      s.row - 1,
      s.col_start,
      { end_col = s.col_end, hl_group = s.hl }
    )
  end
  if #r.rows > 0 then
    pcall(vim.api.nvim_win_set_cursor, ui.float.win, { math.min(render.cursor_line(ui.state), #r.lines), 0 })
  end
end

local function dispatch(action)
  if not ui then
    return
  end
  ui.state = model.reduce(ui.state, action)
  draw()
end

local function refresh_data()
  dispatch {
    type = "data",
    data = { installed = installed_metas(), jobs = jobs_by_slug(), disabled = disabled_slugs() },
  }
end

local function visible_rows()
  local l = float.layout(config.get().view.width, config.get().view.height)
  return math.max(3, l.height - render.HEADER_LINES), l.width
end

local function load_manifest(force)
  dispatch { type = "data", data = { loading = true, error = nil } }
  manifest.get(function(docs, err)
    if not ui then
      return
    end
    local _, at = manifest.cached()
    dispatch {
      type = "data",
      data = { docs = docs or {}, loading = false, error = err, fetched_at = at },
    }
  end, { force = force })
end

-- ---------------------------------------------------------------- effects

local function current_row()
  return ui and model.current(ui.state) or nil
end

local function do_install(row, force)
  if row.status == "installing" then
    notify(row.slug .. " is already installing")
    return
  end
  installer.install(row.slug, { force = force, doc = row.doc }, function(ok, err)
    if not ok then
      notify(("%s: %s"):format(row.slug, err), vim.log.levels.ERROR)
    end
    refresh_data()
  end)
  refresh_data()
end

--- X: one version, or on a language row every installed version, after one
--- confirm that lists the directories it deletes.
local function do_uninstall(row)
  local victims = row.kind == "lang"
      and vim.tbl_filter(function(c)
        return c.meta ~= nil
      end, row.children)
    or { row }
  if #victims == 0 or not victims[1].meta then
    notify((row.slug or row.base) .. " is not installed")
    return
  end
  local dirs = vim.tbl_map(function(v)
    return paths.doc_dir(v.slug)
  end, victims)
  if not float.confirm(("Delete %s?"):format(table.concat(dirs, "\n"))) then
    return
  end
  for _, v in ipairs(victims) do
    local ok, err = installer.uninstall(v.slug)
    if not ok then
      notify(err, vim.log.levels.ERROR)
    end
  end
  refresh_data()
end

--- u: reinstall a version; on a language row, its outdated versions (or its
--- target when none is outdated).
local function do_update(row)
  if row.kind ~= "lang" then
    do_install(row, true)
    return
  end
  local outdated = vim.tbl_filter(function(c)
    return c.status == "outdated"
  end, row.children)
  if #outdated == 0 then
    do_install(model.target(row), true)
    return
  end
  local slugs = vim.tbl_map(function(c)
    return c.slug
  end, outdated)
  installer.install_many(slugs, { force = true, docs = manifest.by_slug(ui.state.docs) }, function()
    refresh_data()
  end)
  refresh_data()
end

--- Delete several docs after one confirm that lists every slug and the
--- disk space it frees. Marks of deleted docs drop out on the refresh.
local function do_uninstall_many(slugs)
  local present = vim.tbl_filter(function(s)
    return ui.state.installed[s] ~= nil
  end, slugs)
  if #present == 0 then
    notify "nothing installed to delete"
    return
  end
  if not float.confirm(selection.confirm_message(present, installer.disk_usage(present), paths.docs_dir())) then
    return
  end
  local n, errors = installer.uninstall_many(present)
  if #errors > 0 then
    notify(("deleted %d, failed %d: %s"):format(n, #errors, table.concat(errors, "; ")), vim.log.levels.WARN)
  else
    notify(("deleted %d doc%s"):format(n, n == 1 and "" or "s"))
  end
  refresh_data()
end

--- The row under the cursor, whatever its kind (group headers included).
local function cursor_row()
  return ui and model.rows(ui.state)[ui.state.cursor] or nil
end

--- X: the marked docs when there are marks, else the row under the cursor.
local function do_uninstall_selection()
  local marked = selection.targets(ui.state.marked)
  if #marked > 0 then
    do_uninstall_many(marked)
    return
  end
  local row = current_row()
  if row then
    do_uninstall(row)
  end
end

--- Delete every installed version but the current one, of one base or all.
--- @param base string|nil
local function do_prune(base)
  local slugs = selection.prune_targets(ui.state.installed, ui.state.docs, base)
  if #slugs == 0 then
    notify(
      base and ("%s has at most one installed version; nothing to prune"):format(base)
        or "every language has at most one installed version; nothing to prune"
    )
    return
  end
  do_uninstall_many(slugs)
end

--- Row indexes of the visual selection, clamped to the rendered rows, and
--- leaves visual mode. Buffer lines map to rows through HEADER_LINES + top.
--- @return integer|nil from, integer|nil to
local function visual_rows()
  local a, b = vim.fn.line "v", vim.fn.line "."
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  if not ui or not ui.render or #ui.render.rows == 0 then
    return nil, nil
  end
  local first = render.HEADER_LINES + 1
  local last = #ui.render.lines
  local function to_row(line)
    line = math.max(first, math.min(line, last))
    return ui.state.top + line - first
  end
  return to_row(a), to_row(b)
end

local function do_update_all()
  local slugs = installer.outdated(ui.state.docs)
  if #slugs == 0 then
    notify "every installed doc is current"
    return
  end
  installer.install_many(slugs, { force = true, docs = manifest.by_slug(ui.state.docs) }, function()
    refresh_data()
  end)
  refresh_data()
end

local function do_toggle_enabled(row)
  if not row.meta then
    notify "only installed docs can be enabled or disabled"
    return
  end
  store.update_state(function(st)
    if st.enabled[row.slug] == false then
      st.enabled[row.slug] = true
    else
      st.enabled[row.slug] = false
    end
    return st
  end)
  refresh_data()
end

local function do_open(row)
  if not row.meta then
    notify(("%s is not installed; i installs it"):format(row.slug))
    return
  end
  M.close()
  vim.schedule(function()
    require("devdocs").open(row.slug)
  end)
end

local function do_browser(row)
  pcall(vim.ui.open, paths.browser_url(row.slug, nil))
end

--- Live filter: read keys until <CR>/<Esc>, re-rendering on each one.
local function do_filter()
  local original = ui.state.filter
  local text = original
  local function show()
    dispatch { type = "filter", text = text }
    vim.cmd.redraw()
  end
  show()
  while true do
    local ok, ch = pcall(vim.fn.getcharstr)
    if not ok or ch == "\27" then
      text = ""
      break
    elseif ch == "\r" or ch == "\n" then
      break
    elseif ch == vim.api.nvim_replace_termcodes("<BS>", true, false, true) or ch == "\8" or ch == "\127" then
      text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
    elseif #ch == 1 and ch:match "[%w%p ]" then
      text = text .. ch
    end
    show()
  end
  show()
end

local function do_help()
  local h = float.open {
    lines = render.HELP,
    title = "DevDocs manager help",
    footer = "q close",
    width = 70,
    height = #render.HELP + 2,
    mode = "float",
  }
  vim.keymap.set("n", "q", function()
    h:close()
  end, { buffer = h.buf })
  vim.keymap.set("n", "<Esc>", function()
    h:close()
  end, { buffer = h.buf })
end

local function row_at_mouse()
  local pos = vim.fn.getmousepos()
  if not ui or pos.winid ~= ui.float.win then
    return nil
  end
  local line = pos.line
  for _, reg in ipairs(ui.render and ui.render.regions or {}) do
    if reg.row == line then
      return reg.id
    end
  end
  return nil
end

-- ---------------------------------------------------------------- open / close

function M.close()
  if ui then
    installer.off(ui.listener)
    ui.float:close()
    ui = nil
  end
end

function M.open()
  if ui and ui.float:valid() then
    vim.api.nvim_set_current_win(ui.float.win)
    return
  end
  local height, width = visible_rows()
  local state = model.new {
    docs = manifest.cached() or {},
    installed = installed_metas(),
    jobs = jobs_by_slug(),
    disabled = disabled_slugs(),
    height = height,
    width = width,
    loading = false,
  }
  -- fn gets the row under the cursor (a language or a version)
  local function with_row(fn)
    return function()
      local row = current_row()
      if row then
        fn(row)
      end
    end
  end
  -- fn gets the version an action on the cursor row means (model.target)
  local function with_target(fn)
    return with_row(function(row)
      local target = model.target(row)
      if target then
        fn(target)
      end
    end)
  end
  local keys = {
    q = M.close,
    ["<Esc>"] = M.close,
    j = function()
      dispatch { type = "move", n = 1 }
    end,
    k = function()
      dispatch { type = "move", n = -1 }
    end,
    ["<Down>"] = function()
      dispatch { type = "move", n = 1 }
    end,
    ["<Up>"] = function()
      dispatch { type = "move", n = -1 }
    end,
    gg = function()
      dispatch { type = "top" }
    end,
    G = function()
      dispatch { type = "bottom" }
    end,
    ["<Home>"] = function()
      dispatch { type = "top" }
    end,
    ["<End>"] = function()
      dispatch { type = "bottom" }
    end,
    ["<C-d>"] = function()
      dispatch { type = "page", n = 1 }
    end,
    ["<C-u>"] = function()
      dispatch { type = "page", n = -1 }
    end,
    ["<PageDown>"] = function()
      dispatch { type = "page", n = 1 }
    end,
    ["<PageUp>"] = function()
      dispatch { type = "page", n = -1 }
    end,
    ["<ScrollWheelDown>"] = function()
      dispatch { type = "move", n = 3 }
    end,
    ["<ScrollWheelUp>"] = function()
      dispatch { type = "move", n = -3 }
    end,
    ["}"] = function()
      dispatch { type = "next_group" }
    end,
    ["{"] = function()
      dispatch { type = "prev_group" }
    end,
    ["<Tab>"] = function()
      dispatch { type = "toggle_expand" }
    end,
    l = function()
      dispatch { type = "expand" }
    end,
    h = function()
      dispatch { type = "collapse" }
    end,
    i = with_target(function(row)
      do_install(row, row.meta ~= nil)
    end),
    X = do_uninstall_selection,
    m = function()
      dispatch { type = "mark" }
    end,
    M = function()
      dispatch { type = "unmark_all" }
    end,
    D = function()
      local row = cursor_row()
      if row and row.base then
        do_prune(row.base)
      end
    end,
    gD = function()
      do_prune(nil)
    end,
    u = with_row(do_update),
    U = do_update_all,
    e = with_target(do_toggle_enabled),
    ["<CR>"] = with_target(do_open),
    o = with_target(do_browser),
    ["/"] = do_filter,
    s = function()
      dispatch { type = "sort" }
    end,
    r = function()
      load_manifest(true)
    end,
    A = function()
      M.close()
      vim.schedule(function()
        require("devdocs").install_all()
      end)
    end,
    ["?"] = do_help,
    ["<LeftMouse>"] = function()
      local id = row_at_mouse()
      if id then
        dispatch { type = "goto", row = id }
      end
    end,
    ["<2-LeftMouse>"] = function()
      local id = row_at_mouse()
      if id then
        dispatch { type = "goto", row = id }
        local row = model.target(current_row())
        if row then
          do_open(row)
        end
      end
    end,
  }
  local f = float.open {
    lines = {},
    title = "DevDocs",
    footer = nil,
    name = "devdocs://list",
    keys = keys,
    wrap = false,
    conceal = false,
    on_close = function()
      if ui then
        installer.off(ui.listener)
        ui = nil
      end
    end,
  }
  vim.wo[f.win].cursorline = true
  -- visual-line selections: m marks the range, X / d deletes it
  local function vmap(lhs, fn)
    vim.keymap.set("x", lhs, fn, { buffer = f.buf, nowait = true, silent = true })
  end
  vmap("m", function()
    local from, to = visual_rows()
    if from then
      dispatch { type = "mark_range", from = from, to = to }
      dispatch { type = "goto", row = to }
    end
  end)
  local function delete_range()
    local from, to = visual_rows()
    if from then
      do_uninstall_many(selection.range_targets(model.rows(ui.state), from, to))
    end
  end
  vmap("X", delete_range)
  vmap("d", delete_range)
  local listener = function()
    vim.schedule(refresh_data)
  end
  installer.on(listener)
  ui = { float = f, state = state, listener = listener }
  -- VimResized is not a buffer event: a buffer-local autocmd would never fire
  local group = vim.api.nvim_create_augroup("devdocs_list", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not ui or not ui.float:valid() then
        pcall(vim.api.nvim_del_augroup_by_id, group)
        return
      end
      vim.schedule(function()
        local h, w = visible_rows()
        dispatch { type = "resize", height = h, width = w }
      end)
    end,
  })
  draw()
  if #state.docs == 0 or not manifest.is_fresh() then
    load_manifest(false)
  end
end

--- @return DevDocsListState|nil
function M.state()
  return ui and ui.state or nil
end

return M

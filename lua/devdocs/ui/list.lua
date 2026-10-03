--- List manager window (:DevDocs list). Holds one state, re-renders on
--- every action and on installer events, and runs the effects (install,
--- uninstall, update, enable, open). Everything visual comes from
--- ui/render.lua; everything about rows from ui/model.lua.
local config = require "devdocs.config"
local float = require "devdocs.ui.float"
local hints = require "devdocs.ui.hints"
local installer = require "devdocs.installer"
local manifest = require "devdocs.manifest"
local model = require "devdocs.ui.model"
local paths = require "devdocs.paths"
local projects = require "devdocs.projects"
local releases = require "devdocs.releases"
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
  -- render emits only the rows that fit, so the buffer always starts at the
  -- top; a window that shrank (VimResized) scrolled the header out of view
  vim.api.nvim_win_call(ui.float.win, function()
    vim.fn.winrestview { topline = 1 }
  end)
  -- pending marks are unsaved changes, oil.nvim style: :w applies them
  vim.bo[ui.float.buf].modified = selection.count(ui.state.marked) > 0
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

--- Upstream release dates (endoflife.date) for every listed and installed doc,
--- merged into state.release_dates: once from cache, again when fresh data
--- arrives. Merged, so a slower call that saw fewer docs never drops dates.
--- An installed doc is dated by its installed release, not the manifest's.
local function load_release_dates()
  if not ui then
    return
  end
  local installed = ui.state.installed or {}
  local docs, seen = {}, {}
  for _, d in ipairs(ui.state.docs or {}) do
    seen[d.slug] = true
    docs[#docs + 1] = releases.installed_doc(d, installed[d.slug])
  end
  for slug, meta in pairs(installed) do
    if not seen[slug] and type(meta) == "table" then
      docs[#docs + 1] = releases.installed_doc(nil, meta, slug)
    end
  end
  releases.dates_for(docs, function(map)
    if ui then
      dispatch { type = "release_dates", dates = map }
    end
  end)
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
    load_release_dates()
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
  -- installed by hand: an install mark on it would turn into an uninstall
  if not row.meta then
    dispatch { type = "unmark", slugs = { row.slug } }
  end
  installer.install(row.slug, { force = force, doc = row.doc }, function(ok, err)
    if not ok then
      notify(("%s: %s"):format(row.slug, err), vim.log.levels.ERROR)
    end
    refresh_data()
  end)
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

--- installer.uninstall_many, plus the slugs it did delete.
--- @return integer n, string[] errors, string[] deleted
local function uninstall(slugs)
  local n, errors = installer.uninstall_many(slugs)
  local failed = {}
  for _, e in ipairs(errors) do
    failed[e:match "^(.-): " or e] = true
  end
  local deleted = vim.tbl_filter(function(s)
    return not failed[s]
  end, slugs)
  return n, errors, deleted
end

--- Every delete in the manager goes through here: one confirm that lists
--- every slug, the disk space it frees and the docs dir (plus `notes`), then
--- installer.uninstall_many. Marks of deleted docs drop out on the refresh.
--- @param slugs string[]
--- @param notes string[]|nil extra confirm lines
local function do_uninstall_many(slugs, notes)
  local present = vim.tbl_filter(function(s)
    return ui.state.installed[s] ~= nil
  end, slugs)
  if #present == 0 then
    notify "nothing installed to delete"
    return
  end
  local msg = selection.confirm_message(present, installer.disk_usage(present), paths.docs_dir(), notes)
  if not float.confirm(msg) then
    return
  end
  local n, errors, deleted = uninstall(present)
  if #errors > 0 then
    notify(("deleted %d, failed %d: %s"):format(n, #errors, table.concat(errors, "; ")), vim.log.levels.WARN)
  else
    notify(("deleted %d doc%s"):format(n, n == 1 and "" or "s"))
  end
  -- a mark on a doc that is not installed means "install it": drop them
  dispatch { type = "unmark", slugs = deleted }
  refresh_data()
end

local function hidden_note(slugs)
  local hidden = selection.hidden(slugs, model.rows(ui.state))
  if #hidden == 0 then
    return nil
  end
  local why = ui.state.filter ~= "" and (" (filter: %s)"):format(ui.state.filter) or ""
  return ("%d of them %s not shown in the current view%s"):format(#hidden, #hidden == 1 and "is" or "are", why)
end

--- The row under the cursor, whatever its kind (group headers included).
local function cursor_row()
  return ui and model.rows(ui.state)[ui.state.cursor] or nil
end

--- X: the row under the cursor: a version, or a language's installed
--- versions that the filter shows. With marks pending X is blocked
--- (guarded); S / :w applies the marks instead.
local function do_uninstall_selection()
  local row = current_row()
  if not row then
    return
  end
  local slugs = selection.row_slugs(row)
  if #slugs == 0 then
    notify((row.slug or row.base) .. " is not installed")
    return
  end
  do_uninstall_many(slugs)
end

--- `fn`, unless marks are pending and `key` is one selection.marked_guard
--- blocks (i, X, u): then a short notice that S applies the marks.
--- @param key string
--- @param fn fun()
--- @return fun()
local function guarded(key, fn)
  return function()
    local why = ui and selection.marked_guard(ui.state.marked, key)
    if why then
      notify(why)
      return
    end
    fn()
  end
end

--- Prune one base or all: keep the newest enabled installed version and
--- every version a project pins (selection.prune_targets), delete the rest.
--- @param base string|nil
local function do_prune(base)
  local pinned = selection.pinned_slugs(ui.state.installed, ui.state.docs, projects.pins())
  local slugs, held =
    selection.prune_targets(ui.state.installed, ui.state.docs, base, { disabled = ui.state.disabled, pinned = pinned })
  local note = selection.prune_note(held, pinned)
  if #slugs == 0 then
    local msg = base and ("%s: nothing to prune"):format(base) or "nothing to prune"
    notify(note and (msg .. "; " .. note) or msg)
    return
  end
  do_uninstall_many(slugs, note and { note } or nil)
end

--- Row indexes of the visual selection (render.visual_range: clamped to the
--- drawn rows, nil when only header lines are selected), and leaves visual mode.
--- @return integer|nil from, integer|nil to
local function visual_rows()
  local a, b = vim.fn.line "v", vim.fn.line "."
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  if not ui or not ui.render then
    return nil, nil
  end
  return render.visual_range(ui.state, #ui.render.rows, a, b)
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

--- Disk each planned doc takes: an install its download size (manifest
--- db_size), an uninstall what it uses on disk (du), else its meta.db_size.
local function plan_sizes(plan, by_slug)
  local sizes = {}
  for _, e in ipairs(plan.install) do
    sizes[e.slug] = by_slug[e.slug] and by_slug[e.slug].db_size or nil
  end
  for _, e in ipairs(plan.uninstall) do
    local meta = ui.state.installed[e.slug]
    sizes[e.slug] = installer.disk_usage { e.slug } or (type(meta) == "table" and meta.db_size or nil)
  end
  return sizes
end

local function slugs_of(entries)
  return vim.tbl_map(function(e)
    return e.slug
  end, entries)
end

--- :w / S: apply the marks (selection.plan) after a menu that lists the
--- installs (disk taken) and uninstalls (disk freed). Uninstalls run now,
--- installs in the background; applied marks clear, failed ones stay.
--- @return boolean false when the menu was cancelled (the marks stay pending)
local function do_apply()
  if not ui then
    return true
  end
  local by_slug = manifest.by_slug(ui.state.docs)
  local plan = selection.plan(ui.state.marked, ui.state.installed, by_slug)
  if #plan.install + #plan.uninstall == 0 then
    if #plan.unknown > 0 then
      notify(
        ("not in the docs list, can not install: %s"):format(table.concat(plan.unknown, ", ")),
        vim.log.levels.WARN
      )
    else
      notify "nothing marked"
    end
    return true
  end
  local notes = {}
  local all = vim.list_extend(slugs_of(plan.install), slugs_of(plan.uninstall))
  notes[#notes + 1] = hidden_note(all)
  if #plan.unknown > 0 then
    notes[#notes + 1] = ("not in the docs list, skipped: %s"):format(table.concat(plan.unknown, ", "))
  end
  local width = math.max(30, math.min(76, vim.o.columns - 4))
  local lines, spans = render.plan_lines(plan, plan_sizes(plan, by_slug), width, notes)
  local list_win = ui.float.win
  -- one spare column so the totals do not touch the right border
  local yes = float.choose { lines = lines, spans = spans, title = "Apply changes", width = width + 1 }
  if vim.api.nvim_win_is_valid(list_win) then
    pcall(vim.api.nvim_set_current_win, list_win)
  end
  if not yes or not ui then
    return false
  end

  local installs, msgs = slugs_of(plan.install), {}
  local n, errors, deleted = 0, {}, {}
  if #plan.uninstall > 0 then
    n, errors, deleted = uninstall(slugs_of(plan.uninstall))
  end
  dispatch { type = "unmark", slugs = vim.list_extend(vim.deepcopy(installs), deleted) }
  if #installs > 0 then
    msgs[#msgs + 1] = ("installing %d doc%s"):format(#installs, #installs == 1 and "" or "s")
    installer.install_many(installs, { docs = by_slug }, function(summary)
      local bad = vim.tbl_keys(summary.errors)
      table.sort(bad)
      if #bad > 0 then
        local why = vim.tbl_map(function(s)
          return ("%s: %s"):format(s, summary.errors[s])
        end, bad)
        notify(
          ("installed %d, failed %d (still marked): %s"):format(summary.ok, #bad, table.concat(why, "; ")),
          vim.log.levels.WARN
        )
        if ui then
          dispatch { type = "mark_slugs", slugs = bad }
        end
      else
        notify(("installed %d doc%s"):format(summary.ok, summary.ok == 1 and "" or "s"))
      end
      refresh_data()
    end)
  end
  if #plan.uninstall > 0 then
    msgs[#msgs + 1] = ("deleted %d doc%s"):format(n, n == 1 and "" or "s")
  end
  if #errors > 0 then
    msgs[#msgs + 1] = ("failed %d (still marked): %s"):format(#errors, table.concat(errors, "; "))
  end
  notify(table.concat(msgs, ", "), #errors > 0 and vim.log.levels.WARN or nil)
  refresh_data()
  return true
end

--- do_apply, then 'modified' says whether marks are still pending (failed
--- or unknown ones): `:wq` closes the list only when nothing is left.
local function apply_marks()
  local done = do_apply()
  if ui and ui.float:valid() then
    vim.bo[ui.float.buf].modified = not done or selection.count(ui.state.marked) > 0
  end
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
  local lines, spans = render.help_lines(math.min(80, vim.o.columns - 4))
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local h = float.open {
    lines = lines,
    spans = spans,
    title = "DevDocs manager help",
    footer = { { "q", "close" } },
    width = width + 2,
    height = #lines + 1,
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
    i = guarded(
      "i",
      with_target(function(row)
        do_install(row, row.meta ~= nil)
      end)
    ),
    X = guarded("X", do_uninstall_selection),
    m = function()
      dispatch { type = "mark" }
    end,
    M = function()
      dispatch { type = "unmark_all" }
    end,
    S = function()
      apply_marks()
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
    u = guarded("u", with_row(do_update)),
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
  -- :w applies the marks (oil.nvim style); :wq / :x apply, then close. A
  -- cancelled menu leaves the buffer modified, so :wq does not close it.
  vim.bo[f.buf].buftype = "acwrite"
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = f.buf,
    callback = function(ev)
      -- `:w other.txt` is not a request to apply the marks
      if ev.match ~= vim.api.nvim_buf_get_name(f.buf) then
        notify "the list can not be written to a file; :w applies the marks"
        return
      end
      apply_marks()
    end,
  })
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
    local why = selection.marked_guard(ui.state.marked, "X")
    if why then
      notify(why)
      return
    end
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
  load_release_dates()
  if #state.docs == 0 or not manifest.is_fresh() then
    load_manifest(false)
  end
end

--- @return DevDocsListState|nil
function M.state()
  return ui and ui.state or nil
end

return M

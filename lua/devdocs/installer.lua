--- Installer: download a doc, convert it in a child nvim, and move it into
--- place atomically. A bounded queue (install.max_jobs) drives install-all;
--- listeners receive progress events for the UI and the statusline.
---
--- Stages of one job: queued -> download -> extract -> convert -> done | error.
--- Everything runs in the background (vim.system); callbacks are scheduled.
--- A failed download from the CDN retries with exponential backoff on 429
--- and 5xx, which is what the public mirror answers when hammered.
local config = require "devdocs.config"
local fetch = require "devdocs.fetch"
local paths = require "devdocs.paths"
local store = require "devdocs.store"

local M = {}

--- @class DevDocsJob
--- @field slug string
--- @field stage "queued"|"download"|"extract"|"convert"|"done"|"error"
--- @field progress number 0..1
--- @field err string|nil
--- @field attempt integer
--- @field doc DevDocsDoc|nil manifest entry, when known
--- @field started_at integer
--- @field callbacks fun(ok: boolean, err: string|nil)[]

--- @type table<string, DevDocsJob>
M.jobs = {}
--- @type string[]
M.queue = {}
M.active = 0
M.listeners = {}

M.MAX_ATTEMPTS = 4
--- Seconds to wait before attempt n (1-based): 2, 4, 8, 16 ... capped.
--- @param attempt integer
--- @return integer
function M.backoff(attempt)
  return math.min(60, 2 ^ attempt)
end

--- @param fn fun(event: "start"|"progress"|"done"|"error", job: DevDocsJob)
function M.on(fn)
  M.listeners[#M.listeners + 1] = fn
end

--- @param fn function
function M.off(fn)
  M.listeners = vim.tbl_filter(function(l)
    return l ~= fn
  end, M.listeners)
end

local function emit(event, job)
  local snapshot = vim.deepcopy(job)
  snapshot.callbacks = nil
  vim.schedule(function()
    for _, l in ipairs(M.listeners) do
      pcall(l, event, snapshot)
    end
  end)
end

local function notify(msg, level)
  if config.get().notify then
    vim.schedule(function()
      vim.notify("devdocs: " .. msg, level or vim.log.levels.INFO)
    end)
  end
end

-- ---------------------------------------------------------------- pure planning

--- Decide what to do for each slug. `installed` maps slug -> meta (or nil).
--- @param slugs string[]
--- @param docs table<string, DevDocsDoc> manifest by slug
--- @param installed table<string, table|nil>
--- @param opts { force?: boolean, update?: boolean }|nil
--- @return { slug: string, action: "install"|"update"|"skip"|"unknown" }[]
function M.plan(slugs, docs, installed, opts)
  opts = opts or {}
  local out = {}
  for _, slug in ipairs(slugs) do
    local doc, meta = docs[slug], installed[slug]
    local action
    if not doc then
      action = "unknown"
    elseif not meta or opts.force then
      action = "install"
    elseif (opts.update or opts.update == nil) and M.is_outdated(meta, doc) then
      action = "update"
    else
      action = "skip"
    end
    out[#out + 1] = { slug = slug, action = action }
  end
  return out
end

--- @param meta table installed meta.json
--- @param doc DevDocsDoc manifest entry
--- @return boolean
function M.is_outdated(meta, doc)
  return type(meta.mtime) == "number" and type(doc.mtime) == "number" and doc.mtime > meta.mtime
end

--- Installed slugs whose manifest entry is newer.
--- @param docs DevDocsDoc[]
--- @return string[]
function M.outdated(docs)
  local by_slug = require("devdocs.manifest").by_slug(docs)
  local out = {}
  for _, slug in ipairs(store.installed()) do
    local meta, doc = store.meta(slug), by_slug[slug]
    if meta and doc and M.is_outdated(meta, doc) then
      out[#out + 1] = slug
    end
  end
  return out
end

-- ---------------------------------------------------------------- the pipeline

local pump

local function finish(job, ok, err)
  job.stage = ok and "done" or "error"
  job.err = err
  job.progress = ok and 1 or job.progress
  M.active = math.max(0, M.active - 1)
  emit(job.stage, job)
  local cbs = job.callbacks
  job.callbacks = {}
  vim.schedule(function()
    for _, cb in ipairs(cbs) do
      pcall(cb, ok, err)
    end
    if ok then
      local hook = config.get().hooks.on_install
      if type(hook) == "function" then
        pcall(hook, job.slug)
      end
    end
  end)
  -- keep done/error jobs visible for the UI until the next start of the same slug
  pump()
end

local function cleanup_tmp(tmp)
  if tmp and vim.uv.fs_stat(tmp) then
    vim.fn.delete(tmp, "rf")
  end
end

-- curl exit codes worth a retry: resolve, connect, timeout, ssl connect, recv, send
local TRANSIENT_CURL = { [6] = true, [7] = true, [28] = true, [35] = true, [52] = true, [55] = true, [56] = true }

local function transient(res)
  return res.status == 429 or res.status >= 500 or TRANSIENT_CURL[res.code or 0] == true
end

local function fail(job, tmp, err, res)
  cleanup_tmp(tmp)
  if res and transient(res) and job.attempt < M.MAX_ATTEMPTS then
    local delay = M.backoff(job.attempt)
    job.attempt = job.attempt + 1
    job.stage = "queued"
    job.err = ("%s (retrying in %ds)"):format(err, delay)
    M.active = math.max(0, M.active - 1)
    emit("progress", job)
    vim.defer_fn(function()
      table.insert(M.queue, 1, job.slug)
      pump()
    end, delay * 1000)
    return
  end
  finish(job, false, err)
end

local function set_stage(job, stage, progress)
  job.stage = stage
  job.progress = progress
  emit("progress", job)
end

--- Move the converted tree into docs/<slug>, replacing any previous install.
local function commit(job, tmp, out)
  local dest = paths.doc_dir(job.slug)
  local old = tmp .. "/old"
  if vim.uv.fs_stat(dest) then
    local ok, err = vim.uv.fs_rename(dest, old)
    if not ok then
      return false, ("could not replace the old install: %s"):format(err)
    end
  end
  vim.fn.mkdir(paths.docs_dir(), "p")
  local ok, err = vim.uv.fs_rename(out, dest)
  if not ok then
    if vim.uv.fs_stat(old) then
      vim.uv.fs_rename(old, dest)
    end
    return false, ("could not move the doc into place: %s"):format(err)
  end
  cleanup_tmp(tmp)
  store.invalidate(job.slug)
  store.update_state(function(st)
    st.enabled[job.slug] = true
    return st
  end)
  return true
end

local function convert(job, tmp, src)
  local cfg = config.get()
  set_stage(job, "convert", 0.4)
  local out = tmp .. "/out"
  local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h:h")
    .. "/scripts/convert_doc.lua"
  local done, total = 0, 0
  local last_line = ""
  vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", script, src, out }, {
    text = true,
    stdout = function(_, data)
      if not data then
        return
      end
      for line in data:gmatch "[^\n]+" do
        last_line = line
        local d, t = line:match "^progress (%d+) (%d+)$"
        if d then
          done, total = tonumber(d), tonumber(t)
          job.progress = 0.4 + 0.55 * (total > 0 and done / total or 0)
          emit("progress", job)
        end
      end
    end,
  }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        local msg = last_line:match "^error (.*)$" or vim.trim(res.stderr or "")
        fail(job, tmp, ("conversion failed: %s"):format(msg ~= "" and msg or ("exit " .. res.code)))
        return
      end
      set_stage(job, "convert", 0.97)
      local ok, err = commit(job, tmp, out)
      if not ok then
        fail(job, tmp, err)
        return
      end
      if cfg.notify then
        local meta = store.meta(job.slug)
        local skipped = meta and meta.skipped and #meta.skipped or 0
        notify(
          ("installed %s (%d pages%s)"):format(
            job.slug,
            meta and meta.page_count or 0,
            skipped > 0 and (", " .. skipped .. " skipped") or ""
          )
        )
      end
      finish(job, true)
    end)
  end)
end

local function download_tarball(job, tmp)
  local cfg = config.get()
  local archive = tmp .. "/doc.tar.gz"
  local src = tmp .. "/src"
  set_stage(job, "download", 0.05)
  fetch.download(
    paths.doc_url(cfg.install.tarball_url, job.slug, ""),
    archive,
    { curl = cfg.install.curl },
    function(res)
      vim.schedule(function()
        if not res.ok then
          fail(job, tmp, ("download failed: %s"):format(res.err), res)
          return
        end
        set_stage(job, "extract", 0.3)
        fetch.untar(archive, src, { tar = cfg.install.tar }, function(ok, err)
          vim.schedule(function()
            if not ok then
              fail(job, tmp, ("extract failed: %s"):format(err))
              return
            end
            os.remove(archive)
            if not vim.uv.fs_stat(src .. "/meta.json") and job.doc then
              store.write_file(src .. "/meta.json", vim.json.encode(job.doc))
            end
            convert(job, tmp, src)
          end)
        end)
      end)
    end
  )
end

local function download_json(job, tmp)
  local cfg = config.get()
  local src = tmp .. "/src"
  set_stage(job, "download", 0.05)
  local files = { "index.json", "db.json" }
  local function step(i)
    if i > #files then
      if job.doc then
        store.write_file(src .. "/meta.json", vim.json.encode(job.doc))
      end
      convert(job, tmp, src)
      return
    end
    fetch.download(
      paths.doc_url(cfg.install.doc_url, job.slug, files[i]),
      src .. "/" .. files[i],
      { curl = cfg.install.curl },
      function(res)
        vim.schedule(function()
          if not res.ok then
            fail(job, tmp, ("download of %s failed: %s"):format(files[i], res.err), res)
            return
          end
          job.progress = 0.05 + 0.15 * i
          emit("progress", job)
          step(i + 1)
        end)
      end
    )
  end
  step(1)
end

local function start(job)
  M.active = M.active + 1
  job.started_at = os.time()
  local tmp = paths.tmp_dir(job.slug)
  cleanup_tmp(tmp)
  vim.fn.mkdir(tmp, "p")
  emit("start", job)
  if config.get().install.source == "json" then
    download_json(job, tmp)
  else
    download_tarball(job, tmp)
  end
end

pump = function()
  local max = math.max(1, config.get().install.max_jobs)
  while M.active < max and #M.queue > 0 do
    local slug = table.remove(M.queue, 1)
    local job = M.jobs[slug]
    if job and job.stage == "queued" then
      start(job)
    end
  end
end

-- ---------------------------------------------------------------- public API

--- @param slug string
--- @return boolean
function M.is_running(slug)
  local j = M.jobs[slug]
  return j ~= nil and j.stage ~= "done" and j.stage ~= "error"
end

--- Install (or reinstall) one doc in the background.
--- @param slug string
--- @param opts { force?: boolean, doc?: DevDocsDoc }|nil
--- @param cb fun(ok: boolean, err: string|nil)|nil
function M.install(slug, opts, cb)
  opts = opts or {}
  cb = cb or function() end
  if not paths.valid_slug(slug) then
    cb(false, ("invalid doc slug %q"):format(tostring(slug)))
    return
  end
  if M.is_running(slug) then
    table.insert(M.jobs[slug].callbacks, cb)
    return
  end
  if store.is_installed(slug) and not opts.force then
    cb(true, "already installed")
    return
  end
  M.jobs[slug] = {
    slug = slug,
    stage = "queued",
    progress = 0,
    attempt = 1,
    doc = opts.doc,
    started_at = os.time(),
    callbacks = { cb },
  }
  M.queue[#M.queue + 1] = slug
  emit("progress", M.jobs[slug])
  pump()
end

--- Install several docs; `cb` runs once with counts when every job settled.
--- @param slugs string[]
--- @param opts { force?: boolean, docs?: table<string, DevDocsDoc> }|nil
--- @param cb fun(summary: { ok: integer, failed: integer, errors: table<string, string> })|nil
function M.install_many(slugs, opts, cb)
  opts = opts or {}
  local pending, summary = #slugs, { ok = 0, failed = 0, errors = {} }
  if pending == 0 then
    if cb then
      cb(summary)
    end
    return
  end
  for _, slug in ipairs(slugs) do
    M.install(slug, { force = opts.force, doc = opts.docs and opts.docs[slug] }, function(ok, err)
      if ok then
        summary.ok = summary.ok + 1
      else
        summary.failed = summary.failed + 1
        summary.errors[slug] = err
      end
      pending = pending - 1
      if pending == 0 and cb then
        cb(summary)
      end
    end)
  end
end

--- Remove an installed doc. Refuses while a job for it runs.
--- @param slug string
--- @return boolean ok, string|nil err
function M.uninstall(slug)
  if not paths.valid_slug(slug) then
    return false, ("invalid doc slug %q"):format(tostring(slug))
  end
  if M.is_running(slug) then
    return false, "an install of this doc is in progress"
  end
  local dir = paths.doc_dir(slug)
  if not vim.uv.fs_stat(dir) then
    return false, "not installed"
  end
  -- belt and braces: only ever delete inside docs_dir()
  assert(vim.startswith(dir, paths.docs_dir() .. "/"))
  if vim.fn.delete(dir, "rf") ~= 0 then
    return false, "could not delete " .. dir
  end
  store.invalidate(slug)
  store.update_state(function(st)
    st.enabled[slug] = nil
    return st
  end)
  M.jobs[slug] = nil
  return true
end

--- Snapshot of every job (queued, running, and the last done/error ones).
--- @return DevDocsJob[]
function M.status()
  local out = {}
  for _, j in pairs(M.jobs) do
    local s = vim.deepcopy(j)
    s.callbacks = nil
    out[#out + 1] = s
  end
  table.sort(out, function(a, b)
    return a.slug < b.slug
  end)
  return out
end

--- @return boolean
function M.is_busy()
  return M.active > 0 or #M.queue > 0
end

--- Forget finished jobs (the UI calls this after showing them).
function M.clear_finished()
  for slug, j in pairs(M.jobs) do
    if j.stage == "done" or j.stage == "error" then
      M.jobs[slug] = nil
    end
  end
end

return M

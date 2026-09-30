--- Mirror (:DevDocs mirror, :DevDocsForceCloneAndScrape): build a complete
--- local copy of devdocs with the freeCodeCamp/devdocs tooling, then
--- install every doc from it. No CDN rate limits, and the raw docs stay on
--- disk for other tools.
---
---   1. git clone (or pull) freeCodeCamp/devdocs into mirror.dir
---   2. docker run the official image with the clone's public/docs mounted,
---      `thor docs:download --all` (or `thor docs:generate <slug>...` with
---      --scrape, which scrapes upstream sites: slow, use for named docs)
---   3. point install.source at the tree (json files via file://) for this
---      session and run install-all
---
--- The shell steps run in a terminal split so the output is visible and
--- can be interrupted; the install-all runs in the background as usual.
local config = require "devdocs.config"
local fetch = require "devdocs.fetch"

local M = {}

local function notify(msg, level)
  vim.notify("devdocs: " .. msg, level or vim.log.levels.INFO)
end

--- @return string
function M.dir()
  local cfg = config.get()
  return cfg.mirror.dir or (cfg.data_dir .. "/mirror/devdocs")
end

--- The install settings that read from a mirror directory.
--- @param dir string
--- @return table install overrides
function M.source_for(dir)
  return {
    source = "json",
    doc_url = "file://" .. dir .. "/public/docs/{slug}/{file}",
    manifest_url = "file://" .. dir .. "/public/docs/docs.json",
  }
end

--- The shell script for the clone + download steps. Pure.
--- @param opts { dir: string, repo: string, image: string, docker: string, git: string, force: boolean, scrape: string[]|nil }
--- @return string
function M.script(opts)
  local q = vim.fn.shellescape
  local lines = {
    "set -euo pipefail",
    ("dir=%s"):format(q(opts.dir)),
    'echo "devdocs mirror: $dir"',
  }
  if opts.force then
    lines[#lines + 1] = 'if [ -d "$dir" ]; then echo "removing the old clone"; rm -rf "$dir"; fi'
  end
  lines[#lines + 1] = ('if [ -d "$dir/.git" ]; then %s -C "$dir" pull --ff-only; else %s clone --depth 1 %s "$dir"; fi'):format(
    q(opts.git),
    q(opts.git),
    q(opts.repo)
  )
  lines[#lines + 1] = 'mkdir -p "$dir/public/docs"'
  lines[#lines + 1] = ('%s info >/dev/null 2>&1 || { echo "docker is not running or not reachable"; exit 3; }'):format(
    q(opts.docker)
  )
  local thor
  if opts.scrape and #opts.scrape > 0 then
    local names = {}
    for _, s in ipairs(opts.scrape) do
      names[#names + 1] = q(s)
    end
    thor = "thor docs:generate " .. table.concat(names, " ")
  else
    thor = "thor docs:download --all"
  end
  lines[#lines + 1] = ('%s run --rm -v "$dir/public/docs:/devdocs/public/docs" %s %s'):format(
    q(opts.docker),
    q(opts.image),
    thor
  )
  lines[#lines + 1] = 'echo "devdocs mirror: done"'
  return table.concat(lines, "\n")
end

--- @param opts { force?: boolean, scrape?: boolean|string[] }|nil
function M.run(opts)
  opts = opts or {}
  local cfg = config.get()
  local dir = M.dir()
  for _, tool in ipairs { cfg.mirror.git, cfg.mirror.docker } do
    if not fetch.available(tool) then
      notify(("%s is not installed; the mirror needs git and docker"):format(tool), vim.log.levels.ERROR)
      return
    end
  end
  local scrape = nil
  if opts.scrape == true then
    scrape =
      vim.split(vim.fn.input "Docs to scrape from upstream (space separated slugs): ", "%s+", { trimempty = true })
    if #scrape == 0 then
      return
    end
  elseif type(opts.scrape) == "table" then
    scrape = opts.scrape
  end
  local msg = opts.force
      and ("Re-clone freeCodeCamp/devdocs into %s and download every doc through its container (several GB)?"):format(
        dir
      )
    or ("Clone/update freeCodeCamp/devdocs in %s and download every doc through its container (several GB)?"):format(
      dir
    )
  if not require("devdocs.ui.float").confirm(msg) then
    return
  end
  local script = M.script {
    dir = dir,
    repo = cfg.mirror.repo,
    image = cfg.mirror.image,
    docker = cfg.mirror.docker,
    git = cfg.mirror.git,
    force = opts.force == true,
    scrape = scrape,
  }
  vim.fn.mkdir(vim.fs.dirname(dir), "p")
  vim.cmd "botright 15split"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.fn.jobstart({ "bash", "-c", script }, {
    term = true,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          notify(("mirror step failed (exit %d); the terminal above has the output"):format(code), vim.log.levels.ERROR)
          return
        end
        M.install_from(dir)
      end)
    end,
  })
end

--- Point this session's installer at a mirror tree and install everything in it.
--- @param dir string
function M.install_from(dir)
  local manifest_file = dir .. "/public/docs/docs.json"
  if not vim.uv.fs_stat(manifest_file) then
    notify(("no docs.json in %s/public/docs; did the download finish?"):format(dir), vim.log.levels.ERROR)
    return
  end
  local cfg = config.get()
  cfg.install = vim.tbl_extend("force", cfg.install, M.source_for(dir))
  notify(
    ("installing from the mirror; to keep using it, set install = { source = %q, doc_url = %q, manifest_url = %q }"):format(
      cfg.install.source,
      cfg.install.doc_url,
      cfg.install.manifest_url
    )
  )
  require("devdocs.manifest").get(function(docs, err)
    if not docs then
      notify(err or "could not read the mirror's docs.json", vim.log.levels.ERROR)
      return
    end
    require("devdocs").install_all { yes = true }
  end, { force = true })
end

return M

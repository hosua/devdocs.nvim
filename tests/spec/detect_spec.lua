local config = require "devdocs.config"
local detect = require "devdocs.detect"
local paths = require "devdocs.paths"
local store = require "devdocs.store"
local version = require "devdocs.version"

local function install_fake(slug, name, version, mtime)
  store.write_json(
    paths.meta_file(slug),
    { slug = slug, name = name, doc_version = version, mtime = mtime or 1 },
    "meta"
  )
  store.write_file(paths.entries_file(slug), "")
end

local function buffer(file, ft)
  local existing = vim.fn.bufnr(file)
  local buf = existing > 0 and existing or vim.api.nvim_create_buf(false, true)
  if existing <= 0 then
    vim.api.nvim_buf_set_name(buf, file)
  end
  vim.bo[buf].filetype = ft
  return buf
end

describe("detect", function()
  local root = tmpdir()
  local project = tmpdir()
  config.resolve { data_dir = root }
  -- no real `python3 --version` etc. in unit tests
  version._run = function()
    return nil
  end
  store.invalidate()
  detect.reset_cache()
  install_fake("python~3.12", "Python", "3.12")
  install_fake("python~3.9", "Python", "3.9")
  install_fake("css", "CSS", "")
  install_fake("node~18_lts", "Node.js", "18 LTS")
  store.invalidate()

  it("finds the project root from .git, else a marker, else none", function()
    vim.fn.mkdir(project .. "/src", "p")
    vim.fn.writefile({ "" }, project .. "/pyproject.toml")
    eq(project, detect.root(buffer(project .. "/src/app.py", "python")))
    eq(nil, detect.root(buffer(tmpdir() .. "/x.py", "python")))
    local repo = tmpdir()
    vim.fn.mkdir(repo .. "/.git", "p")
    vim.fn.mkdir(repo .. "/pkg/web", "p")
    vim.fn.writefile({ "{}" }, repo .. "/pkg/package.json")
    local buf = buffer(repo .. "/pkg/web/a.js", "javascript")
    eq(repo, detect.root(buf))
    eq({ repo .. "/pkg", repo }, detect.version_dirs(buf))
  end)

  it("never treats $HOME (or a dotfiles repo in it) as a project", function()
    local home = tmpdir()
    vim.fn.mkdir(home .. "/.git", "p")
    vim.fn.writefile({ "{}" }, home .. "/package.json")
    local saved = vim.env.HOME
    vim.env.HOME = home
    local ok_, got = pcall(detect.root, buffer(home .. "/.bashrc", "sh"))
    vim.env.HOME = saved
    ok(ok_, tostring(got))
    eq(nil, got)
  end)

  it("picks the installed version matching the project", function()
    vim.fn.writefile({ ".python-version" }, project .. "/.python-version")
    vim.fn.writefile({ "3.9.7" }, project .. "/.python-version")
    detect.reset_cache()
    local b = detect.buffer(buffer(project .. "/src/app.py", "python"))
    eq({ "python" }, b.bases)
    eq({ "python~3.9" }, b.slugs)
    eq({}, b.missing)
    eq("python", b.ft)
  end)

  it("takes the newest installed version without a project hint", function()
    local b = detect.buffer(buffer(tmpdir() .. "/x.py", "python"))
    eq({ "python~3.12" }, b.slugs)
  end)

  it("reports missing bases and keeps order", function()
    local b = detect.buffer(buffer(project .. "/a.ts", "typescript"))
    eq({ "typescript", "javascript", "node", "dom" }, b.bases)
    eq({ "node~18_lts" }, b.slugs)
    eq({ "typescript", "javascript", "dom" }, b.missing)
  end)

  it("scopes lookups to the buffer's own docs", function()
    local order, tiers = detect.lookup_order(buffer(project .. "/x.css", "css"))
    eq({ "css" }, order)
    eq(1, tiers.css)
  end)

  it("searches the newest version of every doc when the language is unknown", function()
    local buf = buffer(tmpdir() .. "/NOTES", "")
    local b = detect.buffer(buf)
    eq(false, b.scoped)
    eq("none", b.how)
    local order, tiers = detect.lookup_order(buf)
    table.sort(order)
    eq({ "css", "node~18_lts", "python~3.12" }, order)
    eq(2, tiers["python~3.12"])
  end)

  it("search order puts the buffer's docs first, then the newest of the rest", function()
    local order, tiers = detect.search_order(buffer(project .. "/x.css", "css"))
    eq("css", order[1])
    eq(1, tiers.css)
    eq(3, #order)
  end)

  it("lookup.scope = 'all' restores every enabled doc", function()
    config.resolve { data_dir = root, lookup = { scope = "all" } }
    detect.reset_cache()
    local order, tiers = detect.lookup_order(buffer(project .. "/x.css", "css"))
    eq("css", order[1])
    eq(2, tiers["python~3.9"])
    eq(4, #order)
    config.resolve { data_dir = root }
    detect.reset_cache()
  end)

  it("caches a buffer's profile until its name or filetype changes", function()
    local buf = buffer(project .. "/cache.py", "python")
    local a = detect.buffer(buf)
    ok(rawequal(a, detect.buffer(buf)), "second call is a cache hit")
    vim.bo[buf].filetype = "css"
    eq({ "css" }, detect.buffer(buf).bases)
  end)

  it("uses a shebang version hint and an installed tool's version", function()
    local dir = tmpdir()
    local buf = buffer(dir .. "/tool", "")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "#!/usr/bin/env python3.9" })
    detect.reset_cache()
    local b = detect.buffer(buf)
    eq("shebang", b.how)
    eq({ "python~3.9" }, b.slugs)
    eq("shebang", b.versions.python.source)
    version._run = function(cmd)
      return cmd[1] == "python3" and "Python 3.9.18" or nil
    end
    local buf2 = buffer(dir .. "/plain.py", "python")
    detect.reset_cache()
    require("devdocs.projects").forget()
    local b2 = detect.buffer(buf2)
    eq({ "python~3.9" }, b2.slugs)
    eq("tool:python3", b2.versions.python.source)
    version._run = function()
      return nil
    end
    require("devdocs.projects").forget()
    detect.reset_cache()
  end)

  it("skips docs disabled in state", function()
    store.update_state(function(st)
      st.enabled["python~3.9"] = false
      return st
    end)
    local b = detect.buffer(buffer(project .. "/src/app.py", "python"))
    eq({ "python~3.12" }, b.slugs)
    eq(3, #detect.enabled_slugs())
    store.update_state(function(st)
      st.enabled["python~3.9"] = nil
      return st
    end)
  end)

  it("resolves what to install from the manifest", function()
    local docs = {
      { slug = "typescript", version = "", name = "TypeScript" },
      { slug = "node", version = "", name = "Node.js" },
      { slug = "node~22_lts", version = "22 LTS", name = "Node.js" },
      { slug = "node~18_lts", version = "18 LTS", name = "Node.js" },
    }
    eq("typescript", detect.slug_to_install("typescript", project, docs).slug)
    vim.fn.writefile({ "v22.1.0" }, project .. "/.nvmrc")
    detect.reset_cache()
    eq("node~22_lts", detect.slug_to_install("node", project, docs).slug)
    eq(nil, detect.slug_to_install("rust", project, docs))
    local missing = detect.missing_docs(buffer(project .. "/a.ts", "typescript"), docs)
    eq(
      { "typescript" },
      vim.tbl_map(function(d)
        return d.slug
      end, missing)
    )
  end)

  it("caches version detection per root", function()
    vim.fn.writefile({ "v20.0.0" }, project .. "/.nvmrc")
    eq("22.1.0", detect.detected_version("node", project))
    detect.reset_cache()
    eq("20.0.0", detect.detected_version("node", project))
  end)
end)

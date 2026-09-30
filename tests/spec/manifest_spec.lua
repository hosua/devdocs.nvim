local config = require "devdocs.config"
local manifest = require "devdocs.manifest"
local paths = require "devdocs.paths"
local store = require "devdocs.store"

local function doc(slug, version, name, alias)
  return {
    name = name or slug:match "^(%a+)",
    slug = slug,
    type = "simple",
    version = version or "",
    release = version or "",
    mtime = 1,
    db_size = 100,
    alias = alias,
  }
end

local DOCS = {
  doc("angular", "", "Angular", "ng"),
  doc("angular~21", "21", "Angular", "ng"),
  doc("bootstrap~5", "5", "Bootstrap"),
  doc("bootstrap~4", "4", "Bootstrap"),
  doc("cpp", "", "C++", "c++"),
  doc("css", "", "CSS"),
  doc("node", "", "Node.js"),
  doc("node~22_lts", "22 LTS", "Node.js"),
  doc("node~8_lts", "8 LTS", "Node.js"),
  doc("python~3.12", "3.12", "Python"),
  doc("python~3.9", "3.9", "Python"),
  doc("python~2.7", "2.7", "Python"),
  doc("scala~2.13_library", "2.13_library", "Scala"),
}

describe("manifest", function()
  local root = tmpdir()
  config.resolve { data_dir = root }

  it("takes the base of a slug", function()
    eq("python", manifest.base "python~3.12")
    eq("css", manifest.base "css")
  end)

  it("orders versions numerically, unversioned newest", function()
    eq(1, manifest.compare_versions("3.12", "3.9"))
    eq(-1, manifest.compare_versions("8 LTS", "22 LTS"))
    eq(1, manifest.compare_versions("", "99"))
    eq(0, manifest.compare_versions("2.13_library", "2.13_reflection"))
    eq(1, manifest.compare_versions("3.10", "3.9.1"))
  end)

  it("lists the versions of a base newest first", function()
    local slugs = vim.tbl_map(function(d)
      return d.slug
    end, manifest.versions(DOCS, "python"))
    eq({ "python~3.12", "python~3.9", "python~2.7" }, slugs)
    eq(
      { "node", "node~22_lts", "node~8_lts" },
      vim.tbl_map(function(d)
        return d.slug
      end, manifest.versions(DOCS, "node"))
    )
    eq({}, manifest.versions(DOCS, "nope"))
    eq(
      { "cpp" },
      vim.tbl_map(function(d)
        return d.slug
      end, manifest.versions(DOCS, "cpp"))
    )
  end)

  it("lists distinct bases in manifest order", function()
    eq({ "angular", "bootstrap", "cpp", "css", "node", "python", "scala" }, manifest.bases(DOCS))
  end)

  it("finds by slug, base, alias and name (newest version)", function()
    eq("python~3.9", manifest.find(DOCS, "python~3.9").slug)
    eq("python~3.12", manifest.find(DOCS, "python").slug)
    eq("python~3.12", manifest.find(DOCS, "Python").slug)
    eq("cpp", manifest.find(DOCS, "c++").slug)
    eq("bootstrap~5", manifest.find(DOCS, "bootstrap").slug)
    eq("angular", manifest.find(DOCS, "ng").slug)
    eq(nil, manifest.find(DOCS, "rust"))
    eq(nil, manifest.find(DOCS, ""))
  end)

  it("globs case-insensitively over slug, base, name and alias", function()
    local function slugs(pattern)
      local out = vim.tbl_map(function(d)
        return d.slug
      end, manifest.glob(DOCS, pattern))
      table.sort(out)
      return out
    end
    eq({ "python~2.7", "python~3.12", "python~3.9" }, slugs "python*")
    eq({ "python~3.12", "python~3.9" }, slugs "python~3*")
    eq({ "bootstrap~4", "bootstrap~5" }, slugs "Bootstrap")
    eq({ "node~22_lts" }, slugs "node~22_lts")
    eq({ "cpp" }, slugs "C++")
    eq({ "node", "node~22_lts", "node~8_lts" }, slugs "*ODE*")
    eq({}, slugs "zzz")
  end)

  it("normalizes null fields the way docs.json ships them", function()
    local raw =
      vim.json.decode '[{"slug":"css","name":"CSS","version":null,"alias":null,"mtime":1,"db_size":2},{"slug":"x"},"junk"]'
    local docs = manifest.normalize(raw)
    eq(2, #docs)
    eq({ name = "CSS", slug = "css", type = "", version = "", release = "", mtime = 1, db_size = 2 }, docs[1])
    eq("x", docs[2].name)
    eq(
      { "css" },
      vim.tbl_map(function(d)
        return d.slug
      end, manifest.glob(docs, "CSS"))
    )
  end)

  it("reports no cache and no freshness on a clean data dir", function()
    eq(nil, (manifest.cached()))
    eq(false, manifest.is_fresh())
  end)

  it("fetches from a file:// url, caches, and honours the ttl", function()
    local src = root .. "/docs.json"
    store.write_file(src, vim.json.encode(DOCS))
    local got, gerr
    manifest.fetch(function(d, e)
      got, gerr = d, e
    end, { url = "file://" .. src, now = 1000 })
    ok(
      vim.wait(5000, function()
        return got ~= nil or gerr ~= nil
      end),
      "fetch did not complete"
    )
    eq(nil, gerr)
    eq(#DOCS, #got)
    local cached, at = manifest.cached()
    eq(#DOCS, #cached)
    eq(1000, at)
    ok(manifest.is_fresh(1000 + 10))
    ok(not manifest.is_fresh(1000 + config.get().install.manifest_ttl + 1))
  end)

  it("get() answers synchronously from a fresh cache", function()
    local answered
    manifest.get(function(d)
      answered = #d
    end, { now = 1000 })
    eq(#DOCS, answered)
  end)

  it("falls back to the stale cache when the fetch fails", function()
    local got, gerr
    manifest.fetch(function(d, e)
      got, gerr = d, e
    end, { url = "file://" .. root .. "/missing.json" })
    ok(
      vim.wait(5000, function()
        return gerr ~= nil
      end),
      "fetch did not complete"
    )
    eq(#DOCS, #got)
    ok(gerr:find("could not fetch", 1, true), gerr)
    eq(nil, vim.uv.fs_stat(paths.data_dir() .. "/manifest.download.json.part"))
  end)
end)

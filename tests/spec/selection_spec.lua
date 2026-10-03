local selection = require "devdocs.ui.selection"

-- Hand-built rows in the shape model.rows emits (group / lang / doc), so these
-- tests do not depend on how the model groups things.
local function drow(slug, installed, extra)
  local r = {
    kind = "doc",
    slug = slug,
    base = (slug:match "^([^~]+)") or slug,
    doc = { slug = slug, name = slug, version = slug:match "~(.*)$" or "" },
    meta = installed and { name = slug } or nil,
    status = installed and "installed" or "available",
  }
  return vim.tbl_extend("force", r, extra or {})
end

local function lrow(base, children)
  local n = 0
  for _, c in ipairs(children) do
    if c.meta then
      n = n + 1
    end
  end
  return { kind = "lang", base = base, name = base, children = children, expanded = false, installed_count = n }
end

local PY = { drow("python~3.12", true), drow("python~3.11", true), drow("python~3.9", false) }
local ROWS = {
  { kind = "group", label = "Installed", count = 2 },
  lrow("python", PY),
  PY[1],
  PY[2],
  PY[3],
  drow("css", true),
  { kind = "group", label = "Available", count = 1 },
  drow("rust", false),
}

describe("selection.toggle", function()
  it("marks and unmarks an installed doc row without mutating the input", function()
    local marked = {}
    local m1 = selection.toggle(marked, drow("css", true))
    eq({ css = true }, m1)
    eq({}, marked)
    local m2 = selection.toggle(m1, drow("css", true))
    eq({}, m2)
    eq({ css = true }, m1)
  end)

  it("ignores not-installed doc rows, group rows and nil", function()
    eq({}, selection.toggle({}, drow("rust", false)))
    eq({}, selection.toggle({}, { kind = "group", label = "Installed", count = 1 }))
    eq({ a = true }, selection.toggle({ a = true }, nil))
  end)

  it("a lang row marks every installed child, or unmarks them when all are marked", function()
    local m1 = selection.toggle({}, ROWS[2])
    eq({ ["python~3.12"] = true, ["python~3.11"] = true }, m1)
    eq({}, selection.toggle(m1, ROWS[2]))
    -- partially marked -> marks the rest
    eq(
      { ["python~3.12"] = true, ["python~3.11"] = true, css = true },
      selection.toggle({ ["python~3.11"] = true, css = true }, ROWS[2])
    )
  end)

  it("treats a nil marked table as empty", function()
    eq({ css = true }, selection.toggle(nil, drow("css", true)))
  end)
end)

describe("selection.mark_range / range_targets", function()
  it("collects installed slugs from doc and lang rows in the range, sorted and deduped", function()
    eq({ "css", "python~3.11", "python~3.12" }, selection.range_targets(ROWS, 1, 8))
    eq({ "python~3.11", "python~3.12" }, selection.range_targets(ROWS, 2, 3))
    eq({}, selection.range_targets(ROWS, 7, 8))
  end)

  it("accepts the range in either order and clamps it to the rows", function()
    eq({ "css", "python~3.11" }, selection.range_targets(ROWS, 6, 4))
    eq({ "css" }, selection.range_targets(ROWS, 6, 99))
    eq({}, selection.range_targets(ROWS, -3, 0))
  end)

  it("marks every installed row in the range", function()
    eq({ css = true, ["python~3.11"] = true, x = true }, selection.mark_range({ x = true }, ROWS, 4, 7))
  end)

  it("unmarks the range when everything in it is already marked", function()
    local all = { css = true, ["python~3.11"] = true, ["python~3.12"] = true }
    eq({ ["python~3.12"] = true }, selection.mark_range(all, ROWS, 4, 6))
  end)

  it("does not mutate its input", function()
    local m = { x = true }
    selection.mark_range(m, ROWS, 1, 8)
    eq({ x = true }, m)
  end)
end)

describe("selection.targets / cleanup / count", function()
  it("lists marked slugs sorted, skipping false values", function()
    eq({ "a", "b~2", "c" }, selection.targets { c = true, a = true, ["b~2"] = true, z = false })
    eq({}, selection.targets(nil))
  end)

  it("cleanup drops marks for slugs that are no longer installed", function()
    eq({ a = true }, selection.cleanup({ a = true, b = true }, { a = {}, c = {} }))
    eq({}, selection.cleanup(nil, { a = {} }))
  end)

  it("count", function()
    eq(0, selection.count(nil))
    eq(2, selection.count { a = true, b = true })
  end)
end)

local function mdoc(slug, version)
  return { slug = slug, version = version, name = slug, db_size = 10 }
end

describe("selection.prune_targets", function()
  local DOCS = {
    mdoc("python~3.13", "3.13"),
    mdoc("python~3.12", "3.12"),
    mdoc("python~3.9", "3.9"),
    mdoc("node", ""),
    mdoc("node~22_lts", "22 LTS"),
    mdoc("node~20_lts", "20 LTS"),
    mdoc("css", ""),
    mdoc("lua~5.4", "5.4"),
    mdoc("lua~5.1", "5.1"),
  }

  it("keeps the manifest's newest version when it is installed", function()
    local installed = { ["python~3.13"] = {}, ["python~3.12"] = {}, ["python~3.9"] = {} }
    eq({ "python~3.12", "python~3.9" }, selection.prune_targets(installed, DOCS))
  end)

  it("the unversioned slug counts as the newest", function()
    local installed = { node = {}, ["node~22_lts"] = {}, ["node~20_lts"] = {} }
    eq({ "node~20_lts", "node~22_lts" }, selection.prune_targets(installed, DOCS))
  end)

  it("keeps the newest installed version when the current one is not installed", function()
    local installed = { ["python~3.12"] = {}, ["python~3.9"] = {} }
    eq({ "python~3.9" }, selection.prune_targets(installed, DOCS))
    local node = { ["node~22_lts"] = {}, ["node~20_lts"] = {} }
    eq({ "node~20_lts" }, selection.prune_targets(node, DOCS))
  end)

  it("leaves a language with one installed version alone", function()
    eq({}, selection.prune_targets({ css = {}, ["lua~5.1"] = {} }, DOCS))
  end)

  it("counts disabled docs as installed (installed = has meta)", function()
    -- the disabled flag lives in state.json, not in meta: a disabled 3.13 is still the one kept
    local installed = { ["python~3.13"] = { name = "Python" }, ["python~3.9"] = { name = "Python" } }
    eq({ "python~3.9" }, selection.prune_targets(installed, DOCS))
  end)

  it("restricts to the given bases (string or list)", function()
    local installed = { ["python~3.13"] = {}, ["python~3.9"] = {}, ["lua~5.4"] = {}, ["lua~5.1"] = {} }
    eq({ "lua~5.1", "python~3.9" }, selection.prune_targets(installed, DOCS))
    eq({ "lua~5.1" }, selection.prune_targets(installed, DOCS, "lua"))
    eq({ "python~3.9" }, selection.prune_targets(installed, DOCS, { "python" }))
    eq({}, selection.prune_targets(installed, DOCS, { "rust" }))
  end)

  it("works for docs the manifest no longer lists, using meta.doc_version or the slug suffix", function()
    local installed = {
      ["go~1.22"] = { doc_version = "1.22" },
      ["go~1.9"] = { doc_version = "1.9" },
      ["zig~0.13"] = {},
      ["zig~0.9"] = {},
    }
    eq({ "go~1.9", "zig~0.9" }, selection.prune_targets(installed, {}))
    eq({ "go~1.9", "zig~0.9" }, selection.prune_targets(installed, nil))
  end)

  it("returns nothing for nothing installed", function()
    eq({}, selection.prune_targets({}, DOCS))
    eq({}, selection.prune_targets(nil, DOCS))
  end)
end)

describe("selection.confirm_message", function()
  it("names the count, the size and every slug", function()
    local msg = selection.confirm_message({ "python~3.9", "lua~5.1" }, 12.5e6, "/data/docs")
    ok(msg:find("Delete 2 docs", 1, true), msg)
    ok(msg:find("12.5 MB", 1, true), msg)
    ok(msg:find("python~3.9", 1, true), msg)
    ok(msg:find("lua~5.1", 1, true), msg)
    ok(msg:find("/data/docs", 1, true), msg)
  end)

  it("singular, and no size when unknown", function()
    local msg = selection.confirm_message({ "css" }, nil, "/d")
    ok(msg:find("Delete 1 doc ", 1, true) or msg:find("Delete 1 doc?", 1, true), msg)
    ok(not msg:find("MB", 1, true), msg)
  end)

  it("wraps a long list onto several lines and keeps every slug", function()
    local slugs = {}
    for i = 1, 40 do
      slugs[i] = ("doc~%d.0"):format(i)
    end
    local msg = selection.confirm_message(slugs, 1e9, "/d")
    for _, s in ipairs(slugs) do
      ok(msg:find(s .. ",", 1, true) or msg:find(s .. "\n", 1, true) or vim.endswith(msg, s), s)
    end
    for _, line in ipairs(vim.split(msg, "\n")) do
      ok(#line <= 80, "line too long: " .. line)
    end
  end)
end)

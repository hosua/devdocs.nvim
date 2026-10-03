local model = require "devdocs.ui.model"

local function doc(slug, version, name, size, mtime)
  return {
    slug = slug,
    version = version or "",
    name = name or slug,
    db_size = size or 1000,
    mtime = mtime or 10,
    type = "x",
  }
end

local DOCS = {
  doc("css", "", "CSS", 15e6),
  doc("python~3.12", "3.12", "Python", 18e6),
  doc("python~3.9", "3.9", "Python", 15e6),
  doc("python~2.7", "2.7", "Python", 6e6),
  doc("node", "", "Node.js", 7e6),
  doc("node~22_lts", "22 LTS", "Node.js", 6e6),
  doc("rust", "", "Rust", 70e6, 20),
  doc("angular", "", "Angular", 8e6),
}

--- "[Group]" for section headers, "@base" for language rows, the slug for versions.
local function slugs(rows)
  return vim.tbl_map(function(r)
    if r.kind == "group" then
      return "[" .. r.label .. "]"
    elseif r.kind == "lang" then
      return "@" .. r.base
    end
    return r.slug
  end, rows)
end

local function child_slugs(row)
  return vim.tbl_map(function(c)
    return c.slug
  end, row.children)
end

local function find(rows, kind, key)
  for i, r in ipairs(rows) do
    if r.kind == kind and (r.base == key or r.slug == key) then
      return r, i
    end
  end
end

describe("list model", function()
  local base = model.new {
    docs = DOCS,
    installed = { css = { mtime = 10, name = "CSS" }, rust = { mtime = 5, name = "Rust" } },
    jobs = { ["python~3.12"] = { slug = "python~3.12", stage = "convert", progress = 0.5 } },
    height = 5,
    width = 80,
  }

  it("lists each language once: Installed (any version installed or busy), then Available", function()
    local rows = model.rows(base)
    eq({ "[Installed]", "@css", "@python", "@rust", "[Available]", "@angular", "@node" }, slugs(rows))
    eq(3, rows[1].count)
    eq(2, rows[5].count)
    eq("installing", rows[3].status)
    eq("outdated", rows[4].status)
    eq("installed", rows[2].status)
    eq("available", rows[6].status)
    eq("Python", rows[3].name)
    eq({ "python~3.12", "python~3.9", "python~2.7" }, child_slugs(rows[3]))
    eq({ "node", "node~22_lts" }, child_slugs(rows[7]))
    eq(false, rows[7].expanded)
    for _, c in ipairs(rows[3].children) do
      eq("doc", c.kind)
      eq(1, c.depth)
      eq("python", c.base)
    end
  end)

  it("aggregates installed size and count, and hints the newest size otherwise", function()
    local s = model.new {
      docs = DOCS,
      installed = {
        ["python~3.9"] = { mtime = 10, name = "Python", db_size = 15e6 },
        ["python~2.7"] = { mtime = 10, name = "Python" }, -- falls back to the manifest size
      },
    }
    local rows = model.rows(s)
    local py = find(rows, "lang", "python")
    eq(2, py.installed_count)
    eq(21e6, py.installed_size)
    eq(18e6, py.size_hint)
    local node = find(rows, "lang", "node")
    eq(0, node.installed_count)
    eq(0, node.installed_size)
    eq(7e6, node.size_hint)
  end)

  it("aggregate status: installing > error > outdated > installed > disabled > available", function()
    local function status(installed, jobs, disabled)
      local s = model.new { docs = DOCS, installed = installed, jobs = jobs or {}, disabled = disabled or {} }
      return find(model.rows(s), "lang", "python").status
    end
    local m = { mtime = 10 }
    local old = { mtime = 1 }
    eq("available", status {})
    eq("installed", status { ["python~3.9"] = m })
    eq("disabled", status({ ["python~3.9"] = m }, nil, { ["python~3.9"] = true }))
    eq("installed", status({ ["python~3.9"] = m, ["python~2.7"] = m }, nil, { ["python~3.9"] = true }))
    eq("outdated", status { ["python~3.9"] = m, ["python~2.7"] = old })
    eq("error", status({ ["python~3.9"] = old }, { ["python~2.7"] = { stage = "error", err = "x" } }))
    eq(
      "installing",
      status({ ["python~3.9"] = old }, {
        ["python~2.7"] = { stage = "error", err = "x" },
        ["python~3.12"] = { stage = "download" },
      })
    )
  end)

  it("merges installed docs that the manifest no longer lists", function()
    local s = model.new {
      docs = DOCS,
      installed = {
        ["python~3.6"] = { name = "Python", doc_version = "3.6", db_size = 1e6, mtime = 1 },
        gone = { name = "Gone", doc_version = "", db_size = 2e6, mtime = 1 },
      },
    }
    local rows = model.rows(s)
    eq({ "python~3.12", "python~3.9", "python~3.6", "python~2.7" }, child_slugs(find(rows, "lang", "python")))
    local gone = find(rows, "lang", "gone")
    eq("Gone", gone.name)
    eq("installed", gone.status)
    eq(2e6, gone.installed_size)
  end)

  it("marks the unversioned slug as DevDocs' current version", function()
    local node = find(model.rows(base), "lang", "node")
    eq(true, node.children[1].current)
    eq(false, node.children[2].current)
  end)

  it("target(): the installed current version, else a busy one, else the newest", function()
    local rows = model.rows(base)
    eq("node", model.target(find(rows, "lang", "node")).slug)
    eq("python~3.12", model.target(find(rows, "lang", "python")).slug)
    eq("css", model.target(find(rows, "lang", "css")).slug)
    eq(nil, model.target(rows[1]))
    local s = model.new {
      docs = DOCS,
      installed = { ["python~3.9"] = { mtime = 10 }, ["python~2.7"] = { mtime = 10 }, ["node~22_lts"] = { mtime = 10 } },
    }
    rows = model.rows(s)
    eq("python~3.9", model.target(find(rows, "lang", "python")).slug)
    eq("node~22_lts", model.target(find(rows, "lang", "node")).slug)
    local s2 = model.new { docs = DOCS, installed = { node = { mtime = 10 }, ["node~22_lts"] = { mtime = 10 } } }
    eq("node", model.target(find(model.rows(s2), "lang", "node")).slug)
    local child = find(model.rows(s2), "lang", "node").children[2]
    eq(child, model.target(child))
  end)

  it("counts languages for the header", function()
    eq({ installed = 2, installing = 1, outdated = 1, available = 3 }, model.counts(base))
  end)

  it("filters case-insensitively on slug, name and alias", function()
    local s = model.reduce(base, { type = "filter", text = "PYTH" })
    eq({ "[Installed]", "@python" }, slugs(model.rows(s)))
    local d = vim.deepcopy(DOCS)
    d[8].alias = "ng"
    local s2 = model.reduce(model.new { docs = d }, { type = "filter", text = "ng" })
    eq({ "[Available]", "@angular" }, slugs(model.rows(s2)))
    local none = model.reduce(base, { type = "filter", text = "zzz" })
    eq({}, model.rows(none))
    eq(1, none.cursor)
  end)

  it("expands a language into its versions and collapses back from a child", function()
    local s = model.reduce(base, { type = "goto", row = 3 })
    eq("python", model.current(s).base)
    eq("lang", model.current(s).kind)
    s = model.reduce(s, { type = "toggle_expand" })
    local rows = model.rows(s)
    eq({ "@python", "python~3.12", "python~3.9", "python~2.7", "@rust" }, vim.list_slice(slugs(rows), 3, 7))
    eq(true, rows[3].expanded)
    eq(1, rows[5].depth)
    eq(3, s.cursor, "cursor stays on the language row")
    s = model.reduce(s, { type = "move", n = 2 })
    eq("python~3.9", model.current(s).slug)
    s = model.reduce(s, { type = "toggle_expand" })
    eq(7, #model.rows(s))
    eq(3, s.cursor, "collapsing from a child moves to its language row")
    -- l expands, h collapses (from the language row or a child)
    s = model.reduce(s, { type = "expand" })
    eq(10, #model.rows(s))
    s = model.reduce(s, { type = "expand" })
    eq(10, #model.rows(s), "expand is idempotent")
    s = model.reduce(s, { type = "move", n = 3 })
    eq("python~2.7", model.current(s).slug)
    s = model.reduce(s, { type = "collapse" })
    eq(7, #model.rows(s))
    eq(3, s.cursor)
    -- single-version languages have nothing to expand
    local c = model.reduce(base, { type = "goto", row = 2 })
    eq(c, model.reduce(c, { type = "toggle_expand" }))
    eq(false, model.rows(c)[2].expanded)
  end)

  it("a filter with ~ expands the matching versions", function()
    local v = model.reduce(base, { type = "filter", text = "python~" })
    eq({ "[Installed]", "@python", "python~3.12", "python~3.9", "python~2.7" }, slugs(model.rows(v)))
    local v3 = model.reduce(base, { type = "filter", text = "python~3" })
    eq({ "[Installed]", "@python", "python~3.12", "python~3.9" }, slugs(model.rows(v3)))
    eq(3, #model.rows(v3)[2].children, "children still carry every version")
  end)

  it("lang rows list the versions that pass the filter in `visible`", function()
    local rows = model.rows(base)
    local py = find(rows, "lang", "python")
    eq(
      { "python~3.12", "python~3.9", "python~2.7" },
      vim.tbl_map(function(c)
        return c.slug
      end, py.visible)
    )
    local f = model.reduce(base, { type = "filter", text = "3.9" })
    py = find(model.rows(f), "lang", "python")
    eq(false, py.expanded, "a filter without ~ leaves the language folded")
    eq(
      { "python~3.9" },
      vim.tbl_map(function(c)
        return c.slug
      end, py.visible)
    )
    eq(3, #py.children, "children still carry every version")
  end)

  it("expanding the last visible language scrolls its versions into view", function()
    -- 5 rows tall: [Installed] @css @python @rust [Available]; python is row 3
    local s = model.reduce(base, { type = "goto", row = 3 })
    s = vim.tbl_extend("force", s, { height = 3, top = 1 })
    local e = model.reduce(s, { type = "expand" })
    eq(3, e.cursor, "cursor stays on the language")
    eq(3, e.top, "the language row and as many versions as fit")
    s = vim.tbl_extend("force", s, { height = 5, top = 1 })
    e = model.reduce(s, { type = "toggle_expand" })
    eq(2, e.top, "every version fits: the window ends on the last one")
    eq(6, e.top + e.height - 1)
    s = vim.tbl_extend("force", s, { height = 20, top = 1 })
    eq(1, model.reduce(s, { type = "expand" }).top, "no scroll when it all fits already")
  end)

  it("release_dates merges into the known dates instead of replacing them", function()
    local s = model.reduce(base, { type = "release_dates", dates = { css = { date = "2026-01-01", exact = true } } })
    s = model.reduce(s, { type = "release_dates", dates = { rust = { date = "2025-01-01", exact = false } } })
    eq({ "css", "rust" }, vim.fn.sort(vim.tbl_keys(s.release_dates)))
    s = model.reduce(s, { type = "release_dates", dates = { css = { date = "2026-02-02", exact = true } } })
    eq("2026-02-02", s.release_dates.css.date)
    eq("2025-01-01", s.release_dates.rust.date)
    eq({}, base.release_dates, "does not mutate the previous state")
  end)

  it("sorts by name or size (installed size, else the newest version's size)", function()
    local s = model.reduce(base, { type = "sort" })
    eq("size", s.sort)
    eq({ "[Installed]", "@rust", "@python", "@css", "[Available]", "@angular", "@node" }, slugs(model.rows(s)))
    eq("name", model.reduce(s, { type = "sort" }).sort)
  end)

  it("moves the cursor over language rows only and scrolls the window", function()
    local s = base
    eq(2, s.cursor, "starts on the first language row")
    s = model.reduce(s, { type = "move", n = 1 })
    eq(3, s.cursor)
    s = model.reduce(s, { type = "move", n = 10 })
    eq(7, s.cursor)
    eq(3, s.top, "scrolled so the cursor is visible in 5 rows")
    s = model.reduce(s, { type = "top" })
    eq(2, s.cursor)
    eq(1, s.top)
    s = model.reduce(s, { type = "bottom" })
    eq(7, s.cursor)
    s = model.reduce(s, { type = "page", n = -1 })
    eq(2, s.cursor)
    s = model.reduce(s, { type = "next_group" })
    eq(6, s.cursor)
    s = model.reduce(s, { type = "prev_group" })
    eq(2, s.cursor)
  end)

  it("replaces data and clamps", function()
    local s = model.reduce(base, { type = "bottom" })
    s = model.reduce(s, { type = "data", data = { docs = { DOCS[1] }, installed = {}, jobs = {} } })
    eq({ "[Available]", "@css" }, slugs(model.rows(s)))
    eq(2, s.cursor)
    eq(nil, model.current(model.new()))
  end)

  it("defaults the marked and release_dates tables", function()
    local s = model.new()
    eq({}, s.marked)
    eq({}, s.release_dates)
  end)

  it("reports disabled and error statuses", function()
    local s = model.new {
      docs = DOCS,
      installed = { css = { mtime = 10 } },
      disabled = { css = true },
      jobs = { angular = { slug = "angular", stage = "error", err = "boom" } },
    }
    eq("disabled", model.status(s, "css", DOCS[1]))
    eq("error", model.status(s, "angular", DOCS[8]))
    local rows = model.rows(s)
    eq({ "[Installed]", "@angular", "@css" }, vim.list_slice(slugs(rows), 1, 3))
    eq("error", rows[2].status)
    eq("disabled", rows[3].status)
  end)
end)

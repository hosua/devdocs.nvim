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

local function slugs(rows)
  return vim.tbl_map(function(r)
    return r.kind == "group" and ("[" .. r.label .. "]") or r.slug
  end, rows)
end

describe("list model", function()
  local base = model.new {
    docs = DOCS,
    installed = { css = { mtime = 10, name = "CSS" }, rust = { mtime = 5, name = "Rust" } },
    jobs = { ["python~3.12"] = { slug = "python~3.12", stage = "convert", progress = 0.5 } },
    height = 5,
    width = 80,
  }

  it("groups rows: installing, outdated, installed, available (one per base)", function()
    eq({
      "[Installing]",
      "python~3.12",
      "[Outdated]",
      "rust",
      "[Installed]",
      "css",
      "[Available]",
      "angular",
      "node",
      "python~3.9",
    }, slugs(model.rows(base)))
    local rows = model.rows(base)
    eq(2, rows[9].versions) -- node + node~22_lts collapsed
    eq(2, rows[10].versions) -- python 3.9 and 2.7 (3.12 is installing)
    eq("installing", rows[2].status)
    eq("outdated", rows[4].status)
  end)

  it("counts for the header", function()
    eq({ installed = 1, installing = 1, outdated = 1, available = 3 }, model.counts(base))
  end)

  it("filters case-insensitively on slug, name and alias", function()
    local s = model.reduce(base, { type = "filter", text = "PYTH" })
    eq({ "[Installing]", "python~3.12", "[Available]", "python~3.9" }, slugs(model.rows(s)))
    local d = vim.deepcopy(DOCS)
    d[8].alias = "ng"
    local s2 = model.reduce(model.new { docs = d }, { type = "filter", text = "ng" })
    eq({ "[Available]", "angular" }, slugs(model.rows(s2)))
    local none = model.reduce(base, { type = "filter", text = "zzz" })
    eq({}, model.rows(none))
    eq(1, none.cursor)
  end)

  it("expands a base into its versions and keeps the cursor on it", function()
    local s = model.reduce(base, { type = "goto", row = 10 })
    eq("python~3.9", model.current(s).slug)
    s = model.reduce(s, { type = "toggle_expand" })
    eq({ "python~3.9", "python~2.7" }, vim.list_slice(slugs(model.rows(s)), 10, 11))
    eq("python~3.9", model.current(s).slug)
    s = model.reduce(s, { type = "toggle_expand" })
    eq(10, #model.rows(s))
    -- a filter with ~ shows every version
    local v = model.reduce(base, { type = "filter", text = "python~" })
    eq({ "[Installing]", "python~3.12", "[Available]", "python~3.9", "python~2.7" }, slugs(model.rows(v)))
  end)

  it("sorts by name or size", function()
    local s = model.reduce(base, { type = "sort" })
    eq("size", s.sort)
    eq({ "python~3.9", "angular", "node" }, vim.list_slice(slugs(model.rows(s)), 8, 10))
    eq("name", model.reduce(s, { type = "sort" }).sort)
  end)

  it("moves the cursor over doc rows only and scrolls the window", function()
    local s = base
    eq(2, s.cursor, "starts on the first doc row")
    s = model.reduce(s, { type = "move", n = 1 })
    eq(4, s.cursor, "skips the group header")
    s = model.reduce(s, { type = "move", n = 10 })
    eq(10, s.cursor)
    eq(6, s.top, "scrolled so the cursor is visible in 5 rows")
    s = model.reduce(s, { type = "top" })
    eq(2, s.cursor)
    eq(1, s.top)
    s = model.reduce(s, { type = "bottom" })
    eq(10, s.cursor)
    s = model.reduce(s, { type = "page", n = -1 })
    eq(4, s.cursor)
    s = model.reduce(s, { type = "next_group" })
    eq(6, s.cursor)
    s = model.reduce(s, { type = "prev_group" })
    eq(4, s.cursor)
  end)

  it("replaces data and clamps", function()
    local s = model.reduce(base, { type = "bottom" })
    s = model.reduce(s, { type = "data", data = { docs = { DOCS[1] }, installed = {}, jobs = {} } })
    eq({ "[Available]", "css" }, slugs(model.rows(s)))
    eq(2, s.cursor)
    eq(nil, model.current(model.new()))
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
    eq({ "[Installing]", "angular", "[Installed]", "css" }, vim.list_slice(slugs(model.rows(s)), 1, 4))
  end)
end)

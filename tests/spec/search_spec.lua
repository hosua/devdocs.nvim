local config = require "devdocs.config"
local paths = require "devdocs.paths"
local search = require "devdocs.search"
local store = require "devdocs.store"

local function install_fake(slug, name, pages, entries)
  store.write_json(paths.meta_file(slug), { slug = slug, name = name }, "meta")
  store.write_file(paths.entries_file(slug), store.encode_entries(entries or {}))
  for page, lines in pairs(pages) do
    store.write_file(paths.page_file(slug, page), table.concat(lines, "\n") .. "\n")
  end
end

local function grep(query, slugs, opts)
  local got, gerr
  search.grep(query, slugs, opts, function(hits, err)
    got, gerr = hits, err
  end)
  assert(
    vim.wait(10000, function()
      return got ~= nil
    end),
    "grep never returned"
  )
  return got, gerr
end

describe("search", function()
  local root = tmpdir()
  config.resolve { data_dir = root }
  store.invalidate()
  install_fake("css", "CSS", {
    ["properties/grid"] = {
      "# grid",
      "",
      "The grid shorthand sets Grid Template Areas.",
      "grid-template-areas: none;",
    },
    ["selectors/:default"] = { "# :default", "", "Matches default UI elements in a grid of controls." },
  }, {
    { name = "grid", path = "properties/grid", type = "Properties" },
    { name = "grid-area", path = "properties/grid-area", type = "Properties" },
  })
  install_fake("lua~5.4", "Lua", {
    index = { "# Lua", "", "table.concat joins a grid of strings.", "string.format" },
  }, { { name = "table.concat()", path = "index#pdf-table.concat", type = "Standard Libraries" } })
  store.invalidate()

  it("parses an @slug prefix", function()
    eq({ "css", "grid gap" }, { search.parse_query "@css grid gap" })
    eq({ "python~3.12", "" }, { search.parse_query "@python~3.12" })
    eq({ nil, "grid" }, { search.parse_query "grid" })
  end)

  it("matches entry names, buffer docs first", function()
    local hits = search.entries("grid", { "css", "lua~5.4" })
    eq("grid", hits[1].entry.name)
    eq("css", hits[1].slug)
    eq({}, search.entries("", { "css" }))
  end)

  if vim.fn.executable "rg" == 1 then
    it("greps pages with ripgrep, ordered by slug priority", function()
      local hits, err = grep("grid", { "lua~5.4", "css" })
      eq(nil, err)
      ok(#hits >= 3, vim.inspect(hits))
      eq("lua~5.4", hits[1].slug)
      eq("index", hits[1].page)
      eq(3, hits[1].line)
      ok(hits[1].text:find("grid", 1, true))
      eq("css", hits[2].slug)
      local pages = {}
      for _, h in ipairs(hits) do
        pages[h.slug .. "/" .. h.page] = true
      end
      ok(pages["css/selectors/:default"], "encoded page names decode back")
    end)

    it("is case-insensitive for lowercase queries and literal by default", function()
      local hits = grep("template areas", { "css" })
      eq(1, #hits)
      eq(3, hits[1].line)
      eq(0, #grep("grid.*none", { "css" }))
      eq(1, #grep("grid.*none", { "css" }, { regex = true }))
    end)

    it("honours max_results and reports nothing installed", function()
      eq(1, #grep("grid", { "css", "lua~5.4" }, { max_results = 1 }))
      local hits, err = grep("grid", { "nope" })
      eq({}, hits)
      ok(err ~= nil)
      eq({}, (grep("", { "css" })))
    end)
  else
    it("skips ripgrep specs: rg is not installed", function()
      ok(true)
    end)
  end
end)

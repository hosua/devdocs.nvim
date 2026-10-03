local classify = require "devdocs.classify"
local config = require "devdocs.config"
local detect = require "devdocs.detect"
local index = require "devdocs.index"
local lookup = require "devdocs.lookup"
local picker = require "devdocs.ui.picker"
local rank = require "devdocs.rank"
local symbols = require "devdocs.symbols"
local viewer = require "devdocs.ui.viewer"

local HIT = { slug = "lua~5.4", entry = { name = "count", path = "index#count" } }

--- Run fn with lookup's collaborators stubbed; returns what was called.
--- @param o { class?: string, hover?: boolean, hits?: table[], sources?: integer, smart?: boolean, fallback?: string }
local function scenario(o, fn)
  local calls = { classify = 0, hover = 0, docs = 0, open = 0, search = {}, notify = {} }
  local saved = {
    cursor = classify.cursor,
    candidates = symbols.candidates,
    buffer = detect.buffer,
    order = detect.lookup_order,
    sources = index.sources,
    rlookup = rank.lookup,
    decisive = rank.decisive,
    vopen = viewer.open,
    pick = picker.pick_hits,
    clients = vim.lsp.get_clients,
    hover = vim.lsp.buf.hover,
    notify = vim.notify,
    search = require("devdocs").search,
  }
  config.resolve { lookup = { smart = o.smart ~= false, fallback = o.fallback or "search" } }
  classify.cursor = function()
    calls.classify = calls.classify + 1
    return o.class or "unknown"
  end
  symbols.candidates = function(_, opts)
    local t = opts and opts.text
    return { (t and t ~= "") and t or "count" }
  end
  detect.buffer = function()
    return { ft = "lua", bases = { "lua" }, missing = {}, slugs = { "lua~5.4" }, root = "/p" }
  end
  detect.lookup_order = function()
    return { "lua~5.4" }, { ["lua~5.4"] = 1 }
  end
  index.sources = function()
    calls.docs = calls.docs + 1
    return o.sources == 0 and {} or { {} }
  end
  rank.lookup = function()
    return o.hits or {}
  end
  rank.decisive = function()
    return true
  end
  viewer.open = function()
    calls.open = calls.open + 1
  end
  picker.pick_hits = function() end
  vim.lsp.get_clients = function(filter)
    if not o.hover then
      return {}
    end
    if filter and filter.method and filter.method ~= "textDocument/hover" then
      return {}
    end
    return { { id = 1, name = "stub" } }
  end
  vim.lsp.buf.hover = function()
    calls.hover = calls.hover + 1
  end
  vim.notify = function(msg)
    table.insert(calls.notify, msg)
  end
  require("devdocs").search = function(q)
    table.insert(calls.search, q)
  end

  local ok, err = pcall(fn, calls)

  classify.cursor = saved.cursor
  symbols.candidates = saved.candidates
  detect.buffer = saved.buffer
  detect.lookup_order = saved.order
  index.sources = saved.sources
  rank.lookup = saved.rlookup
  rank.decisive = saved.decisive
  viewer.open = saved.vopen
  picker.pick_hits = saved.pick
  vim.lsp.get_clients = saved.clients
  vim.lsp.buf.hover = saved.hover
  vim.notify = saved.notify
  require("devdocs").search = saved.search
  config.resolve()
  if not ok then
    error(err, 0)
  end
  return calls
end

describe("lookup.run smart fallback", function()
  it("hovers a project variable instead of searching the docs", function()
    local c = scenario({ class = "variable", hover = true, hits = { HIT } }, function()
      lookup.run "section"
    end)
    eq(1, c.hover)
    eq(0, c.docs)
    eq(0, c.open)
  end)

  it("does the same for examples", function()
    local c = scenario({ class = "variable", hover = true, hits = { HIT } }, function()
      lookup.run "examples"
    end)
    eq(1, c.hover)
    eq(0, c.open)
  end)

  it("keeps the doc lookup for a variable when no client can hover", function()
    local c = scenario({ class = "variable", hover = false, hits = { HIT } }, function()
      lookup.run "section"
    end)
    eq(0, c.hover)
    eq(1, c.open)
  end)

  it("keeps the configured fallback for a variable with no docs and no LSP", function()
    local c = scenario({ class = "variable", hover = false, hits = {} }, function()
      lookup.run "section"
    end)
    eq(0, c.hover)
    eq({ "@lua~5.4 count" }, c.search)
  end)

  for _, class in ipairs { "keyword", "builtin", "library" } do
    it("looks a " .. class .. " up in the docs even when hover is available", function()
      local c = scenario({ class = class, hover = true, hits = { HIT } }, function()
        lookup.run "section"
      end)
      eq(0, c.hover)
      eq(1, c.open)
    end)
  end

  it("opens the docs for a project symbol that has an entry", function()
    local c = scenario({ class = "symbol", hover = true, hits = { HIT } }, function()
      lookup.run "section"
    end)
    eq(0, c.hover)
    eq(1, c.open)
  end)

  it("hovers a project symbol the docs do not know, before the configured fallback", function()
    local c = scenario({ class = "symbol", hover = true, hits = {} }, function()
      lookup.run "section"
    end)
    eq(1, c.hover)
    eq({}, c.search)
  end)

  it("hovers a project symbol when no docs are installed", function()
    local c = scenario({ class = "symbol", hover = true, sources = 0 }, function()
      lookup.run "section"
    end)
    eq(1, c.hover)
    eq({}, c.notify)
  end)

  it("uses the configured fallback for a project symbol when no client can hover", function()
    local c = scenario({ class = "symbol", hover = false, hits = {} }, function()
      lookup.run "section"
    end)
    eq(0, c.hover)
    eq({ "@lua~5.4 count" }, c.search)
  end)

  it("leaves an unknown token to the configured fallback", function()
    local c = scenario({ class = "unknown", hover = true, hits = {} }, function()
      lookup.run "section"
    end)
    eq(0, c.hover)
    eq({ "@lua~5.4 count" }, c.search)
  end)

  it("does not classify explicit text (a selection or an argument)", function()
    local c = scenario({ class = "variable", hover = true, hits = { HIT } }, function()
      lookup.run("section", { text = "count" })
    end)
    eq(0, c.classify)
    eq(0, c.hover)
    eq(1, c.open)
  end)

  it("still classifies the cursor word when the text is empty", function()
    local c = scenario({ class = "variable", hover = true, hits = { HIT } }, function()
      lookup.run("section", { text = "" })
    end)
    eq(1, c.classify)
    eq(1, c.hover)
  end)

  it("does nothing new with lookup.smart = false", function()
    local c = scenario({ smart = false, class = "variable", hover = true, hits = { HIT } }, function()
      lookup.run "section"
    end)
    eq(0, c.classify)
    eq(0, c.hover)
    eq(1, c.open)
  end)
end)

describe("lookup.can_hover", function()
  it("asks for clients that implement textDocument/hover", function()
    local seen
    local orig = vim.lsp.get_clients
    vim.lsp.get_clients = function(filter)
      seen = filter
      return {}
    end
    local got = lookup.can_hover(7)
    vim.lsp.get_clients = orig
    eq(false, got)
    eq({ bufnr = 7, method = "textDocument/hover" }, seen)
  end)
end)

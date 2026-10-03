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
--- Hover responses per client id, as vim.lsp.buf_request_all hands them over.
local HOVER = { [1] = { result = { contents = { kind = "markdown", value = "count: integer" } } } }

--- Run fn with lookup's collaborators stubbed; returns what was called.
--- `hover_results` is what the hover request answers (default HOVER); `calls.hover`
--- counts hover requests and `calls.float` the hover windows shown.
--- `cands` is what symbols.candidates returns for the cursor (default { "count" }).
--- @param o { class?: string, cands?: string[], hover?: boolean, hover_results?: table, hits?: table[], sources?: integer, smart?: boolean, fallback?: string, decisive?: boolean }
local function scenario(o, fn)
  local calls = { classify = 0, hover = 0, float = {}, docs = 0, open = 0, pick = 0, search = {}, notify = {} }
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
    request_all = vim.lsp.buf_request_all,
    float = vim.lsp.util.open_floating_preview,
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
    if t and t ~= "" then
      return { t }
    end
    return o.cands or { "count" }
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
    return o.decisive ~= false
  end
  viewer.open = function()
    calls.open = calls.open + 1
  end
  picker.pick_hits = function()
    calls.pick = calls.pick + 1
  end
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
  vim.lsp.buf_request_all = function(_, method, params, handler)
    calls.hover = calls.hover + 1
    calls.method = method
    calls.params = type(params) == "function" and params({ id = 1, offset_encoding = "utf-16" }, 0) or params
    handler(o.hover_results or HOVER)
  end
  vim.lsp.util.open_floating_preview = function(lines, syntax)
    table.insert(calls.float, { lines = lines, syntax = syntax })
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
  vim.lsp.buf_request_all = saved.request_all
  vim.lsp.util.open_floating_preview = saved.float
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
    eq("textDocument/hover", c.method)
    eq({ { lines = { "count: integer" }, syntax = "markdown" } }, c.float)
  end)

  it("sends the cursor position with the hover request", function()
    local c = scenario({ class = "variable", hover = true }, function()
      lookup.run "section"
    end)
    eq(true, c.params.position ~= nil and c.params.textDocument ~= nil)
  end)

  it("falls back to the docs when the hover comes back empty", function()
    for _, results in ipairs {
      {},
      { [1] = { result = nil } },
      { [1] = { result = { contents = "" } } },
      { [1] = { result = { contents = { kind = "markdown", value = "  \n" } } } },
      { [1] = { result = { contents = {} } } },
      { [1] = { err = { code = -32601, message = "nope" } }, [2] = { result = nil } },
    } do
      local c = scenario({ class = "variable", hover = true, hover_results = results, hits = { HIT } }, function()
        lookup.run "section"
      end)
      eq(1, c.hover, vim.inspect(results))
      eq({}, c.float, vim.inspect(results))
      eq(1, c.open, vim.inspect(results))
    end
  end)

  it("uses the configured fallback when the hover is empty and the docs have nothing", function()
    local c = scenario({ class = "variable", hover = true, hover_results = {}, hits = {} }, function()
      lookup.run "section"
    end)
    eq({}, c.float)
    eq({ "@lua~5.4 count" }, c.search)
  end)

  it("shows the non-empty answers when some clients have nothing", function()
    local results = {
      [1] = { result = { contents = "" } },
      [2] = { err = { code = 1, message = "x" } },
      [3] = { result = { contents = { kind = "plaintext", value = "from three" } } },
    }
    local c = scenario({ class = "variable", hover = true, hover_results = results, hits = { HIT } }, function()
      lookup.run "section"
    end)
    eq(1, #c.float)
    eq(0, c.open)
  end)

  it("does not classify when no client can hover", function()
    local c = scenario({ class = "variable", hover = false, hits = { HIT } }, function()
      lookup.run "section"
    end)
    eq(0, c.classify)
    eq(1, c.open)
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
    eq(1, #c.float)
    eq({}, c.search)
  end)

  it("uses the configured fallback for a project symbol whose hover is empty", function()
    local c = scenario({ class = "symbol", hover = true, hover_results = {}, hits = {} }, function()
      lookup.run "section"
    end)
    eq(1, c.hover)
    eq({}, c.float)
    eq({ "@lua~5.4 count" }, c.search)
  end)

  it("explains the missing docs for a project symbol whose hover is empty", function()
    local c = scenario({ class = "symbol", hover = true, hover_results = {}, sources = 0 }, function()
      lookup.run "section"
    end)
    eq({}, c.float)
    eq(1, #c.notify)
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

  it("uses the configured fallback for an unknown token when no client can hover", function()
    local c = scenario({ class = "unknown", hover = false, hits = {} }, function()
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

-- What lua_ls and the lua treesitter query said in the repro, line
-- `vim.api.nvim_create_user_command("DevDocs", function(args)` with the cursor on
-- nvim_create_user_command: semantic token { type = "method", modifiers = {} }
-- ("symbol"), or before tokens arrive / with semanticTokensProvider disabled
-- (NvChad) the captures variable, variable.member, function.call ("unknown").
-- lua~5.1 has no entry for any candidate.
local NVIM_API = { "vim.api.nvim_create_user_command", "api.nvim_create_user_command", "nvim_create_user_command" }
local function hit(name)
  return { slug = "lua~5.1", entry = { name = name, path = "index#" .. name }, score = 50 }
end

describe("lookup.run without a decisive doc entry", function()
  for _, class in ipairs { "unknown", "symbol", "library" } do
    it("hovers a Neovim API function the docs do not cover (" .. class .. ")", function()
      local c = scenario({ class = class, cands = NVIM_API, hover = true, hits = {} }, function()
        lookup.run "section"
      end)
      eq(1, c.hover)
      eq(1, #c.float)
      eq({}, c.search)
      eq({}, c.notify)
    end)

    it("hovers instead of the picker when only weak matches come back (" .. class .. ")", function()
      local hits = { hit "table.insert()", hit "Insert" }
      local c = scenario({
        class = class,
        cands = { "vim.fn.insert", "fn.insert", "insert" },
        hover = true,
        hits = hits,
        decisive = false,
      }, function()
        lookup.run "section"
      end)
      eq(1, c.hover)
      eq(0, c.pick)
      eq(0, c.open)
    end)

    it("hovers when no docs are installed (" .. class .. ")", function()
      local c = scenario({ class = class, cands = NVIM_API, hover = true, sources = 0 }, function()
        lookup.run "section"
      end)
      eq(1, c.hover)
      eq({}, c.notify)
    end)
  end

  it("does not open lua's print() for vim.print (defaultLibrary covers vim.* too)", function()
    local c = scenario(
      { class = "library", cands = { "vim.print", "print" }, hover = true, hits = { hit "print()" } },
      function()
        lookup.run "section"
      end
    )
    eq(1, c.hover)
    eq(0, c.open)
  end)

  it("opens the doc page for a library name the docs have an exact entry for", function()
    for _, case in ipairs {
      { cands = { "print" }, name = "print()" },
      { cands = { "string.format", "format" }, name = "string.format()" },
    } do
      local c = scenario({ class = "library", cands = case.cands, hover = true, hits = { hit(case.name) } }, function()
        lookup.run "section"
      end)
      eq(0, c.hover, case.name)
      eq(1, c.open, case.name)
    end
  end)

  it("goes on to the docs when the hover is empty", function()
    local hits = { hit "table.insert()", hit "Insert" }
    local c = scenario({
      class = "unknown",
      cands = { "vim.fn.insert", "fn.insert", "insert" },
      hover = true,
      hover_results = {},
      hits = hits,
      decisive = false,
    }, function()
      lookup.run "section"
    end)
    eq(1, c.hover)
    eq({}, c.float)
    eq(1, c.pick)
  end)

  it("keeps the configured fallback for keywords and builtins the docs lack", function()
    for _, class in ipairs { "keyword", "builtin" } do
      local c = scenario({ class = class, hover = true, hits = {} }, function()
        lookup.run "section"
      end)
      eq(0, c.hover, class)
      eq({ "@lua~5.4 count" }, c.search, class)
    end
  end)

  it("hovers a variable only once when its hover is empty and the docs lack it", function()
    local c = scenario({ class = "variable", hover = true, hover_results = {}, hits = {} }, function()
      lookup.run "section"
    end)
    eq(1, c.hover)
    eq({ "@lua~5.4 count" }, c.search)
  end)

  it("never hovers for explicit text or with lookup.smart = false", function()
    local c = scenario({ class = "unknown", hover = true, hits = {} }, function()
      lookup.run("section", { text = "nvim_create_user_command" })
    end)
    eq(0, c.hover)
    eq({ "@lua~5.4 nvim_create_user_command" }, c.search)
    c = scenario({ smart = false, class = "unknown", cands = NVIM_API, hover = true, hits = {} }, function()
      lookup.run "section"
    end)
    eq(0, c.hover)
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

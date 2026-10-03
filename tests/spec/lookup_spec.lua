local classify = require "devdocs.classify"
local config = require "devdocs.config"
local detect = require "devdocs.detect"
local explain = require "devdocs.explain"
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
--- `target` (or class / kind / word / decl_line) is what classify.target returns;
--- `explain` turns lookup.explain on (default off, so the older tests keep their
--- expectations); `calls.explain` lists the targets the "nothing to document" popup got.
--- @param o { class?: string, kind?: string, word?: string, decl_line?: integer, target?: table, explain?: boolean, cands?: string[], hover?: boolean, hover_results?: table, hits?: table[], sources?: integer, smart?: boolean, fallback?: string, decisive?: boolean }
local function scenario(o, fn)
  local calls =
    { classify = 0, hover = 0, float = {}, docs = 0, open = 0, pick = 0, search = {}, notify = {}, explain = {} }
  local saved = {
    target = classify.target,
    explain_show = explain.show,
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
  config.resolve {
    lookup = { smart = o.smart ~= false, fallback = o.fallback or "search", explain = o.explain == true },
  }
  classify.target = function()
    calls.classify = calls.classify + 1
    return o.target
      or { class = o.class or "unknown", kind = o.kind, word = o.word or "count", decl_line = o.decl_line }
  end
  explain.show = function(t)
    table.insert(calls.explain, t)
    return 1000
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

  classify.target = saved.target
  explain.show = saved.explain_show
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

--- lookup.run with lookup.explain = true: `calls.explain` holds the popups shown.
describe("lookup.run explain", function()
  local function run(o, mode)
    o.explain = o.explain ~= false
    return scenario(o, function()
      lookup.run(mode or "section")
    end)
  end

  it("shows a popup for trivial targets and does nothing else", function()
    for _, kind in ipairs { "string", "comment", "number", "whitespace", "operator", "punctuation" } do
      for _, hover in ipairs { true, false } do
        local label = kind .. " hover=" .. tostring(hover)
        local c = run { class = "trivial", kind = kind, hover = hover, hits = { HIT } }
        eq(1, #c.explain, label)
        eq(kind, c.explain[1].kind, label)
        eq(0, c.hover, label)
        eq(0, c.docs, label)
        eq(0, c.open, label)
        eq({}, c.search, label)
        eq({}, c.notify, label)
      end
    end
  end)

  it("shows the popup on a blank line without the nothing-to-look-up warning", function()
    local c = run { class = "trivial", kind = "whitespace", word = "", cands = {} }
    eq(1, #c.explain)
    eq({}, c.notify)
  end)

  it("classifies for a variable even with no hover client, and shows the popup", function()
    local c = run { class = "variable", kind = "local", decl_line = 2, hover = false, hits = { HIT } }
    eq(1, c.classify)
    eq(1, #c.explain)
    eq(0, c.open)
    eq(0, c.hover)
  end)

  it("hovers a variable that has hover content", function()
    local c = run { class = "variable", kind = "local", decl_line = 2, hover = true, hits = { HIT } }
    eq(1, #c.float)
    eq(0, #c.explain)
    eq(0, c.open)
  end)

  it("shows the popup for a variable whose hover is empty, never the docs", function()
    local c = run { class = "variable", hover = true, hover_results = {}, hits = { HIT } }
    eq(1, c.hover)
    eq({}, c.float)
    eq(1, #c.explain)
    eq(0, c.open)
    eq({}, c.search)
  end)

  it("opens the doc page for a literal the docs have an exact entry for", function()
    local c =
      run { class = "builtin", kind = "nil", word = "null", cands = { "null" }, hits = { hit "null" }, hover = true }
    eq(1, c.open)
    eq(0, #c.explain)
    eq(0, c.hover)
  end)

  it("shows the popup for true / false the docs have no exact entry for", function()
    local c = run { class = "builtin", kind = "boolean", word = "true", cands = { "true" }, hits = {} }
    eq(1, #c.explain)
    eq({}, c.search)
    c = run {
      class = "builtin",
      kind = "boolean",
      word = "true",
      cands = { "true" },
      hits = { hit "Boolean" },
      decisive = false,
    }
    eq(1, #c.explain)
    eq(0, c.pick)
    eq(0, c.open)
    eq(0, c.hover)
  end)

  it("shows the popup for a literal when no docs are installed", function()
    local c = run { class = "builtin", kind = "nil", word = "nil", sources = 0 }
    eq(1, #c.explain)
    eq({}, c.notify)
  end)

  it("hovers a buffer-declared function the docs lack", function()
    local c = run { class = "unknown", kind = "function", decl_line = 3, cands = { "helper" }, hover = true, hits = {} }
    eq(1, #c.float)
    eq(0, #c.explain)
  end)

  it("shows the popup for a buffer-declared function with an empty hover", function()
    local c = run {
      class = "unknown",
      kind = "function",
      decl_line = 3,
      cands = { "helper" },
      hover = true,
      hover_results = {},
      hits = {},
    }
    eq(1, #c.explain)
    eq({}, c.search)
    eq(0, c.pick)
  end)

  it("shows the popup for a buffer-declared function when no client can hover", function()
    local c =
      run { class = "unknown", kind = "function", decl_line = 3, cands = { "helper" }, hover = false, hits = {} }
    eq(1, #c.explain)
    eq({}, c.search)
  end)

  it("opens the doc page for a buffer-declared symbol with an exact entry", function()
    local c = run { class = "symbol", kind = "function", decl_line = 1, hits = { HIT } }
    eq(1, c.open)
    eq(0, #c.explain)
  end)

  it("shows the popup instead of the no-docs notice for a declared symbol", function()
    local c = run { class = "symbol", kind = "function", decl_line = 1, hover = true, hover_results = {}, sources = 0 }
    eq(1, #c.explain)
    eq({}, c.notify)
  end)

  describe("never shows the popup for", function()
    it("a keyword", function()
      local c = run { class = "keyword", cands = { "return" }, hits = { hit "return" }, hover = true }
      eq(1, c.open)
      eq(0, #c.explain)
      eq(0, c.hover)
      c = run { class = "keyword", hover = true, hits = {} }
      eq({ "@lua~5.4 count" }, c.search)
      eq(0, #c.explain)
    end)

    it("a builtin or library name with an exact entry", function()
      local c = run { class = "builtin", cands = { "print" }, hits = { hit "print()" }, hover = true }
      eq(1, c.open)
      eq(0, #c.explain)
      c = run {
        class = "library",
        cands = { "string.format", "format" },
        hits = { hit "string.format()" },
        hover = true,
      }
      eq(1, c.open)
      eq(0, #c.explain)
    end)

    for _, class in ipairs { "unknown", "symbol", "library" } do
      it("an undeclared " .. class .. " that hover answers (" .. class .. ")", function()
        local c = run { class = class, cands = NVIM_API, hover = true, hits = {} }
        eq(1, #c.float)
        eq(0, #c.explain)
      end)
    end

    it("an undeclared unknown with an empty hover or no client", function()
      local c = run { class = "unknown", cands = NVIM_API, hover = true, hover_results = {}, hits = {} }
      eq({ "@lua~5.4 nvim_create_user_command" }, c.search)
      eq(0, #c.explain)
      c = run { class = "unknown", hover = false, hits = {} }
      eq(1, c.classify)
      eq({ "@lua~5.4 count" }, c.search)
      eq(0, #c.explain)
    end)

    it("explicit text", function()
      local c = scenario({ class = "trivial", kind = "string", explain = true, hits = { HIT } }, function()
        lookup.run("section", { text = "count" })
      end)
      eq(0, c.classify)
      eq(0, #c.explain)
      eq(1, c.open)
    end)

    it("lookup.smart = false", function()
      local c = run { smart = false, class = "trivial", kind = "string", hits = { HIT } }
      eq(0, c.classify)
      eq(0, #c.explain)
    end)
  end)

  describe("with lookup.explain = false", function()
    it("treats a trivial target as unknown", function()
      local c = run { explain = false, class = "trivial", kind = "string", hover = true, hits = {} }
      eq(1, c.hover)
      eq(1, #c.float)
      eq(0, #c.explain)
      c = run { explain = false, class = "trivial", kind = "string", hover = false, hits = {} }
      eq(0, c.classify)
      eq(0, #c.explain)
    end)

    it("keeps the docs for a variable whose hover is empty", function()
      local c = run { explain = false, class = "variable", hover = true, hover_results = {}, hits = { HIT } }
      eq(1, c.open)
      eq(0, #c.explain)
    end)
  end)
end)

describe("lookup.explain config", function()
  it("defaults to true", function()
    eq(true, config.defaults.lookup.explain)
  end)

  it("must be a boolean and is a known key", function()
    eq(false, (pcall(config.resolve, { lookup = { explain = "yes" } })))
    local ok_, err = pcall(config.resolve, { lookup = { explain = false } })
    config.resolve()
    ok(ok_, tostring(err))
  end)
end)

describe("lookup.open without an entry (the index)", function()
  local paths = require "devdocs.paths"
  local store = require "devdocs.store"

  local root = tmpdir()
  config.resolve { data_dir = root }
  store.invalidate()
  for _, v in ipairs { "5.1", "5.4" } do
    local slug = "lua~" .. v
    store.write_json(paths.meta_file(slug), { slug = slug, name = "Lua", doc_version = v }, "meta")
    store.write_file(
      paths.entries_file(slug),
      store.encode_entries { { name = "assert()", path = "index#pdf-assert", type = "Standard Libraries" } }
    )
  end
  store.invalidate()

  --- Run fn with the viewer, detect and ui.select stubbed; returns what was called.
  --- @param o { buffer_slugs?: string[], viewer_slug?: string, newest?: string[], choose?: string, installed?: string[] }
  local function scenario(o, fn)
    local calls = { index = {}, open = {}, notify = {}, select = nil }
    local saved = {
      open_index = viewer.open_index,
      open = viewer.open,
      current = viewer.current_view,
      buffer = detect.buffer,
      newest = detect.newest_slugs,
      select = vim.ui.select,
      notify = vim.notify,
      lookup = rank.lookup,
      decisive = rank.decisive,
      sources = index.sources,
      installed = store.installed,
    }
    viewer.open_index = function(slug, opts)
      table.insert(calls.index, { slug = slug, opts = opts })
    end
    viewer.open = function(view)
      table.insert(calls.open, view)
    end
    viewer.current_view = function()
      return o.viewer_slug and { slug = o.viewer_slug, mode = "section" } or nil
    end
    detect.buffer = function()
      return { ft = "lua", bases = { "lua" }, missing = {}, slugs = o.buffer_slugs or {}, root = "/p" }
    end
    detect.newest_slugs = function()
      return o.newest or { "lua~5.4" }
    end
    vim.ui.select = function(items, select_opts, on_choice)
      calls.select = { items = items, opts = select_opts }
      on_choice(o.choose)
    end
    vim.notify = function(msg, level)
      table.insert(calls.notify, { msg = msg, level = level })
    end
    rank.lookup = function()
      return { { slug = "lua~5.4", entry = { name = "assert()", path = "index#pdf-assert" } } }
    end
    rank.decisive = function()
      return true
    end
    index.sources = function()
      return {}
    end
    if o.installed then
      store.installed = function()
        return o.installed
      end
    end
    local ok_run, err = pcall(fn, calls)
    viewer.open_index = saved.open_index
    viewer.open = saved.open
    viewer.current_view = saved.current
    detect.buffer = saved.buffer
    detect.newest_slugs = saved.newest
    vim.ui.select = saved.select
    vim.notify = saved.notify
    rank.lookup = saved.lookup
    rank.decisive = saved.decisive
    index.sources = saved.sources
    store.installed = saved.installed
    if not ok_run then
      error(err, 0)
    end
    return calls
  end

  it("resolves a doc name to the newest installed slug, or an exact slug, or nothing", function()
    eq("lua~5.4", (lookup.resolve_doc "lua"))
    eq("lua~5.1", (lookup.resolve_doc "lua~5.1"))
    eq(nil, (lookup.resolve_doc "nonesuch"))
  end)

  it("opens the index of the doc named, the newest version for a bare name", function()
    local calls = scenario({}, function()
      lookup.open("lua", nil)
      lookup.open("lua~5.1", nil)
      lookup.open("lua", "")
    end)
    eq(3, #calls.index)
    eq("lua~5.4", calls.index[1].slug)
    eq("lua~5.1", calls.index[2].slug)
    eq("lua~5.4", calls.index[3].slug)
    eq(0, #calls.open, "no entry page should open")
  end)

  it("opens the index of the buffer's doc when no doc is given", function()
    local calls = scenario({ buffer_slugs = { "lua~5.1", "lua~5.4" } }, function()
      lookup.open(nil, nil)
      lookup.open("", nil)
    end)
    eq(
      { "lua~5.1", "lua~5.1" },
      vim.tbl_map(function(c)
        return c.slug
      end, calls.index)
    )
    eq(nil, calls.select)
  end)

  it("falls back to the doc in the open viewer", function()
    local calls = scenario({ viewer_slug = "lua~5.1" }, function()
      lookup.open(nil, nil)
    end)
    eq("lua~5.1", calls.index[1].slug)
    eq(nil, calls.select)
  end)

  it("asks which doc when there is no buffer doc and no viewer", function()
    local calls = scenario({ newest = { "lua~5.4", "python~3.12" }, choose = "python~3.12" }, function()
      lookup.open(nil, nil)
    end)
    eq({ "lua~5.4", "python~3.12" }, calls.select.items)
    eq("DevDocs index of:", calls.select.opts.prompt)
    eq("python~3.12", calls.index[1].slug)
  end)

  it("opens nothing when the choice is cancelled", function()
    local calls = scenario({ newest = { "lua~5.4", "python~3.12" } }, function()
      lookup.open(nil, nil)
    end)
    eq(0, #calls.index)
    eq(0, #calls.notify)
  end)

  it("warns when no docs are installed", function()
    local calls = scenario({ newest = {}, installed = {} }, function()
      lookup.open(nil, nil)
    end)
    eq(0, #calls.index)
    eq(nil, calls.select)
    ok(calls.notify[1] and calls.notify[1].msg:find("no docs installed", 1, true), vim.inspect(calls.notify))
    ok(calls.notify[1].msg:find(":DevDocs install", 1, true), calls.notify[1].msg)
    eq(vim.log.levels.WARN, calls.notify[1].level)
  end)

  it("warns about a doc that is not installed and opens no index", function()
    local calls = scenario({}, function()
      lookup.open("nonesuch", nil)
    end)
    eq(0, #calls.index)
    ok(calls.notify[1] and calls.notify[1].msg:find("nonesuch", 1, true), vim.inspect(calls.notify))
  end)

  it("still opens the entry's page when an entry is given", function()
    local calls = scenario({}, function()
      lookup.open("lua", "assert")
    end)
    eq(0, #calls.index)
    eq(1, #calls.open)
    eq("assert()", calls.open[1].entry.name)
    eq("section", calls.open[1].mode)
  end)

  it("joins the words after the doc into one entry query: :DevDocs open lua table insert", function()
    local commands = require "devdocs.commands"
    local devdocs = require "devdocs"
    local saved = devdocs.open
    local got = {}
    devdocs.open = function(doc, entry)
      got[#got + 1] = { doc, entry }
    end
    local msgs = {}
    local saved_notify = vim.notify
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    local ok_run, err = pcall(function()
      commands.subcommands.open {}
      commands.subcommands.open { "lua" }
      commands.subcommands.open { "lua", "table", "insert" }
    end)
    devdocs.open = saved
    vim.notify = saved_notify
    assert(ok_run, err)
    eq({ { nil, nil }, { "lua", nil }, { "lua", "table insert" } }, got)
    eq(0, #msgs, "no usage error any more: " .. vim.inspect(msgs))
  end)
end)

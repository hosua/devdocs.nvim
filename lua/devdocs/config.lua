--- Config: defaults, validation, and the resolved table the rest of the
--- plugin reads. The defaults table below IS the README's config section;
--- keep the two identical (tests/spec/readme_spec.lua asserts it).
local M = {}

--- @class DevDocsConfig
M.defaults = {
  -- Where docs, the manifest cache and state live. One directory; delete it to reset.
  data_dir = vim.fn.stdpath "data" .. "/devdocs",

  -- true: when a buffer's language has a devdocs entry that is not installed yet,
  -- download the version matching the project (or the newest) in the background.
  -- "prompt": ask first. false: only :DevDocs install / the list manager install.
  install_as_needed = true,

  import = {
    -- Docs to keep installed, by slug or display name; `*` globs, case-insensitive
    -- ("python*" matches every Python version, "Bootstrap" matches bootstrap~5).
    -- Empty: derived from the LSP servers Mason has installed (when mason is present).
    docs = {},
    -- Only the newest version of each listed doc.
    recent_only = false,
    -- The docs list is the whole allowlist: no FileType auto-install, no Mason defaults.
    import_only = false,
    -- Every version of each listed doc; lookups pick the version the buffer's project uses.
    all = false,
  },

  install = {
    -- Parallel downloads/conversions for install-all. Raise it (e.g. 6) when
    -- installing from a local devdocs mirror; the public CDN rate-limits.
    max_jobs = 2,
    -- "tarball": one .tar.gz per doc from tarball_url (what `thor docs:download` uses; default).
    -- "json": db.json + index.json from doc_url, for a self-hosted devdocs app
    -- ("http://localhost:9292/docs/{slug}/{file}", manifest "http://localhost:9292/docs.json")
    -- or a directory of downloaded docs ("file:///path/to/devdocs/public/docs/{slug}/{file}").
    source = "tarball",
    tarball_url = "https://downloads.devdocs.io/{slug}.tar.gz",
    doc_url = "https://documents.devdocs.io/{slug}/{file}",
    manifest_url = "https://devdocs.io/docs.json",
    tar = "tar",
    -- Seconds before the cached manifest (list of all docs) is refreshed.
    manifest_ttl = 86400,
    curl = "curl",
  },

  -- :DevDocs mirror (:DevDocsForceCloneAndScrape): clone freeCodeCamp/devdocs, pull every
  -- doc through its container into <dir>/public/docs, then install-all from that directory.
  mirror = {
    -- nil = <data_dir>/mirror/devdocs
    dir = nil,
    repo = "https://github.com/freeCodeCamp/devdocs",
    image = "ghcr.io/freecodecamp/devdocs:latest",
    docker = "docker",
    git = "git",
  },

  search = {
    rg = "rg",
    max_results = 200,
    -- Results from the current buffer's docs come first.
    prioritize_buffer_docs = true,
  },

  view = {
    -- "float" | "split" | "vsplit" | "tab"
    mode = "float",
    width = 0.8,
    height = 0.8,
    -- nil follows 'winborder'; otherwise any nvim_open_win border value.
    border = nil,
    wrap = true,
    -- conceallevel=2 in the viewer so markdown links read as plain text.
    conceal = true,
  },

  lookup = {
    -- When the symbol under the cursor has no doc entry:
    -- "search" opens the search picker with the word, "lsp_hover" calls vim.lsp.buf.hover(), "none" notifies.
    fallback = "search",
    -- "buffer": when the buffer's language is known, look only in its docs (the version
    -- its project uses); otherwise in the newest version of every doc.
    -- "all": the buffer's docs first, then every installed doc (slow with many docs installed).
    scope = "buffer",
    -- On :DevDocs definition / example, tell keywords and builtins from the project's own
    -- names (LSP semantic tokens, else treesitter): a local variable, parameter or field shows
    -- vim.lsp.buf.hover() instead of a doc page, and any other name the docs have no entry
    -- named exactly like (`vim.api.nvim_create_user_command`) shows hover before fuzzy matches
    -- or `fallback`. Only when an attached client can hover; an empty hover goes on to the
    -- docs, and a visual selection or an explicit argument always looks up the docs.
    smart = true,
  },

  -- filetype -> { slug bases }, merged over the built-in table (lua/devdocs/langmap.lua).
  extra_filetypes = {},
  -- Mason package name -> { slug bases }, merged over the built-in table.
  extra_mason = {},

  hooks = {
    -- function(slug) after a doc finished installing
    on_install = nil,
    -- function(slug, path) when a page opens in the viewer
    on_open = nil,
  },

  notify = true,
}

local resolved

--- Collect "a.b.c" paths present in `user` but absent from `defaults`, so a
--- typo in the user's opts is reported instead of silently ignored. Tables
--- whose default is a list or a free-form map are not descended into.
local FREE_FORM = { extra_filetypes = true, extra_mason = true, hooks = true }
-- Keys whose default is nil (so they cannot be discovered from `defaults`).
local NIL_DEFAULTS = { ["view.border"] = true, ["mirror.dir"] = true }

local function unknown_keys(user, defaults, prefix, out)
  for k, v in pairs(user) do
    local path = prefix .. tostring(k)
    if defaults[k] == nil and not FREE_FORM[k] and not NIL_DEFAULTS[path] then
      out[#out + 1] = path
    elseif type(v) == "table" and type(defaults[k]) == "table" and not vim.islist(defaults[k]) and not FREE_FORM[k] then
      unknown_keys(v, defaults[k], path .. ".", out)
    end
  end
  return out
end

local function validate(cfg)
  vim.validate("data_dir", cfg.data_dir, "string")
  vim.validate("install_as_needed", cfg.install_as_needed, function(v)
    return v == true or v == false or v == "prompt"
  end, "true, false or 'prompt'")
  vim.validate("import.docs", cfg.import.docs, vim.islist, "a list of doc names")
  vim.validate("install.max_jobs", cfg.install.max_jobs, "number")
  vim.validate("install.source", cfg.install.source, function(v)
    return v == "tarball" or v == "json"
  end, "'tarball' or 'json'")
  vim.validate("search.max_results", cfg.search.max_results, "number")
  vim.validate("view.mode", cfg.view.mode, function(v)
    return v == "float" or v == "split" or v == "vsplit" or v == "tab"
  end, "'float', 'split', 'vsplit' or 'tab'")
  vim.validate("lookup.fallback", cfg.lookup.fallback, function(v)
    return v == "search" or v == "lsp_hover" or v == "none"
  end, "'search', 'lsp_hover' or 'none'")
  vim.validate("lookup.scope", cfg.lookup.scope, function(v)
    return v == "buffer" or v == "all"
  end, "'buffer' or 'all'")
  vim.validate("lookup.smart", cfg.lookup.smart, "boolean")
end

--- @param opts table|nil
--- @return DevDocsConfig cfg, string[] unknown
function M.resolve(opts)
  opts = opts or {}
  local unknown = unknown_keys(opts, M.defaults, "", {})
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- tbl_deep_extend drops nil-valued defaults; hooks/border are legitimately nil.
  cfg.hooks = vim.tbl_extend("force", {}, opts.hooks or {})
  cfg.data_dir = vim.fs.normalize(cfg.data_dir)
  validate(cfg)
  resolved = cfg
  if #unknown > 0 then
    vim.notify("devdocs: unknown config key(s): " .. table.concat(unknown, ", "), vim.log.levels.WARN)
  end
  return resolved, unknown
end

--- @return DevDocsConfig
function M.get()
  return resolved or M.resolve()
end

return M

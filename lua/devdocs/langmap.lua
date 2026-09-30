--- Langmap: which docs belong to which buffer. Pure tables plus the glob
--- expansion for `import.docs`. Every base named here exists in the
--- devdocs manifest (checked 2026-09-29); an unknown base is harmless, the
--- manifest lookup just finds nothing.
local manifest = require "devdocs.manifest"

local M = {}

--- filetype -> doc bases, most specific first.
--- @type table<string, string[]>
M.filetypes = {
  c = { "c" },
  cpp = { "cpp", "c" },
  cuda = { "cpp" },
  objc = { "c" },
  python = { "python" },
  javascript = { "javascript", "node", "dom" },
  javascriptreact = { "react", "javascript", "dom" },
  typescript = { "typescript", "javascript", "node", "dom" },
  typescriptreact = { "react", "typescript", "javascript", "dom" },
  vue = { "vue", "javascript", "dom", "css" },
  svelte = { "svelte", "javascript", "dom", "css" },
  astro = { "astro", "javascript", "dom" },
  css = { "css" },
  scss = { "sass", "css" },
  sass = { "sass", "css" },
  less = { "less", "css" },
  html = { "html", "dom", "css" },
  htmldjango = { "django", "html", "dom" },
  jinja = { "jinja", "html" },
  pug = { "pug", "html" },
  handlebars = { "handlebars", "html" },
  lua = { "lua" },
  go = { "go" },
  gomod = { "go" },
  rust = { "rust" },
  sh = { "bash" },
  bash = { "bash" },
  zsh = { "bash" },
  fish = { "fish" },
  terraform = { "terraform" },
  ["terraform-vars"] = { "terraform" },
  hcl = { "terraform" },
  dockerfile = { "docker" },
  java = { "openjdk" },
  kotlin = { "kotlin" },
  groovy = { "groovy" },
  php = { "php" },
  ruby = { "ruby" },
  eruby = { "rails", "ruby" },
  elixir = { "elixir", "erlang" },
  heex = { "elixir" },
  erlang = { "erlang" },
  haskell = { "haskell" },
  scala = { "scala" },
  dart = { "dart" },
  zig = { "zig" },
  nix = { "nix" },
  sql = { "postgresql", "sqlite" },
  pgsql = { "postgresql" },
  mysql = { "mariadb" },
  r = { "r" },
  rmd = { "r" },
  julia = { "julia" },
  cmake = { "cmake" },
  make = { "gnu_make" },
  markdown = { "markdown" },
  tex = { "latex" },
  plaintex = { "latex" },
  nginx = { "nginx" },
  gdscript = { "godot" },
  ocaml = { "ocaml" },
  perl = { "perl" },
  matlab = { "octave" },
  octave = { "octave" },
  jq = { "jq" },
  gitcommit = { "git" },
  gitconfig = { "git" },
  gitrebase = { "git" },
  clojure = { "clojure" },
  crystal = { "crystal" },
  nim = { "nim" },
  d = { "d" },
  bzl = { "bazel" },
}

--- Lua patterns on the file name (tail) -> extra bases, tried before the filetype.
--- @type { [1]: string, [2]: string[] }[]
M.filenames = {
  { "^docker%-compose.*%.ya?ml$", { "docker" } },
  { "^compose%.ya?ml$", { "docker" } },
  { "^Dockerfile", { "docker" } },
  { "^package%.json$", { "npm", "node" } },
  { "^%.nvmrc$", { "node" } },
  { "^go%.mod$", { "go" } },
  { "^Makefile$", { "gnu_make" } },
  { "^CMakeLists%.txt$", { "cmake" } },
  { "%.cmake$", { "cmake" } },
  { "^%.gitignore$", { "git" } },
  { "^tailwind%.config%.", { "tailwindcss" } },
  { "^vite%.config%.", { "vite" } },
  { "^webpack%.config%.", { "webpack" } },
  { "^jest%.config%.", { "jest" } },
  { "^vitest%.config%.", { "vitest" } },
  { "^playwright%.config%.", { "playwright" } },
  { "^cypress%.config%.", { "cypress" } },
  { "^%.eslintrc", { "eslint" } },
  { "^eslint%.config%.", { "eslint" } },
  { "^babel%.config%.", { "babel" } },
  { "^next%.config%.", { "nextjs" } },
  { "^nuxt%.config%.", { "vue" } },
  { "^requirements.*%.txt$", { "python" } },
  { "^pyproject%.toml$", { "python" } },
  { "^Gemfile$", { "ruby" } },
  { "^composer%.json$", { "composer", "php" } },
  { "^mix%.exs$", { "elixir" } },
  { "^build%.gradle", { "gradle", "openjdk" } },
  { "^pom%.xml$", { "openjdk" } },
  { "^project%.godot$", { "godot" } },
  { "^%.tf$", { "terraform" } },
  { "^nginx%.conf$", { "nginx" } },
  { "^helmfile", { "kubernetes" } },
  { "^Chart%.yaml$", { "kubernetes" } },
  { "^deployment.*%.ya?ml$", { "kubernetes" } },
  { "^ansible%.cfg$", { "ansible" } },
  { "^playbook.*%.ya?ml$", { "ansible" } },
}

--- Mason package name -> doc bases (what `import.docs = {}` derives its defaults from).
--- @type table<string, string[]>
M.mason = {
  ["angular-language-server"] = { "angular", "typescript" },
  ["ansible-language-server"] = { "ansible" },
  ["astro-language-server"] = { "astro" },
  basedpyright = { "python" },
  ["bash-language-server"] = { "bash" },
  clangd = { "c", "cpp" },
  ["cmake-language-server"] = { "cmake" },
  ["css-lsp"] = { "css" },
  ["css-variables-language-server"] = { "css" },
  ["django-language-server"] = { "django", "python" },
  ["docker-language-server"] = { "docker" },
  ["dockerfile-language-server"] = { "docker" },
  ["elixir-ls"] = { "elixir", "erlang" },
  ["erlang-ls"] = { "erlang" },
  ["eslint-lsp"] = { "eslint" },
  ["fish-lsp"] = { "fish" },
  ["golangci-lint-langserver"] = { "go" },
  gopls = { "go" },
  ["haskell-language-server"] = { "haskell" },
  ["helm-ls"] = { "kubernetes" },
  ["html-lsp"] = { "html", "dom" },
  intelephense = { "php" },
  jdtls = { "openjdk" },
  ["jq-lsp"] = { "jq" },
  ["julia-lsp"] = { "julia" },
  ["kotlin-language-server"] = { "kotlin" },
  ["kotlin-lsp"] = { "kotlin" },
  ["lua-language-server"] = { "lua" },
  ["nginx-language-server"] = { "nginx" },
  nil_ls = { "nix" },
  nixd = { "nix" },
  ["ocaml-lsp"] = { "ocaml" },
  perlnavigator = { "perl" },
  phpactor = { "php" },
  ["postgres-language-server"] = { "postgresql" },
  pyright = { "python" },
  ["python-lsp-server"] = { "python" },
  ["r-languageserver"] = { "r" },
  ruff = { "python" },
  ["ruby-lsp"] = { "ruby" },
  ["rust-analyzer"] = { "rust" },
  solargraph = { "ruby" },
  sqlls = { "postgresql", "sqlite" },
  superhtml = { "html" },
  ["svelte-language-server"] = { "svelte" },
  ["tailwindcss-language-server"] = { "tailwindcss" },
  ["terraform-ls"] = { "terraform" },
  ["terragrunt-ls"] = { "terraform" },
  texlab = { "latex" },
  ["typescript-language-server"] = { "typescript", "javascript", "node", "dom" },
  vtsls = { "typescript", "javascript", "node", "dom" },
  ["vue-language-server"] = { "vue" },
  zls = { "zig" },
}

local function push_unique(out, seen, bases)
  for _, b in ipairs(bases or {}) do
    if not seen[b] then
      seen[b] = true
      out[#out + 1] = b
    end
  end
end

--- Doc bases for a buffer, most specific first: user extra_filetypes, then
--- file-name rules, then the filetype table.
--- @param ft string
--- @param filename string|nil full path or tail
--- @param extra table<string, string[]>|nil config.extra_filetypes
--- @return string[]
function M.bases_for(ft, filename, extra)
  local out, seen = {}, {}
  if extra and extra[ft] then
    push_unique(out, seen, extra[ft])
  end
  local tail = filename and vim.fn.fnamemodify(filename, ":t") or ""
  if tail ~= "" then
    for _, rule in ipairs(M.filenames) do
      if tail:match(rule[1]) then
        push_unique(out, seen, rule[2])
      end
    end
  end
  push_unique(out, seen, M.filetypes[ft])
  return out
end

--- Doc bases implied by the Mason packages installed on this machine.
--- @param installed string[] mason package names
--- @param extra table<string, string[]>|nil config.extra_mason
--- @return string[]
function M.bases_for_mason(installed, extra)
  local out, seen = {}, {}
  for _, pkg in ipairs(installed) do
    push_unique(out, seen, (extra and extra[pkg]) or M.mason[pkg])
  end
  table.sort(out)
  return out
end

--- Names of the Mason packages installed here, or {} when mason is absent.
--- @return string[]
function M.mason_installed()
  local ok, registry = pcall(require, "mason-registry")
  if not ok or type(registry.get_installed_package_names) ~= "function" then
    return {}
  end
  local ok2, names = pcall(registry.get_installed_package_names)
  return ok2 and names or {}
end

--- Expand `import.docs` patterns into slugs. Per base: every version when
--- `all`, else the newest. A pattern that names one exact slug keeps it.
--- @param docs DevDocsDoc[]
--- @param patterns string[]
--- @param opts { all?: boolean }|nil
--- @return string[] slugs, string[] unmatched
function M.expand_import(docs, patterns, opts)
  opts = opts or {}
  local by_slug = manifest.by_slug(docs)
  local out, seen, unmatched = {}, {}, {}
  local function add(slug)
    if not seen[slug] then
      seen[slug] = true
      out[#out + 1] = slug
    end
  end
  for _, pattern in ipairs(patterns) do
    if by_slug[pattern] then
      add(pattern)
    else
      local matched = manifest.glob(docs, pattern)
      if #matched == 0 then
        unmatched[#unmatched + 1] = pattern
      elseif opts.all then
        for _, d in ipairs(matched) do
          add(d.slug)
        end
      else
        -- newest matched version of each base ("python~3*" never picks 2.7)
        local bases = {}
        for _, d in ipairs(manifest.sort_newest(matched)) do
          local b = manifest.base(d.slug)
          if not bases[b] then
            bases[b] = true
            add(d.slug)
          end
        end
      end
    end
  end
  return out, unmatched
end

return M

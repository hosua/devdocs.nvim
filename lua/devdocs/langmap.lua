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
  ksh = { "bash" },
  zsh = { "zsh", "bash" },
  readline = { "bash" },
  fish = { "fish" },
  terraform = { "terraform" },
  -- nvim names an empty *.tf "tf" (TinyFugue) until it has content to sniff
  tf = { "terraform" },
  opentofu = { "opentofu", "terraform" },
  tpp = { "cpp" },
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
  { "^%.npmrc$", { "npm" } },
  { "^%.yarnrc", { "yarn" } },
  { "^%.babelrc", { "babel" } },
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

--- File extension (lowercased) -> doc bases, for buffers whose filetype is
--- empty or not in M.filetypes. Every common spelling of each language.
--- @type table<string, string[]>
M.extensions = {}
for bases, exts in pairs {
  [{ "c" }] = "c",
  [{ "cpp", "c" }] = "h hh hpp hxx h++ cc cpp cxx c++ ipp tpp inl ixx cppm ccm cxxm mpp tcc",
  [{ "bash" }] = "sh bash ksh mksh dash bats",
  [{ "zsh", "bash" }] = "zsh",
  [{ "fish" }] = "fish",
  [{ "terraform" }] = "tf tfvars hcl tftest",
  [{ "opentofu", "terraform" }] = "tofu tofuvars",
  [{ "lua" }] = "lua luau rockspec",
  [{ "python" }] = "py pyi pyw pyx",
  [{ "javascript", "node", "dom" }] = "js mjs cjs",
  [{ "react", "javascript", "dom" }] = "jsx",
  [{ "typescript", "javascript", "node", "dom" }] = "ts mts cts",
  [{ "react", "typescript", "javascript", "dom" }] = "tsx",
  [{ "go" }] = "go",
  [{ "rust" }] = "rs",
  [{ "openjdk" }] = "java",
  [{ "kotlin" }] = "kt kts",
  [{ "groovy" }] = "groovy gvy",
  [{ "scala" }] = "scala sc",
  [{ "php" }] = "php phtml",
  [{ "ruby" }] = "rb rake gemspec",
  [{ "elixir", "erlang" }] = "ex exs",
  [{ "erlang" }] = "erl hrl",
  [{ "haskell" }] = "hs lhs",
  [{ "dart" }] = "dart",
  [{ "zig" }] = "zig zon",
  [{ "nix" }] = "nix",
  [{ "postgresql", "sqlite" }] = "sql",
  [{ "r" }] = "r rmd",
  [{ "julia" }] = "jl",
  [{ "cmake" }] = "cmake",
  [{ "gnu_make" }] = "mk mak",
  [{ "markdown" }] = "md markdown",
  [{ "latex" }] = "tex sty cls",
  [{ "css" }] = "css",
  [{ "sass", "css" }] = "scss sass",
  [{ "less", "css" }] = "less",
  [{ "html", "dom", "css" }] = "html htm xhtml",
  [{ "vue", "javascript", "dom", "css" }] = "vue",
  [{ "svelte", "javascript", "dom", "css" }] = "svelte",
  [{ "godot" }] = "gd",
  [{ "ocaml" }] = "ml mli",
  [{ "perl" }] = "pl pm",
  [{ "octave" }] = "m",
  [{ "jq" }] = "jq",
  [{ "clojure" }] = "clj cljs cljc edn",
  [{ "crystal" }] = "cr",
  [{ "nim" }] = "nim nims",
  [{ "d" }] = "d",
  [{ "bazel" }] = "bzl bazel",
  [{ "powershell" }] = "ps1 psm1 psd1",
  [{ "docker" }] = "dockerfile",
} do
  for ext in exts:gmatch "%S+" do
    M.extensions[ext] = bases
  end
end

--- Shebang interpreter (version digits stripped) -> doc bases.
--- @type table<string, string[]>
M.interpreters = {
  sh = { "bash" },
  bash = { "bash" },
  dash = { "bash" },
  ksh = { "bash" },
  mksh = { "bash" },
  zsh = { "zsh", "bash" },
  fish = { "fish" },
  python = { "python" },
  pypy = { "python" },
  node = { "node", "javascript" },
  nodejs = { "node", "javascript" },
  bun = { "javascript", "node" },
  deno = { "deno", "typescript", "javascript" },
  ["ts-node"] = { "typescript", "node" },
  tsx = { "typescript", "node" },
  lua = { "lua" },
  luajit = { "lua" },
  ruby = { "ruby" },
  perl = { "perl" },
  php = { "php" },
  Rscript = { "r" },
  julia = { "julia" },
  elixir = { "elixir" },
  escript = { "erlang" },
  ocaml = { "ocaml" },
  groovy = { "groovy" },
  kotlin = { "kotlin" },
  scala = { "scala" },
  dart = { "dart" },
  pwsh = { "powershell" },
  make = { "gnu_make" },
  tclsh = { "tcl_tk" },
  wish = { "tcl_tk" },
  octave = { "octave" },
}

-- interpreters whose name says the version: luajit is Lua 5.1
local INTERPRETER_VERSION = { luajit = "5.1" }

--- Interpreter of a shebang line and the version its name carries:
--- "#!/usr/bin/env -S python3.12 -u" -> "python", "3.12".
--- @param line string|nil
--- @return string|nil name, string|nil version
function M.parse_shebang(line)
  if type(line) ~= "string" or line:sub(1, 2) ~= "#!" then
    return nil
  end
  local words = vim.split(vim.trim(line:sub(3)), "%s+", { trimempty = true })
  local i = 1
  local prog = words[i] and words[i]:match "[^/]+$"
  if prog == "env" then
    i = i + 1
    -- env's own flags (-S, -i, -u NAME is rare enough to ignore) and VAR=value
    while words[i] and (words[i]:sub(1, 1) == "-" or words[i]:find("=", 1, true)) do
      i = i + 1
    end
    prog = words[i] and words[i]:match "[^/]+$"
  end
  if not prog or prog == "" then
    return nil
  end
  if M.interpreters[prog] then
    return prog, INTERPRETER_VERSION[prog]
  end
  local name, ver = prog:match "^(.-)%-?(%d[%d%.]*)$"
  if name and M.interpreters[name] then
    return name, ver
  end
  return prog, nil
end

--- Doc base of a login shell path ($SHELL): "/usr/bin/zsh" -> "zsh".
--- Shells without their own doc read as bash.
--- @param shell string|nil
--- @return string
function M.shell_base(shell)
  local name = shell and shell:match "[^/]+$"
  if name == "zsh" or name == "fish" then
    return name
  end
  return "bash"
end

local function set(words)
  local out = {}
  for w in words:gmatch "%S+" do
    out[w] = true
  end
  return out
end

local ZSH_FILES = set "zshrc zshenv zprofile zlogin zlogout"
local POSIX_FILES = set "profile bash_profile bash_login bash_logout bashrc xinitrc xprofile xsession xsessionrc envrc"
-- "*rc" files that are config for something else, not shell
local NOT_SHELL_RC =
  set "vimrc gvimrc exrc nanorc screenrc wgetrc curlrc gemrc irbrc pryrc psqlrc sqliterc lynxrc muttrc neomuttrc mailrc netrc npmrc yarnrc babelrc eslintrc prettierrc stylelintrc swcrc mocharc nycrc lintstagedrc editorrc"

--- Bases for a dotfile that is probably a shell script (".bashrc", ".xinitrc",
--- ".myapprc"), or nil when it is not shell. Runs after the filename rules and
--- the filetype table, so ".npmrc", ".eslintrc" and friends never reach it.
--- @param tail string file name without directory
--- @param shell_base string the user's shell as a doc base (M.shell_base)
--- @return string[]|nil
function M.rc_bases(tail, shell_base)
  local name = tail:gsub("^%.", "")
  if ZSH_FILES[name] then
    return { "zsh", "bash" }
  end
  -- sh syntax whatever the login shell is (fish never reads them; direnv runs bash)
  if POSIX_FILES[name] then
    return { "bash" }
  end
  if NOT_SHELL_RC[name] or not name:match "^[%w_.-]+rc$" then
    return nil
  end
  return shell_base == "zsh" and { "zsh", "bash" } or { shell_base }
end

--- Doc bases for a buffer, and how they were found. Tried in order:
--- filetype (with extra_filetypes and file-name rules), the file extension,
--- the shebang, then the rc-dotfile heuristic.
--- @param ctx { ft: string, name: string|nil, first_line: string|nil, extra: table|nil, shell: string|nil }
--- @return string[] bases
--- @return "filetype"|"extension"|"shebang"|"rc"|"none" how
--- @return { base: string, version: string }|nil hint version named by the shebang
function M.resolve(ctx)
  local name = ctx.name or ""
  local tail = name ~= "" and vim.fn.fnamemodify(name, ":t") or ""
  local interp, interp_version = M.parse_shebang(ctx.first_line)
  local interp_bases = interp and M.interpreters[interp]
  local hint = (interp_bases and interp_version) and { base = interp_bases[1], version = interp_version } or nil

  local bases = M.bases_for(ctx.ft or "", name, ctx.extra)
  if #bases > 0 then
    return bases, "filetype", hint
  end
  -- ".bashrc" has no extension for fnamemodify, so dotfiles fall through to rc
  local ext = tail:match "^.+%.([^.]+)$"
  local by_ext = ext and M.extensions[ext:lower()]
  if by_ext then
    return vim.deepcopy(by_ext), "extension", nil
  end
  if interp_bases then
    return vim.deepcopy(interp_bases), "shebang", hint
  end
  if tail ~= "" then
    local rc = M.rc_bases(tail, M.shell_base(ctx.shell))
    if rc and #rc > 0 then
      return rc, "rc", nil
    end
  end
  return {}, "none", nil
end

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

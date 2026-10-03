local langmap = require "devdocs.langmap"

local function resolve(ctx)
  local bases, how, hint = langmap.resolve(ctx)
  return { bases = bases, how = how, hint = hint }
end

describe("langmap.resolve", function()
  it("uses the filetype table first", function()
    eq({ bases = { "cpp", "c" }, how = "filetype" }, resolve { ft = "cpp", name = "/p/a.hh" })
    eq({ "lua" }, resolve({ ft = "lua", name = "/p/init.lua" }).bases)
  end)

  it("maps filetypes nvim gives without content", function()
    -- an empty a.tf is ft=tf (TinyFugue) until it has content
    eq({ "terraform" }, resolve({ ft = "tf", name = "/p/main.tf" }).bases)
    eq({ "zsh", "bash" }, resolve({ ft = "zsh", name = "/p/a.zsh" }).bases)
    eq({ "cpp" }, resolve({ ft = "tpp", name = "/p/a.tpp" }).bases)
  end)

  it("falls back to the extension when the filetype is empty or unmapped", function()
    for ext, want in pairs {
      h = "cpp",
      hh = "cpp",
      hpp = "cpp",
      cc = "cpp",
      cxx = "cpp",
      ["c++"] = "cpp",
      ipp = "cpp",
      cppm = "cpp",
      c = "c",
      tf = "terraform",
      tfvars = "terraform",
      hcl = "terraform",
      tofu = "opentofu",
      sh = "bash",
      bash = "bash",
      ksh = "bash",
      zsh = "zsh",
      lua = "lua",
      pyi = "python",
      mjs = "javascript",
      cts = "typescript",
    } do
      local r = resolve { ft = "", name = "/p/file." .. ext }
      eq("extension", r.how, ext)
      eq(want, r.bases[1], ext)
    end
    eq("cpp", resolve({ ft = "conf", name = "/p/A.HPP" }).bases[1])
  end)

  it("reads the shebang when there is no usable extension", function()
    local r = resolve { ft = "", name = "/p/tool", first_line = "#!/usr/bin/env python3.12" }
    eq({ bases = { "python" }, how = "shebang", hint = { base = "python", version = "3.12" } }, r)
    eq(
      { "node", "javascript" },
      resolve({ ft = "", name = "/p/x", first_line = "#!/usr/bin/env -S node --flag" }).bases
    )
    eq({ "bash" }, resolve({ ft = "", name = "/p/x", first_line = "#!/bin/bash -eu" }).bases)
    eq({ "zsh", "bash" }, resolve({ ft = "", name = "/p/x", first_line = "#! /usr/bin/zsh" }).bases)
    eq("5.1", resolve({ ft = "", name = "/p/x", first_line = "#!/usr/bin/luajit" }).hint.version)
    eq("3", resolve({ ft = "", name = "/p/x", first_line = "#!/usr/bin/env python3" }).hint.version)
    eq(nil, resolve({ ft = "", name = "/p/x", first_line = "#!/usr/bin/env bash" }).hint)
    eq("none", resolve({ ft = "", name = "/p/x", first_line = "# not a shebang" }).how)
  end)

  it("keeps a shebang version hint when the filetype already matched", function()
    local r = resolve { ft = "python", name = "/p/run", first_line = "#!/usr/bin/python3.11" }
    eq("filetype", r.how)
    eq({ base = "python", version = "3.11" }, r.hint)
  end)

  it("treats shell dotfiles as the user's shell", function()
    eq({ bases = { "bash" }, how = "rc" }, resolve { ft = "", name = "/home/u/.xinitrc", shell = "bash" })
    eq({ "zsh", "bash" }, resolve({ ft = "", name = "/home/u/.zshenv", shell = "bash" }).bases)
    eq({ "zsh", "bash" }, resolve({ ft = "", name = "/home/u/.myapprc", shell = "zsh" }).bases)
    eq({ "bash" }, resolve({ ft = "", name = "/home/u/.somethingrc" }).bases)
  end)

  it("does not call non-shell rc files shell", function()
    eq({ "npm" }, resolve({ ft = "dosini", name = "/p/.npmrc", shell = "bash" }).bases)
    eq({ "babel" }, resolve({ ft = "json", name = "/p/.babelrc", shell = "bash" }).bases)
    eq("none", resolve({ ft = "vim", name = "/home/u/.vimrc", shell = "bash" }).how)
  end)

  it("reports none when nothing matches", function()
    eq({ bases = {}, how = "none" }, resolve { ft = "", name = "/p/README" })
    eq({ bases = {}, how = "none" }, resolve { ft = "", name = "" })
  end)

  it("names the base of a shell path", function()
    eq("zsh", langmap.shell_base "/usr/bin/zsh")
    eq("fish", langmap.shell_base "/opt/homebrew/bin/fish")
    eq("bash", langmap.shell_base "/bin/sh")
    eq("bash", langmap.shell_base(nil))
  end)
end)

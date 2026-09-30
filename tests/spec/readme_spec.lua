local config = require "devdocs.config"

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h:h")

describe("README", function()
  local readme = table.concat(vim.fn.readfile(root .. "/README.md"), "\n")

  it("has a Defaults block identical to config.defaults", function()
    local block = readme:match "### Defaults\n\n```lua\n(.-)\n```"
    ok(block, "no ```lua block after '### Defaults'")
    local chunk, err = loadstring("return " .. block)
    ok(chunk, err)
    local ok_run, tbl = pcall(chunk)
    ok(ok_run, tbl)
    eq(config.defaults, tbl)
  end)

  it("mentions every subcommand and every highlight group", function()
    for name in pairs(require("devdocs.commands").subcommands) do
      ok(readme:find("`" .. name, 1, true) or readme:find(name .. " ", 1, true), "README lacks subcommand " .. name)
    end
    for group in pairs(require("devdocs.ui.float").HIGHLIGHTS) do
      ok(readme:find("`" .. group .. "`", 1, true), "README lacks highlight group " .. group)
    end
  end)

  it("ships a vimdoc that helptags accepts", function()
    local docdir = vim.fn.tempname()
    vim.fn.mkdir(docdir, "p")
    vim.fn.writefile(vim.fn.readfile(root .. "/doc/devdocs.txt"), docdir .. "/devdocs.txt")
    local ok_tags, err = pcall(vim.cmd, "helptags " .. vim.fn.fnameescape(docdir))
    ok(ok_tags, err)
    local tags = table.concat(vim.fn.readfile(docdir .. "/tags"), "\n")
    for _, tag in ipairs {
      ":DevDocs",
      "devdocs.setup()",
      "devdocs-install_as_needed",
      "devdocs-import",
      "devdocs-viewer",
      "devdocs-manager",
    } do
      ok(tags:find(tag, 1, true), "missing help tag " .. tag)
    end
    vim.fn.delete(docdir, "rf")
  end)
end)

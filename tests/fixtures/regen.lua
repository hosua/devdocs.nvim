-- Regenerate the golden .md / .anchors.json next to every fixture .html:
--
--   make golden        (nvim --headless -u NONE -l tests/fixtures/regen.lua)
--
-- Fixture names are <slug>__<page>.html with "/" in the page written as "~".
-- Review the diff before committing: the goldens are the converter's spec.
local this = debug.getinfo(1, "S").source:gsub("^@", "")
local dir = vim.fn.fnamemodify(this, ":p:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(dir, ":h:h"))
local convert = require "devdocs.convert"
for _, f in ipairs(vim.fn.glob(dir .. "/*.html", false, true)) do
  local base = vim.fn.fnamemodify(f, ":t:r")
  local slug, page = base:match "^(.-)__(.*)$"
  page = page:gsub("~", "/")
  local lines, anchors = convert.html(table.concat(vim.fn.readfile(f), "\n"), { slug = slug, page = page })
  vim.fn.writefile(lines, dir .. "/" .. base .. ".md")
  local keys = vim.tbl_keys(anchors)
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = ("  %s: %d"):format(vim.json.encode(k), anchors[k])
  end
  vim.fn.writefile({ "{", table.concat(parts, ",\n"), "}" }, dir .. "/" .. base .. ".anchors.json")
  print(("%s: %d lines, %d anchors"):format(base, #lines, #keys))
end

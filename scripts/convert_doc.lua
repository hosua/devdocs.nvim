-- Convert one downloaded doc into the on-disk layout. Runs in a child process:
--
--   nvim --headless -u NONE -l scripts/convert_doc.lua <src_dir> <out_dir>
--
-- <src_dir> holds db.json and index.json (and meta.json from a tarball).
-- <out_dir> receives pages/<path>.md, entries.tsv, anchors.json, meta.json.
-- Progress goes to stdout as "progress <done> <total>", the last line is
-- "done <pages> <entries> <skipped>"; any failure prints "error <msg>" and
-- exits 1. installer.lua parses these lines.
local this = debug.getinfo(1, "S").source:gsub("^@", "")
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.runtimepath:prepend(root)

local convert = require "devdocs.convert"
local paths = require "devdocs.paths"
local store = require "devdocs.store"

local function fail(msg)
  io.stdout:write("error " .. tostring(msg):gsub("\n", " ") .. "\n")
  io.stdout:flush()
  os.exit(1)
end

local src, out = arg[1], arg[2]
if not src or not out then
  fail "usage: convert_doc.lua <src_dir> <out_dir>"
end

local db, dberr = store.read_json(src .. "/db.json")
if not db then
  fail("db.json: " .. tostring(dberr))
end
local index, ierr = store.read_json(src .. "/index.json")
if not index or type(index.entries) ~= "table" then
  fail("index.json: " .. tostring(ierr))
end
local meta = store.read_json(src .. "/meta.json") or {}

-- deterministic order so progress is meaningful and output is reproducible
local keys = vim.tbl_keys(db)
table.sort(keys)
local total = #keys
local slug = meta.slug or vim.fn.fnamemodify(out, ":t")

local anchors, pages, skipped = {}, 0, {}
vim.fn.mkdir(out .. "/pages", "p")
for i, page in ipairs(keys) do
  local html = db[page]
  local ok, err = pcall(function()
    if type(html) ~= "string" then
      error "not a string"
    end
    local file = out .. "/pages/" .. paths.encode_page(page)
    local lines, page_anchors = convert.html(html, { slug = slug, page = page })
    vim.fn.mkdir(vim.fs.dirname(file), "p")
    local wok, werr = store.write_file(file, table.concat(lines, "\n") .. "\n")
    if not wok then
      error(werr)
    end
    if next(page_anchors) then
      anchors[page] = page_anchors
    end
    pages = pages + 1
  end)
  if not ok then
    skipped[#skipped + 1] = page .. ": " .. tostring(err)
  end
  if i % 50 == 0 or i == total then
    io.stdout:write(("progress %d %d\n"):format(i, total))
    io.stdout:flush()
  end
end

local entries = {}
for _, e in ipairs(index.entries) do
  if type(e.name) == "string" and type(e.path) == "string" then
    entries[#entries + 1] = { name = e.name, path = e.path, type = type(e.type) == "string" and e.type or "" }
  end
end

local ok, err = store.write_file(out .. "/entries.tsv", store.encode_entries(entries))
if not ok then
  fail("entries.tsv: " .. tostring(err))
end
ok, err = store.write_json(out .. "/anchors.json", { pages = anchors }, "anchors")
if not ok then
  fail("anchors.json: " .. tostring(err))
end
ok, err = store.write_json(out .. "/meta.json", {
  slug = slug,
  name = meta.name,
  type = meta.type,
  doc_version = meta.version,
  release = meta.release,
  mtime = meta.mtime,
  db_size = meta.db_size,
  installed_at = os.time(),
  entry_count = #entries,
  page_count = pages,
  types = index.types,
  skipped = skipped,
}, "meta")
if not ok then
  fail("meta.json: " .. tostring(err))
end

io.stdout:write(("done %d %d %d\n"):format(pages, #entries, #skipped))
io.stdout:flush()
os.exit(0)

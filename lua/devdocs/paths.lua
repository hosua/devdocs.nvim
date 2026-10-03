--- Paths: where everything lives on disk and how a devdocs page path becomes
--- a file name. Pure: reads config, touches nothing.
---
---   <data_dir>/manifest.json               cached docs.json
---   <data_dir>/state.json                  enabled docs, per-project versions, recent pages
---   <data_dir>/docs/<slug>/meta.json       what is installed and from which manifest entry
---   <data_dir>/docs/<slug>/entries.tsv     name \t path \t type
---   <data_dir>/docs/<slug>/anchors.json    page -> { fragment id -> line }
---   <data_dir>/docs/<slug>/pages/<path>.md one file per db.json key
---   <data_dir>/tmp/<slug>.<pid>/           staging for an install in progress
---   <data_dir>/releases/<product>.json     cached endoflife.date release cycles
local M = {}

local SITE = "https://devdocs.io"

local function data_dir()
  return require("devdocs.config").get().data_dir
end

function M.data_dir()
  return data_dir()
end

function M.manifest_file()
  return data_dir() .. "/manifest.json"
end

function M.state_file()
  return data_dir() .. "/state.json"
end

function M.releases_dir()
  return data_dir() .. "/releases"
end

function M.docs_dir()
  return data_dir() .. "/docs"
end

--- A slug is what the manifest calls a doc: "css", "python~3.12", "node~22_lts".
--- Anything else is rejected so a slug can never escape docs_dir().
--- @param slug string
--- @return boolean
function M.valid_slug(slug)
  return type(slug) == "string" and slug:match "^[%w][%w%.%-_~+]*$" ~= nil and not slug:find("..", 1, true)
end

local function checked(slug)
  if not M.valid_slug(slug) then
    error(("devdocs: invalid doc slug %q"):format(tostring(slug)), 2)
  end
  return slug
end

function M.doc_dir(slug)
  return M.docs_dir() .. "/" .. checked(slug)
end

function M.meta_file(slug)
  return M.doc_dir(slug) .. "/meta.json"
end

function M.entries_file(slug)
  return M.doc_dir(slug) .. "/entries.tsv"
end

function M.anchors_file(slug)
  return M.doc_dir(slug) .. "/anchors.json"
end

function M.pages_dir(slug)
  return M.doc_dir(slug) .. "/pages"
end

function M.tmp_dir(slug)
  return data_dir() .. "/tmp/" .. checked(slug) .. "." .. vim.uv.os_getpid()
end

--- "selectors/:default#syntax" -> "selectors/:default", "syntax"
--- @param path string
--- @return string page, string|nil fragment
function M.split_fragment(path)
  local page, frag = path:match "^([^#]*)#(.*)$"
  if page then
    return page, frag
  end
  return path, nil
end

--- Percent-encode everything outside [A-Za-z0-9._-] within each path
--- segment, so the file name is safe on every filesystem and round-trips.
--- Rejects empty, absolute and traversing paths: db.json keys are untrusted.
--- @param page string devdocs page path without fragment
--- @return string relative file path ending in .md
function M.encode_page(page)
  if type(page) ~= "string" or page == "" or page:sub(1, 1) == "/" then
    error(("devdocs: invalid page path %q"):format(tostring(page)), 2)
  end
  local segments = {}
  for seg in vim.gsplit(page, "/", { plain = true }) do
    if seg == "" or seg == "." or seg == ".." then
      error(("devdocs: invalid page path %q"):format(page), 2)
    end
    segments[#segments + 1] = seg:gsub("[^%w%._%-]", function(c)
      return ("%%%02X"):format(c:byte())
    end)
  end
  return table.concat(segments, "/") .. ".md"
end

--- Inverse of encode_page.
--- @param file string relative file path ending in .md
--- @return string page
function M.decode_page(file)
  local stem = file:gsub("%.md$", "")
  return (stem:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- @param slug string
--- @param page string page path (fragment allowed, ignored)
--- @return string absolute .md file
function M.page_file(slug, page)
  return M.pages_dir(slug) .. "/" .. M.encode_page((M.split_fragment(page)))
end

--- Absolute page file -> slug, page path; nil when the file is not under docs_dir().
--- @param file string
--- @return string|nil slug, string|nil page
function M.page_from_file(file)
  local rel = file:sub(#M.docs_dir() + 2)
  if file:sub(1, #M.docs_dir() + 1) ~= M.docs_dir() .. "/" then
    return nil
  end
  local slug, encoded = rel:match "^([^/]+)/pages/(.+%.md)$"
  if not slug then
    return nil
  end
  return slug, M.decode_page(encoded)
end

--- The page on devdocs.io, fragment included.
--- @param slug string
--- @param path string|nil
--- @return string
function M.browser_url(slug, path)
  if not path or path == "" then
    return SITE .. "/" .. slug .. "/"
  end
  return SITE .. "/" .. slug .. "/" .. path
end

--- Expand the configured doc_url template.
--- @param template string
--- @param slug string
--- @param file string "db.json" | "index.json"
--- @return string
function M.doc_url(template, slug, file)
  return (template:gsub("{slug}", checked(slug)):gsub("{file}", file))
end

return M

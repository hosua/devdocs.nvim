local config = require "devdocs.config"
local mirror = require "devdocs.mirror"

describe("mirror", function()
  it("defaults the clone dir under data_dir and honours mirror.dir", function()
    config.resolve { data_dir = "/tmp/dd" }
    eq("/tmp/dd/mirror/devdocs", mirror.dir())
    config.resolve { data_dir = "/tmp/dd", mirror = { dir = "/srv/devdocs" } }
    eq("/srv/devdocs", mirror.dir())
    config.resolve()
  end)

  it("derives json-source install settings for a mirror tree", function()
    eq({
      source = "json",
      doc_url = "file:///srv/devdocs/public/docs/{slug}/{file}",
      manifest_url = "file:///srv/devdocs/public/docs/docs.json",
    }, mirror.source_for "/srv/devdocs")
  end)

  it("writes a clone + download script that quotes its inputs", function()
    local s = mirror.script {
      dir = "/tmp/my dir/devdocs",
      repo = "https://github.com/freeCodeCamp/devdocs",
      image = "ghcr.io/freecodecamp/devdocs:latest",
      docker = "docker",
      git = "git",
      force = false,
    }
    ok(s:find("set -euo pipefail", 1, true))
    ok(s:find("dir='/tmp/my dir/devdocs'", 1, true), s)
    ok(s:find("clone --depth 1 'https://github.com/freeCodeCamp/devdocs'", 1, true))
    ok(s:find("pull --ff-only", 1, true))
    ok(s:find("thor docs:download --all", 1, true))
    ok(s:find('-v "$dir/public/docs:/devdocs/public/docs"', 1, true))
    ok(not s:find("rm -rf", 1, true))
  end)

  it("force re-clones and --scrape generates the named docs", function()
    local s = mirror.script {
      dir = "/d",
      repo = "r",
      image = "i",
      docker = "docker",
      git = "git",
      force = true,
      scrape = { "css", "lua~5.4" },
    }
    ok(s:find('rm -rf "$dir"', 1, true))
    ok(s:find("thor docs:generate 'css' 'lua~5.4'", 1, true), s)
    ok(not s:find("docs:download", 1, true))
  end)
end)

local installer = require "devdocs.installer"

describe("installer (pure)", function()
  it("backs off exponentially with a cap", function()
    local got = {}
    for i = 1, 7 do
      got[i] = installer.backoff(i)
    end
    eq({ 2, 4, 8, 16, 32, 60, 60 }, got)
  end)

  it("detects outdated installs by manifest mtime", function()
    ok(installer.is_outdated({ mtime = 10 }, { mtime = 11 }))
    ok(not installer.is_outdated({ mtime = 11 }, { mtime = 11 }))
    ok(not installer.is_outdated({}, { mtime = 11 }))
  end)

  it("plans install / update / skip / unknown", function()
    local docs =
      { css = { slug = "css", mtime = 5 }, lua = { slug = "lua", mtime = 9 }, go = { slug = "go", mtime = 1 } }
    local installed = { lua = { mtime = 3 }, go = { mtime = 1 } }
    eq({
      { slug = "css", action = "install" },
      { slug = "lua", action = "update" },
      { slug = "go", action = "skip" },
      { slug = "rust", action = "unknown" },
    }, installer.plan({ "css", "lua", "go", "rust" }, docs, installed))
    eq({ { slug = "go", action = "install" } }, installer.plan({ "go" }, docs, installed, { force = true }))
    eq({ { slug = "lua", action = "skip" } }, installer.plan({ "lua" }, docs, installed, { update = false }))
  end)

  it("rejects bad slugs without touching the queue", function()
    local got
    installer.install("../x", nil, function(ok, err)
      got = { ok, err }
    end)
    eq(false, got[1])
    ok(got[2]:find("invalid", 1, true))
    eq({}, installer.queue)
  end)
end)

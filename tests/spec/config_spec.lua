local config = require "devdocs.config"

describe("config", function()
  it("resolves defaults with no opts", function()
    local cfg, unknown = config.resolve()
    eq(config.defaults, cfg)
    eq({}, unknown)
  end)

  it("reports unknown keys instead of ignoring them", function()
    local notify = vim.notify
    vim.notify = function() end
    local _, unknown = config.resolve { notfy = false }
    vim.notify = notify
    eq({ "notfy" }, unknown)
  end)

  it("validates list.release_dates as a boolean", function()
    eq(false, config.resolve({ list = { release_dates = false } }).list.release_dates)
    ok(not pcall(config.resolve, { list = { release_dates = "yes" } }))
    config.resolve()
  end)

  it("does not mutate the defaults table", function()
    local before = vim.deepcopy(config.defaults)
    config.resolve { notify = false }
    eq(before, config.defaults)
  end)
end)

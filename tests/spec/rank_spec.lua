local rank = require "devdocs.rank"

local function e(name, path)
  return { name = name, path = path or name, type = "t" }
end

describe("rank", function()
  it("scores exact, case-insensitive and paren-stripped matches highest", function()
    eq(100, rank.score_name("std::cout", "std::cout"))
    eq(95, rank.score_name("Array.prototype.map()", "array.prototype.map()"))
    eq(95, rank.score_name("os.path.join()", "os.path.join"))
    eq(nil, rank.score_name("x", ""))
  end)

  it("ranks a qualified entry ending in the query above a substring", function()
    local suffix = rank.score_name("std::cout", "cout")
    local sub = rank.score_name("std::cout_iterator", "cout")
    ok(suffix > sub, ("%s > %s"):format(suffix, sub))
    ok(rank.score_name("os.path.join()", "join") > rank.score_name("os.path.join()", "path"))
    ok(rank.score_name("fs.readFile()", "readFile") > rank.score_name("fs.readFileSync()", "readFile"))
  end)

  it("prefers shorter qualifiers for the same suffix", function()
    ok(rank.score_name("io.open()", "open") > rank.score_name("some.long.module.open()", "open"))
  end)

  it("matches prefixes and fuzzy subsequences with low scores", function()
    local prefix = rank.score_name("os.path.join()", "os.path")
    ok(prefix >= 35 and prefix < 85, tostring(prefix))
    local fuzzy = rank.score_name("grid-template-areas", "gta")
    ok(fuzzy and fuzzy <= 25, tostring(fuzzy))
    eq(nil, rank.score_name("grid", "zzz"))
  end)

  it("looks up ordered candidates across tiers", function()
    local sources = {
      {
        slug = "cpp",
        tier = 1,
        entries = { e "std::cout", e "std::wcout", e("std::basic_ostream::operator<<", "io/op") },
      },
      { slug = "c", tier = 2, entries = { e "cout_something" } },
      { slug = "javascript", tier = 3, entries = { e "console.log()" } },
    }
    local hits = rank.lookup({ "std::cout", "cout" }, sources)
    eq("std::cout", hits[1].entry.name)
    eq("cpp", hits[1].slug)
    eq(1, hits[1].candidate)
    ok(rank.decisive(hits))
    -- the tier-1 exact hit outranks the same name in a lower tier
    local tiers = rank.lookup({ "log" }, {
      { slug = "node", tier = 2, entries = { e "console.log()" } },
      { slug = "javascript", tier = 1, entries = { e "console.log()" } },
    })
    eq("javascript", tiers[1].slug)
    eq("node", tiers[2].slug)
  end)

  it("is not decisive between two close, different pages", function()
    local hits = rank.lookup({ "map" }, {
      {
        slug = "javascript",
        tier = 2,
        entries = { e("Array.prototype.map()", "a/map"), e("Map.prototype.map()", "b/map") },
      },
    })
    eq(2, #hits)
    ok(not rank.decisive(hits))
    eq(false, rank.decisive {})
  end)

  it("honours limit and min_score", function()
    local src = { { slug = "x", tier = 2, entries = { e "aaa", e "aab", e "zzz" } } }
    eq(1, #rank.lookup({ "aa" }, src, { limit = 1 }))
    eq(0, #rank.lookup({ "zz" }, src, { min_score = 90 }))
  end)

  it("gives identical lookups with the substring prefilter", function()
    local names = {
      "std::cout",
      "std::cout_iterator",
      "os.path.join()",
      "os.path",
      "join",
      "Array.prototype.join()",
      "String.prototype.at()",
      "string.format",
      "format()",
      "grid-template-areas",
      "GTA",
      "io.open()",
      "readFile",
      "fs.readFile()",
      "fs.readFileSync()",
      "Join",
      "  spaced  ",
    }
    local entries = vim.tbl_map(function(n)
      return e(n)
    end, names)
    local with = { { slug = "x", tier = 1, entries = entries, names = rank.normalized_names(entries) } }
    local without = { { slug = "x", tier = 1, entries = entries } }
    for _, cands in ipairs {
      { "join" },
      { "os.path.join", "join" },
      { "cout" },
      { "std::cout", "cout" },
      { "gta" },
      { "readFile" },
      { "FORMAT" },
      { "at()" },
      { "spaced" },
      { "zzz" },
    } do
      eq(rank.lookup(cands, without, { limit = 50 }), rank.lookup(cands, with, { limit = 50 }), cands[1])
    end
    -- below 30 the fuzzy tier can match without a substring: no prefilter there
    eq(rank.lookup({ "gta" }, without, { min_score = 5 }), rank.lookup({ "gta" }, with, { min_score = 5 }))
  end)
end)

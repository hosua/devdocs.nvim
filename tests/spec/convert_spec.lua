local convert = require "devdocs.convert"

local CTX = { slug = "css", page = "properties/grid" }

local function md(html, ctx)
  local lines = convert.html(html, ctx or CTX)
  return table.concat(lines, "\n")
end

describe("convert", function()
  it("decodes entities", function()
    eq("<a> & \"b\" 'c' © → x", convert.decode_entities "&lt;a&gt; &amp; &quot;b&quot; &#39;c&#39; &copy; &rarr; x")
    eq("ü ü ü", convert.decode_entities "&#252; &#xFC; &#XFC;")
    eq("&unknown; plain", convert.decode_entities "&unknown; plain")
    eq("a b", convert.decode_entities "a&nbsp;b")
  end)

  it("reads attributes with quotes, apostrophes, none, and dashes", function()
    eq("css", convert.attr(' data-language="css"', "data-language"))
    eq("x y", convert.attr(" class='x y' id=z", "class"))
    eq("z", convert.attr(" class='x y' id=z", "id"))
    eq(nil, convert.attr(" idx=1", "id"))
    eq(nil, convert.attr("", "id"))
    eq("a&b", convert.attr(' href="a&amp;b"', "href"))
  end)

  it("resolves relative links to devdocs:// urls", function()
    eq("devdocs://cpp/header/iostream", convert.link("../header/iostream", { slug = "cpp", page = "io/cout" }))
    eq("devdocs://cpp/io/cin", convert.link("cin", { slug = "cpp", page = "io/cout" }))
    eq("devdocs://cpp/io/cout#Notes", convert.link("#Notes", { slug = "cpp", page = "io/cout" }))
    eq("devdocs://cpp/language/init#x", convert.link("../language/init#x", { slug = "cpp", page = "io/cout" }))
    eq("devdocs://cpp/abs", convert.link("/abs", { slug = "cpp", page = "io/cout" }))
    eq("https://x.y/z", convert.link("https://x.y/z", { slug = "cpp", page = "io/cout" }))
    eq("mailto:a@b", convert.link("mailto:a@b", { slug = "cpp", page = "io/cout" }))
    eq("devdocs://css/index", convert.link("index", { slug = "css", page = "index" }))
  end)

  it("renders headings with anchors", function()
    local lines, anchors = convert.html('<h1 id="top">Title</h1><p>Body</p><h2 id="syntax">Syntax</h2>', CTX)
    eq({ "# Title", "", "Body", "", "## Syntax" }, lines)
    eq({ top = 1, syntax = 5 }, anchors)
  end)

  it("anchors an empty span before its heading (sphinx)", function()
    local lines, anchors = convert.html('<span id="mod"></span><h1>os.path</h1><p>x</p>', CTX)
    eq({ "# os.path", "", "x" }, lines)
    eq(1, anchors.mod)
  end)

  it("keeps a dt id on the dt line", function()
    local lines, anchors =
      convert.html('<p>intro</p><dl><dt id="f"><code>f(x)</code></dt><dd><p>Does f.</p></dd></dl>', CTX)
    eq({ "intro", "", "**`f(x)`**", "", "  Does f." }, lines)
    eq(3, anchors.f)
  end)

  it("fences pre with its language and decodes entities inside", function()
    eq("```css\na &lt;\n```", md '<pre data-language="css">a &amp;lt;\n</pre>')
    eq("```js\nlet a = 1;\n```", md '<pre><code class="language-js">let a = 1;</code></pre>')
    eq("```\nx\n```", md "<pre>x</pre>")
    eq("````\n```\n````", md "<pre>```</pre>")
  end)

  it("strips highlight spans inside pre", function()
    eq(
      "```py\nprint(1)\n```",
      md '<pre data-language="py"><span class="k">print</span>(<span class="m">1</span>)</pre>'
    )
  end)

  it("renders inline markup", function()
    eq("a **b** *c* `d` e", md "<p>a <strong>b</strong> <em>c</em> <code>d</code> e</p>")
    eq("**Source:** [x](https://x)", md '<p><strong>Source: </strong><a href="https://x">x</a></p>')
    eq("[`std::cin`](devdocs://css/properties/cin) is", md '<p><code><a href="cin">std::cin</a></code> is</p>')
    eq("`a` b", md "<p><code> a </code> b</p>")
    eq("x", md '<p>x<a href="y"></a></p>')
    eq("a\nb", md "<p>a<br>b</p>")
  end)

  it("collapses whitespace and drops empty wrappers", function()
    eq("a b c", md "<p>  a \n  b\t\tc </p>")
    eq("x", md "<p>x<strong> </strong><code></code></p>")
  end)

  it("treats block tags inside summary and dt as spaces", function()
    eq(
      "**Baseline Widely available**\n\nbody",
      md '<details><summary><div class="t">Baseline <span>Widely available</span></div></summary><div><p>body</p></div></details>'
    )
  end)

  it("renders lists, nested and ordered with a start", function()
    eq("- a\n- b\n  - b1\n  - b2\n- c", md "<ul><li>a</li><li>b<ul><li>b1</li><li>b2</li></ul></li><li>c</li></ul>")
    eq("3. x\n4. y", md '<ol start="3"><li>x</li><li>y</li></ol>')
    eq("- a\n\n  ```\n  code\n  ```", md "<ul><li>a<pre>code</pre></li></ul>")
  end)

  it("renders blockquotes with the prefix", function()
    eq("> a\n>\n> b", md "<blockquote><p>a</p><p>b</p></blockquote>")
  end)

  it("renders tables as pipe tables with escaped pipes", function()
    eq(
      "| A   | B    |\n| --- | ---- |\n| 1   | x\\|y |\n| `c` | d    |",
      md "<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>x|y</td></tr><tr><td><code>c</code></td><td>d</td></tr></table>"
    )
  end)

  it("turns cppreference declaration tables into code blocks", function()
    eq(
      "# std::cout\n\n```c\nextern std::ostream cout;\n```\n\n```c\nextern std::wostream wcout;\n```\n\nText",
      md '<h1>std::cout</h1><table class="t-dcl-begin"><tr><th>Defined in</th></tr><tr class="t-dcl"><td><pre data-language="c">extern std::ostream cout;\n</pre></td><td>(1)</td></tr><tr class="t-dcl"><td><pre data-language="c">extern std::wostream wcout;\n</pre></td><td>(2)</td></tr></table><p>Text</p>'
    )
  end)

  it("skips scripts, styles, svg and comments", function()
    eq("a b", md "<p>a <script>x()</script><style>p{}</style><svg><path d='1'/></svg><!-- c --> b</p>")
  end)

  it("renders images and rules", function()
    eq("![alt](i.png)", md '<p><img src="i.png" alt="alt"></p>')
    eq("a\n\n---\n\nb", md "<p>a</p><hr><p>b</p>")
  end)

  it("survives malformed html", function()
    local lines = convert.html("<p>a <b>b <i>c</b> d</p> stray < lt <div", CTX)
    ok(#lines > 0)
    ok(lines[1]:find("a", 1, true) and lines[1]:find("d", 1, true), lines[1])
  end)

  it("handles an empty document", function()
    eq({}, (convert.html("", CTX)))
    eq({}, (convert.html("  <div></div> ", CTX)))
  end)

  describe("golden fixtures", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:gsub("^@", ""), ":p:h:h") .. "/fixtures"
    for _, f in ipairs(vim.fn.glob(root .. "/*.html", false, true)) do
      local base = vim.fn.fnamemodify(f, ":t:r")
      it(base, function()
        local slug, page = base:match "^(.-)__(.*)$"
        page = page:gsub("~", "/")
        local html = table.concat(vim.fn.readfile(f), "\n")
        local lines, anchors = convert.html(html, { slug = slug, page = page })
        local expected = vim.fn.readfile(root .. "/" .. base .. ".md")
        eq(expected, lines, "regenerate with: make golden")
        local want = vim.json.decode(table.concat(vim.fn.readfile(root .. "/" .. base .. ".anchors.json"), "\n"))
        eq(want, anchors)
      end)
    end
  end)
end)

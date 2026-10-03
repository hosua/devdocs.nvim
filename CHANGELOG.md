# Changelog

## [0.4.0](https://github.com/hosua/devdocs.nvim/compare/v0.3.0...v0.4.0) (2026-10-03)


### Features

* add a doc index view opened by :DevDocs open and I, like devdocs.io's sidebar ([#18](https://github.com/hosua/devdocs.nvim/issues/18)) ([f8c3cc1](https://github.com/hosua/devdocs.nvim/commit/f8c3cc180b72cf1eab8208021264d4e468a66f8f))

## [0.3.0](https://github.com/hosua/devdocs.nvim/compare/v0.2.0...v0.3.0) (2026-10-03)


### Features

* fall back to LSP hover when looking up a project variable ([#13](https://github.com/hosua/devdocs.nvim/issues/13)) ([97253e2](https://github.com/hosua/devdocs.nvim/commit/97253e242bdca45c204d77f09ebb49ab075efe37))
* paginate the viewer with p, jump between sections and chapters, and show help as aligned tables ([#15](https://github.com/hosua/devdocs.nvim/issues/15)) ([a827b3a](https://github.com/hosua/devdocs.nvim/commit/a827b3aa5e6b8629e6e5507d0f6bc2ce8fb6964b))
* show a "nothing to document" popup for strings, comments, numbers, operators and names declared in the buffer ([#13](https://github.com/hosua/devdocs.nvim/issues/13)) ([97253e2](https://github.com/hosua/devdocs.nvim/commit/97253e242bdca45c204d77f09ebb49ab075efe37))

## [0.2.0](https://github.com/hosua/devdocs.nvim/compare/v0.1.0...v0.2.0) (2026-10-03)

### Features

* list manager grouped by language, release dates, bulk delete and prune ([#14](https://github.com/hosua/devdocs.nvim/pull/14)) ([9873d0c](https://github.com/hosua/devdocs.nvim/commit/9873d0cce0536ccd1041d5a0cdfbb3cb0473de8f))

### Improvements

* scope lookups to the buffer's language and cache detection per project ([#11](https://github.com/hosua/devdocs.nvim/pull/11)) ([f83f281](https://github.com/hosua/devdocs.nvim/commit/f83f2811c9da8f3f9ef168c355441a6be2ffe56a))

### Bug Fixes

* open the whole page at the current section when pressing p ([#12](https://github.com/hosua/devdocs.nvim/pull/12)) ([ff38bf3](https://github.com/hosua/devdocs.nvim/commit/ff38bf36bfa64af5b12460fe622d960e1c63874e))

## [0.1.0](https://github.com/hosua/devdocs.nvim/commits/v0.1.0) (2026-09-30)

### Features

* Mason-like list manager (:DevDocs list) ([#8](https://github.com/hosua/devdocs.nvim/pull/8)) ([2f0d7d7](https://github.com/hosua/devdocs.nvim/commit/2f0d7d7acd535c8627e4adca5a2bd69df7106735))
* background installer with bounded queue, retries and atomic replace ([#3](https://github.com/hosua/devdocs.nvim/pull/3)) ([a2c4cfb](https://github.com/hosua/devdocs.nvim/commit/a2c4cfbdd6e1a28bab413e93e12729b635233ed5))
* data layout, atomic JSON store, manifest cache and curl fetch ([#1](https://github.com/hosua/devdocs.nvim/pull/1)) ([3112974](https://github.com/hosua/devdocs.nvim/commit/31129742cc3ac82ac30637c0bfd52e494cab2e76))
* entry ranking, page/section index with examples, ripgrep search backend ([#5](https://github.com/hosua/devdocs.nvim/pull/5)) ([35cd1f7](https://github.com/hosua/devdocs.nvim/commit/35cd1f71522ec25c2fad7ae12a2ff5cfcb4ee563))
* filetype/Mason doc mapping, import globbing and project version detection ([#4](https://github.com/hosua/devdocs.nvim/pull/4)) ([80c6a62](https://github.com/hosua/devdocs.nvim/commit/80c6a62f1409c206333c770a9b535401771e6b91))
* mirror command, checkhealth, README and vimdoc ([#9](https://github.com/hosua/devdocs.nvim/pull/9)) ([5bccfc3](https://github.com/hosua/devdocs.nvim/commit/5bccfc3c139929bdd7fc2a9bad943ec1cd1a2f2c))
* pure-Lua HTML to markdown converter with anchors and golden fixtures ([#2](https://github.com/hosua/devdocs.nvim/pull/2)) ([87f782d](https://github.com/hosua/devdocs.nvim/commit/87f782dbabd828c74a97440172b2b1ee25dff27a))
* telescope search picker with async ripgrep and entry-name mode ([#7](https://github.com/hosua/devdocs.nvim/pull/7)) ([e3d15e7](https://github.com/hosua/devdocs.nvim/commit/e3d15e7b0eb2d5620f97b5c1d781d6dbeeccfaf1))
* viewer float, symbol lookup, definition/example/open commands ([#6](https://github.com/hosua/devdocs.nvim/pull/6)) ([a0ae379](https://github.com/hosua/devdocs.nvim/commit/a0ae379eec12374bfb702dbd5fa2b676224bfcc7))

### Bug Fixes

* normalize docs.json entries (null version/alias decode to vim.NIL) ([#10](https://github.com/hosua/devdocs.nvim/pull/10)) ([c2e4ab0](https://github.com/hosua/devdocs.nvim/commit/c2e4ab04422f00562dd0a7ab27ace2bd0ee904e1))

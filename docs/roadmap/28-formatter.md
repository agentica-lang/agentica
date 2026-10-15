## Phase 28: Formatter

Specified in [`docs/future/47-formatter.md` section
47](../future/47-formatter.md#47-code-formatter-agentica-fmt). Phase 28 adds
`agentica fmt`, one printer for `.agc` files. It also moves the width rule of
§45.5 into `agentica check` (`CHECK-LINE-TOO-LONG`), which replaces
`tests/test_style_line_width.py`. Its items keep the numbers of §47.8 (47a to
47d), so the spec and this file match. It is row 7.9 of the [roadmap](README.md)
order, deferred until after the bootstrap of the self-hosted front end
([§35](../future/35-self-hosting.md), step 8): the formatter is written in
Agentica in `compiler/`, on its lexer and parser. Item 47d is outside that
order: it waits for the language server (§43, not scheduled). Each item has its
own PR, with its own tests and docs. The open questions of §47.9 need the
owner's answers before 47b starts.

- [ ] **47a: comments and the side list (§47.4).**
  - **Lexer:** `lex_with_comments` in `compiler/lexer.agc`, which returns the
    plain comments with their span, text and an own-line flag. Plain `lex` and
    `parse` keep their output and their goldens.
  - **Attachment:** the rules and the position table of §47.4 in
    `compiler/format_comments.agc`. Each comment becomes leading, trailing or
    dangling on one node, and trailing comments are placed before layout.
  - **Tests:** the table of (node, role) pairs for a set of inputs (§47.7).
- [ ] **47b: printer and `--check` (§47.5 to §47.7).**
  - **Printer:** the document type (text, groups, line suffixes, break-parent,
    `fill`), the fit check and the layout rules in `compiler/format_doc.agc` and
    `compiler/format_layout.agc`, with the driver in `compiler/format.agc`. It
    covers every syntax landed by then, heredocs included (row 7.6, phase 15).
  - **CLI:** `agentica fmt --check` and the `--tree` debugging flag only, so CI
    can run them. `make fmt-check` runs `--check` over `compiler/` and
    `stdlib/`.
  - **Tests:** `tests/test_fmt.py` (Python unittest): the goldens of
    `tests/fixtures/fmt/`, the round trip on the normal form, the idempotence
    tests, and the independent peer (§47.7). The corpus runs in the slow tier.
  - **Reformat:** the one-time reformat of what the rules change. A change in
    `stdlib/` moves line numbers in the `std/` stack-trace goldens, so that PR
    runs `make goldens`.
  - **Docs:** the note on trailing commas in `docs/grammar/04-lexical.md`
    (§47.9, question 4).
- [ ] **47c: CLI, `[style]` and the width check (§47.2, §47.9).**
  - **CLI:** write mode in place, `-` for standard input, the exit codes of
    §47.2, `FMT-USAGE`, and the refusal of a file that does not parse (exit 1,
    the file untouched).
  - **Manifest:** the nearest `agentica.toml`, read with `std/toml`, and the
    default width of §47.9, question 1. The only `[style]` key is
    `max_line_width`.
  - **Width:** `agentica check` reports `CHECK-LINE-TOO-LONG` for a line over
    the width (§45.5), and CI runs it over `compiler/` and `stdlib/`. This
    replaces `tests/test_style_line_width.py`, which goes in the same PR
    (question 9 in §47.9). The code is confirmed by the owner.
  - **Removal:** question 7 (§47.9) decides what `compiler/builtins_data.agc`
    and `compiler/check_tables.agc` become, and their header comments change in
    this PR.
  - **Tests:** the CLI tests of §47.7, hermetic, in temporary folders.
  - **Docs:** a `CHANGELOG.md` entry under `## [Unreleased]`, a site page for
    `agentica fmt`, and the development skill's note on `make fmt-check`.
- [ ] **47d: LSP "format document" (§47.8, §43).**
  - **LSP:** one request that returns the whole-file edit of `format_text`, with
    no second printer. It waits for the language server, which is not scheduled
    (§43), so it is outside the order of row 7.9.

**Done when:** `agentica fmt` rewrites a file in place, and `fmt --check` passes
in CI over `compiler/` and `stdlib/`. `agentica check` reports the width, and
CI runs it. The round-trip, idempotence and peer tests pass.
`tests/test_style_line_width.py` is gone, and what it checked is covered by
`agentica check`.

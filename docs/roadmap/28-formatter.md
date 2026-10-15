## Phase 28: Formatter

Specified in [`docs/future/47-formatter.md` section
47](../future/47-formatter.md#47-code-formatter-agentica-fmt). Phase 28 adds
`agentica fmt`, one printer for `.agc` files, and replaces the width test of
`tests/test_style_line_width.py`. Its items keep the numbers of §47.8 (47a to
47d), so the spec and this file match. It is row 7.9 of the [roadmap](README.md)
order. All four items wait for the bootstrap of the self-hosted front end
([§35](../future/35-self-hosting.md), step 8): the formatter is written in
Agentica in `compiler/`, on its lexer and parser. Each item has its own PR, with
its own tests and docs. The open questions of §47.9 need the owner's answers
before 47b starts.

- [ ] **47a: comments and the side list (§47.4).**
  - **Lexer:** `lex_with_comments` in `compiler/lexer.agc`, which returns the
    plain comments with their span, text and an own-line flag. Plain `lex` and
    `parse` keep their output and their goldens.
  - **Attachment:** the rules of §47.4 in `compiler/format_comments.agc`. Each
    comment becomes leading, trailing or dangling on one node.
  - **Tests:** the table of (node, role) for a set of inputs (§47.7).
- [ ] **47b: printer and `--check` (§47.5, §47.7).**
  - **Printer:** the document type, the fit check and the layout rules in
    `compiler/format_doc.agc` and `compiler/format_layout.agc`, with the driver
    in `compiler/format.agc`.
  - **CLI:** `agentica fmt --check` only, so CI can run it. `make fmt-check`
    runs it over `compiler/` and `stdlib/`.
  - **Tests:** the goldens of `tests/fixtures/fmt/`, the round-trip and
    idempotence tests on them, and the independent Python peer (§47.7). The
    idempotence test over the corpus runs in the slow tier.
  - **Reformat:** the one-time reformat of what the rules change. A change in
    `stdlib/` moves line numbers in the `std/` stack-trace goldens, so that PR
    runs `make goldens`.
  - **Docs:** the note on trailing commas in `docs/grammar/04-lexical.md`
    (§47.9, question 4).
- [ ] **47c: CLI and `[style]` (§47.2, §47.9).**
  - **CLI:** write mode in place, `-` for standard input, the exit codes of
    §47.2, `FMT-USAGE`, and the refusal of a file that does not parse (exit 1,
    the file untouched).
  - **Manifest:** the nearest `agentica.toml`, read with `std/toml`, and the
    default width of §47.9, question 1.
  - **Removal:** `tests/test_style_line_width.py` goes, with its generator
    check. Question 7 (§47.9) decides what `compiler/builtins_data.agc` and
    `compiler/check_tables.agc` become, and their header comments change in
    this PR.
  - **Tests:** the CLI tests of §47.7, hermetic, in temporary folders.
  - **Docs:** a `CHANGELOG.md` entry under `## [Unreleased]`, a site page for
    `agentica fmt`, and the development skill's note on `make fmt-check`.
- [ ] **47d: LSP "format document" (§47.8, §43).**
  - **LSP:** one request that returns the whole-file edit of `format_text`, with
    no second printer. It waits for the language server, which is not scheduled
    (§43).

**Done when:** `agentica fmt` rewrites a file in place, and `fmt --check` passes
in CI over `compiler/` and `stdlib/`. The round-trip, idempotence and peer tests
pass. `tests/test_style_line_width.py` is gone, and what it checked is covered
by `fmt --check`.

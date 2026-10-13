## 18. Front-end implementation language

**Decided:** on 2026-10-13 the owner chose self-hosting, for one binary and a fast start. The plan is [§35](35-self-hosting.md); the text below is the history of the question.

**Today:** the front-end (lexer, parser, linker, checker, lowering, bytecode) is written in Racket; the VM is C. The front-end stays in Racket while the language still changes: Phase 8 and the open JSON work (adapters, optional JSON fields, CBOR; sections 15–17). The reference evaluator is also Racket, until it is removed in roadmap 7i.

**Why not now:**

- Two front-ends would double the work of every language change.
- The Racket evaluator stays until 7i as the parity reference for the VM (`tests/vm-diff-*-test.rkt`); after that, golden-output tests replace it (roadmap 7i).

**The goal is distribution: one binary to download.** Measured on Linux x86_64 with Racket CS 9.3:

- `raco exe --orig-exe` on `src/main.rkt` gives one self-contained ELF file (about 68 MB, about 14 MB as `.tar.xz`). It runs in a clean `debian:trixie-slim` container without Racket. Plain `raco exe` (today's `make exe`) is only a 17 MB starter that needs an installed Racket. `raco distribute` (today's `release.yml`) is 66 MB in 3 files and ships no VM.
- The C VM is 207 KB with libgc linked statically and needs only libc. With TLS (7h) the release links the vendored OpenSSL statically (a default source build links the system OpenSSL; `docs/vm/10-dependencies-and-platforms.md` 10.0), so the released VM still needs only glibc's own libraries, and releases ship OpenSSL's `LICENSE.txt`. Built on trixie it needs `GLIBC_2.38` (`__isoc23_strtol`), so release builds need an older glibc baseline or must avoid the C23 `strtol` variants. musl (Alpine) needs a separate build.
- A proof embedded the VM bytes in the Racket executable and wrote them to `~/.cache/agentica/<hash>/agentica-vm` on the first `--vm` run: one file, +144 KB, and it worked in the clean container. A later step could use `memfd_create` (Linux) to avoid writing to disk and to work with `noexec` home directories. Loading the VM as a shared library through the FFI was judged too risky (two garbage collectors, clashes over `exit` and stdio).
- Startup is about 570–630 ms in every mode (`check`, run, `--vm`); Racket boot dominates.

**Near-term path, without a rewrite:** release one Linux file built with `raco exe --orig-exe`, with the VM embedded, on an older glibc baseline. `compile` plus `agentica-vm` already avoid Racket at run time. What is missing is that `--vm` compiles to a new temporary file on each run (`src/main.rkt`); it should reuse a cached `.agcb` keyed by the source and the compiler version. Agentica itself is `Apache-2.0 WITH LLVM-exception`. The file embeds Racket and the VM, so its archive ships Agentica's `LICENSE` and `NOTICE` next to the file, with a `licenses/` directory for the third-party licenses (Racket's and Chez Scheme's `NOTICE` among them); an `agentica --licenses` command that prints them is an option for later.

**When to look again:** a single file does not need a rewrite. The remaining reasons to change the front-end language are startup time and binary size. Look again once the grammar is stable, and only if those measurements still hurt. The roadmap takes this decision in its order step 11, with the source → result start-up (the 7g runners and the server measurement, 7j) and the typed-Python evaluation round (6c); like the multicore schedulers, a rewrite starts only if those numbers call for it.

**Options then:**

- Preferred: self-host the compiler in Agentica (dogfooding), once the VM is fast enough.
- Alternative to evaluate at that moment: Rust. Its enums and `match` fit the AST and the checker, close to Racket's `match`.
- Less suited: Go, which has no sum types.

No rewrite decision is taken now.


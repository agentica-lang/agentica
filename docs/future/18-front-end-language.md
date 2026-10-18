## 18. Front-end implementation language

**Status:** Historical decision note. On 2026-10-13 the owner chose
self-hosting in Agentica for one binary and a fast start. The port is complete
(roadmap row 7.2.7, step 8d-2; see [§35](35-self-hosting.md)). The checked-in
[`bootstrap/stage0.agcb`](../../bootstrap/stage0.agcb) starts a build that needs
no Racket ([`AGENTS.md`](../../AGENTS.md)). This file records the alternatives,
not current build guidance.

### Decision context

- While syntax was still changing, maintaining two front ends would double the
  work of every language change. Racket remained the parity reference until 7i;
  golden-output tests replaced it when the evaluator was removed.
- On Linux x86_64 with Racket CS 9.3, `raco exe --orig-exe` produced a
  self-contained executable of about 68 MB (14 MB as `.tar.xz`), but Racket's
  startup still took about 570–630 ms. These are measurements of the rejected
  interim option, not the current release.
- A proof embedded the VM bytes in the Racket executable (+144 KB) and unpacked
  them on first run. Loading the VM as a shared library through the FFI was
  rejected: two garbage collectors and clashes over `exit` and stdio made it
  too risky.
- The proposed Linux release kept glibc dynamic; Alpine/musl needed a separate
  build.

### Alternatives at the time

- **Self-hosting in Agentica:** selected; it gives the one-file distribution
  and dogfooding. See §35 for the bootstrap design.
- **Rust:** its enums and `match` fit the AST and checker, but it was not
  chosen.
- **Go:** less suited to the AST because it has no sum types.

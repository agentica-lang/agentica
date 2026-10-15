## 43. Language server (LSP)

**Status:** idea, not scheduled. The owner asked on 2026-10-15 to note an LSP
for some point. The dependencies are technical: it reuses the semantic CLI
(§39, roadmap [phase 26](../roadmap/26-semantic-cli.md)) and the doc comments
(§32), so it can only start after them, and it is easiest on the self-hosted
front end (§35). Nothing here is designed yet; this section only keeps the plan
and the open questions in one place.

### 43.1 Goal (possible scope, not decided)

Editors would show what the checker already knows, without a shell round trip:

- diagnostics, with their codes and spans;
- go to definition and find references, across modules;
- hover text, from the `##` doc comments of §32;
- the outline of a file;
- completion, later, once the rest works.

### 43.2 What it builds on

- **The semantic CLI (§39).** `outline`, `symbol`, `refs` and `type-at` will
  define the answers. The server would give the same answers, so an agent and
  an editor never see different things.
- **Doc comments (§32).** Hover text is the `##` text of a declaration.
- **The self-hosted front end (§35, `compiler/`).** The server is probably
  written on the Agentica front end, not on the Racket one, which has been
  frozen since row 7.2.7 and would be redone by the port.
- **The single binary (§35.6, step 8 of §35.4).** An editor would start one
  executable with the front end inside.

### 43.3 Open questions

- **Process and checking.** A long-lived process could keep the checked program
  and re-check only the changed modules, or re-check the whole program on each
  request. The second is simpler; the first needs incremental checking. §39.8
  has no daemon and no cache, so the LSP is where a long-lived process first
  appears. Measure the check time of the bootstrap build before choosing.
- **Protocol and language.** Is the protocol over stdio written in Agentica,
  run by the VM, or in C, inside the VM?
- **Editors.** Which editors to test with first.

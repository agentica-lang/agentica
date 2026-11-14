# Property tests (Hypothesis)

When to add a property test and how to write one. Hypothesis is a test
dependency; the profiles are in `tests/conftest.py`.

## When

Add one where the bugs hide in the input space, not in one example:

- a parser or reader of untrusted bytes (a wire format, bytecode, a
  manifest): accepted if and only if valid, and never a crash;
- lengths, sizes and counts at a cap or an overflow: 0, the cap, one past it,
  the largest value the wire or an option allows;
- round trips: encode and decode, `fmt` and parse, print and read;
- streams read in chunks, with line buffering, timeouts and cancels;
- two implementations that must agree: the interpreter and the JIT, a native
  driver and its FFI twin, Agentica and a Node or Python peer, or a model and
  what it models (a cache key's PATH search and the real spawn).

Two wins: issue #1568 (a property found that the bytecode cache's compiler key
modelled libuv's PATH search, while `resolve()` in `vm/process.c` picks the
file by other rules) and the `poll_line` property of `tests/test_process.py`
(PR #1560: against the old code it shrinks to one cancelled poll that loses a
line).

## How

- The system under test is the real `dist/agentica`. One VM serves every
  example of a run (a server, or a program that reads cases from stdin), as in
  `tests/test_prop_http.py`.
- The oracle is the component the code must agree with (the real spawn, a
  standard library peer), a small reference model only when that is too slow,
  or an invariant: a round trip, no byte lost, duplicated or reordered. The
  oracle never copies the logic under test.
- The generator covers every form the code tells apart: empty and duplicate
  entries, missing files, no exec bit, CRLF, UTF-8 cut at a chunk edge, the
  largest length.
- A property runs in both tiers with the tier's profile: the fast tier
  replays the same few examples (derandomized, no example database), the slow
  tier draws many from a seed it prints. A costly example lowers the counts
  with `settings(max_examples=500 if SLOW else 25)`. Replay a slow-tier seed
  with `PYTEST_ADDOPTS=--hypothesis-seed=N make test-slow TESTS=...`.
- A failure prints the shrunk example and a `@reproduce_failure` line; put the
  program's input and the VM's output in the assertion message so the shrunk
  case reads alone.
- The property fails on the code before the fix (`references/vm-tests.md`,
  Gotchas).

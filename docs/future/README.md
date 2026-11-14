# Agentica: planned designs

Plans live in [GitHub issues](https://github.com/agentica-lang/agentica/issues)
(labels, milestones); shipped work is in `CHANGELOG.md` and the merged PR. The
current language contract is in [`grammar.md`](../grammar.md).

These files keep the design decisions (API, semantics, rejected alternatives,
open questions) of planned features whose issue points here, and the list of
what was decided against. They hold no recipes and nothing that shipped. When a
feature lands, move its rules to `docs/grammar/`, `docs/vm/` or the site and
delete its section; section numbers are never renumbered, so gaps stay.

- `16-cbor.md`: typed `Term.encode` and `Term.decode` (#994).
- `19-simd.md`: SIMD in the VM (#996).
- `25-ruby-typed-idioms.md`: what was decided against.
- `27-iteration-and-concurrency.md`: what was decided against in tasks and
  streams.
- `28-vm-metrics.md`: VM metrics in Prometheus text (#992).
- `29-tls-context.md`: later TLS options (#993).
- `48-regex.md`: Unicode classes for regex (#990), and the decisions that bound
  it.

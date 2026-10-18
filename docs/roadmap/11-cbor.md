## Phase 11: Binary serialization (CBOR)

Specified in [`docs/future/16-cbor.md` section
16](../future/16-cbor.md#16-binary-serialization-cbor). On demand: it starts
when a real program needs it, for example a disk cache or messages between
Agentica processes. It needs `Bytes`, generic structs (10c, for the type check
on generic instances) and the JSON form of enums (10d,
`docs/future/15-adapters-and-json-inspection.md` §15.4), so both formats share
the tag and values order. The codec lands on the VM in one PR, with
`grammar.md`, the docs and tests. Docs: a
`site/content/library/text-and-data/term.md` page (front matter `title` and
`weight`, runnable examples that `tests/test_site_examples.py` checks), and a
`references/term.md` file in the programming skill plus its row in the skill's
"When to read a reference" table (the skill is not published).

Needs: `Bytes`, not repeated here. It is the Phase 8 "Later" item
([`08-data-structures.md`](08-data-structures.md)); plan it there and land it
first.

- [ ] 11a `Term.encode(value: T) -> Result[Bytes]` and
  `Term.decode(data: Bytes, type: T) -> Result[T]` on the VM (in-house C,
  explicit stack): the mapping and
  deterministic encoding of §16.4, with enums as `[tag, values]`; the Term type
  check is a new checker predicate that substitutes the instance's type
  arguments into struct fields and enum payloads before it recurses
  (`data-type?` only gives the base list of allowed and denied leaf types: it
  accepts `Json`, `Result` and type variables, and its `seen` key is
  `(kind . name)` without type arguments), cuts recursion with a `seen` set
  keyed on the substituted type (kind, name and type arguments), and also
  rejects `Json`, `Result`, `Void`, `Fn` and type variables left after
  substitution at any depth, with `CHECK-NOT-ENCODABLE` and
  `CHECK-NOT-DECODABLE`; the `decode` target is a static type argument (a named
  non-generic struct or enum); nested generic instances decode; depth counts
  Agentica nesting (an enum is one level, §16.5); past the depth, item or 64 MiB
  limit both functions return `error(...)`, never a runtime diagnostic: the
  depth error is `$: depth limit exceeded` and the item error is
  `$: too many items` (past `TERM_MAX_ITEMS`, 4,000,000 items, where every
  Agentica value is one item, the top struct included, counted the same way) in
  both directions, other errors have a `JSON.decode`-style path built only on
  error. The same PR moves `JSON.decode` map-key path escaping to the JSON
  string rule of §16.5 (user-visible error text: check site `output` blocks that
  print such paths) and adds a CHANGELOG note. `Term` becomes a reserved name
  (say so in the changelog).
- [ ] 11b Tests: round trips both ways (`encode(decode(b))` gives `b` for
  canonical bytes); RFC 8949 Appendix A vectors as fixtures; byte-identical
  encoded output and the same error results (ok or error; message text may
  differ, black-box parity) on the VM (`tests/test_vm_diff_*.py`);
  hostile input (truncation at every byte, lengths past the input, depth over
  the limit (enum nesting counted as one level), more than `TERM_MAX_ITEMS`
  values (`$: too many items`, also inside an ignored struct value), duplicate
  keys (also a duplicate struct key that the struct does not have), tags,
  indefinite lengths, non-shortest heads, invalid UTF-8, Ints outside int64,
  trailing bytes); encode errors past the depth (`$: depth limit exceeded`),
  item (`$: too many items`) and size limits; the exact item cap boundary
  (`Wrap(items: xs)` with 3,999,998 Int elements round trips, one more element
  is `$: too many items` on encode and on decode); a decode target for
  `make vm-fuzz`.

**Done when:** an example writes a struct with an `Int`-keyed map, a Float NaN
and an enum to bytes and reads it back, with the same bytes and output on both
VM, and every hostile-input case returns `error(...)` with its path.


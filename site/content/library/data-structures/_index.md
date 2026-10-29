---
title: Data structures
weight: 1
description: Lists, maps, sets, queues, ranges, bytes and lazy pipelines, and when to use each.
---

- [List](/library/data-structures/list/): values of one type, in order. Walk, sort, map, select.
- [Map](/library/data-structures/map/): find a value by key (`Int`, `String` or `Bytes`), in insertion order. Lookups and counters.
- [Set](/library/data-structures/set/): each `Int`, `String` or `Bytes` once, in first-added order. Duplicates and membership.
- [Queue](/library/data-structures/queue/) (`std/queue`): first in, first out, of strings.
- [Range](/library/data-structures/range/): `0...n` counts without a list. Use it in `for`.
- [Bytes](/library/data-structures/bytes/): a compact immutable byte string, for digests, file contents and wire formats. Slice, join, compare.
- [Lazy](/library/data-structures/lazy/): a recipe of steps over a list, a range or an endless source, run one item at a time.
- [Structs](/tour/structs/) and [enums](/tour/enums-and-case/): fixed named fields, or named cases.

All values are immutable. New to these? Read the tour pages [Lists](/tour/lists/) and [Maps](/tour/maps/) first.

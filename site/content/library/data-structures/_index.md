---
title: Data structures
weight: 1
description: Lists, maps, sets, queues and ranges, and when to use each.
---

Pick the form that matches the job.

- A [List](/library/data-structures/list/) keeps values of one type in order. Use it for a sequence you walk through, sort, map or filter.
- A [Map](/library/data-structures/map/) finds a value by key. Keys are `Int` or `String`, and the map keeps the order in which keys were added. Use it for lookups and counters.
- A [Set](/library/data-structures/set/) holds each `Int` or `String` once, in the order it was first added. Use it to remove duplicates and to ask whether a value was seen.
- A [Queue](/library/data-structures/queue/) (from `std/queue`) is first in, first out, and holds strings. Use it when the oldest value must come out first.
- A [Range](/library/data-structures/range/) such as `0...n` counts through `Int` values without building a list. Use it in a `for` loop.
- A struct groups a fixed set of named fields of different types, and an enum is one of a few named cases. Use them when the data has a shape of its own. They are in the tour pages [Structs](/tour/structs/) and [Enums and case](/tour/enums-and-case/).

All values are immutable: every function gives a new value and leaves its input as it was. See the tour pages [Lists](/tour/lists/) and [Maps](/tour/maps/) first if they are new to you.

## 38. Value representation

**Status:** item 1 of §38.6 (unboxed `List[Int]` and `List[Float]`) is built,
as step 3 of roadmap item 8d
([§17.12](../vm/17-lists.md#1712-unboxed-numeric-leaves)). The VM picks the kind
of a list from its values, so the checker's types did not have to reach it. The
rest is a note, no change planned: revisit it with the benchmarks (roadmap order
rows 9 and 14). An implementation note with no language change.

The owner asked whether `agc_value` could be smaller than 16 bytes. This note
records why it is 16 bytes, the alternatives, and the direction to take if
memory or speed ever asks for it.

### 38.1 Today

`agc_value` (`vm/value.h`, `docs/vm/05-values-execution-builtins.md` §5) is a
`uint32_t tag` plus an 8-byte union of `bool`, `int64_t`, `double` and `void *`:
12 bytes of data and 4 of padding, 16 bytes passed by value (two registers under
the SysV x86-64 ABI). `Int` and `Float` never allocate, and `Int` is 64-bit with
overflow a runtime error. The Boehm GC is conservative, and pointers are never
tagged (§5.3). It is compiled with `-DALL_INTERIOR_POINTERS` (`GC_COMPILE`,
mk/vm.mk) and reads heap objects, stack and roots only at 8-byte aligned offsets
(`GC_set_all_interior_pointers(1)`, no `GC_register_displacement`).

### 38.2 Alternatives weighed

- **Packed struct (12 or 9 bytes): rejected.** Boehm reads only aligned words, so
  in an array of 12-byte values every second payload (seven of eight with 9
  bytes) is invisible and a live object would be freed: the blocker. Also
  unaligned loads across cache lines, no atomic access, traps on some
  architectures, and a small gain (25% or 44%) with worse calls: a struct with
  unaligned fields is class MEMORY in the SysV ABI and goes on the stack.
- **NaN-boxing (8 bytes).** Floats stay inline, but a 64-bit `Int` does not fit
  in the free bits (about 48 to 51): large Ints need heap boxes (allocation in
  arithmetic) or the language must narrow `Int`. The classic layout hides
  pointers from Boehm; the pointer-favouring variant (JavaScriptCore) keeps them
  visible but still cannot hold a 64-bit Int.
- **Low-bit pointer tagging (8 bytes, Ruby and OCaml style).** Works with Boehm
  (interior pointers are recognised), but Ints become 62 or 63 bits, a language
  change, and Floats need heap boxes (Ruby's flonum keeps most inline).
- **Struct of arrays (9 bytes).** A separate array of 1-byte tags beside the
  8-byte payloads keeps alignment and GC visibility, but every container (lists,
  structs, enum payloads, captures, `Result`, Json, registers) manages two arrays
  and rebuilds an `agc_value` on every read.

### 38.6 Direction: use the static types

The checker already knows the type of every value, so most tags are redundant.
Lowering gets the types today. In order of payoff:

1. **Unboxed `List[Int]` and `List[Float]`**: 8 bytes per item and no tag, in an
   atomic object that the GC does not scan. Built as step 3 of 8d, after the
   persistent vector of steps 1 and 2, whose leaves are typed arrays now. It
   differs from this sketch in one point: the list code decides the kind from
   the values it stores, instead of the checker passing the element type
   (§17.12). It also enables the vector sort of §19 item 4.
2. **Typed registers in the JIT** (roadmap 7m,
   [§6.4](../vm/05-values-execution-builtins.md#64-jit)): Int and Float stay in
   machine registers with no tag.
3. **Compact struct fields**: a struct type knows its field types, so an Int,
   Float or Bool field can be stored in 8 bytes with no tag, and a pointer field
   as a bare, aligned pointer.

This halves memory where values are numerous, keeps `Int` at 64 bits, and keeps
pointers aligned and visible to the GC. `agc_value` stays as the general form in
registers, calls and generic code; a typed container rebuilds it from the static
type on a read.

### 38.7 Decision rule

Measure first, with the benchmarks of roadmap order rows 9 (the server
measurement, 7j) and 14 (cross-language, phase 12): wall time and peak RSS.
Change `agc_value` itself only if those numbers show that the value size, and
not lists or dispatch, is the limit, and only to a form that keeps 64-bit Ints
and aligned pointers.

## 38. Value representation

**Status:** a note, no change planned. Revisit with faster lists (roadmap 8d) and the benchmarks (roadmap order rows 9 and 14). An implementation note with no language change.

The owner asked whether `agc_value` could be smaller than 16 bytes. This note records why it is 16 bytes, the alternatives, and the direction to take if memory or speed ever asks for it.

### 38.1 Today

Checked at `8be2ffa`:

- `agc_value` (`vm/agc.h:36-39`, `docs/vm/05-values-execution-builtins.md` §5) is a `uint32_t tag` plus an 8-byte union of `bool`, `int64_t`, `double` and `void *`. That is 12 bytes of data and 4 of padding, so 16 bytes, passed by value. The VM has 20 tags (`vm/agc.h:32-34`).
- Under the SysV x86-64 ABI a 16-byte struct of two eightbytes travels in two registers, in and out of a call.
- `Int` and `Float` never allocate. `Int` is a signed 64-bit integer, and overflow is a runtime error (`docs/grammar.md`).
- Memory is managed by the Boehm GC, which is conservative: it treats any word that looks like a pointer into the heap as one. Pointers are never tagged (`docs/vm/05-values-execution-builtins.md` §5.3).
- The GC setup: `build/vm/gc.o` is compiled with `-DALL_INTERIOR_POINTERS -DNO_EXECUTE_PERMISSION` (`Makefile:182`), and `vm/value.c:53-56` only calls `GC_INIT` and sets the OOM, abort and warning hooks. So a pointer anywhere inside an object keeps it alive, from the heap as well as from the stack. bdwgc v8.2.12 sets `ALIGNMENT` to 8 on x86-64 (`include/private/gcconfig.h:2423`): the collector reads heap objects, the stack and the roots only at 8-byte aligned offsets. The VM does not change either setting (no `GC_set_all_interior_pointers`, no `GC_register_displacement`).

### 38.2 Packed struct (12 or 9 bytes): rejected

`__attribute__((packed))` with the `uint32_t` tag gives 12 bytes; with a `uint8_t` tag, 9 bytes.

- **The GC loses pointers.** Boehm reads only 8-byte aligned words. In an array of 12-byte values every second payload sits at an offset of 4 mod 8; with 9-byte values, seven of eight do. A pointer there is invisible, so a live object would be freed. This is the blocker.
- **Unaligned payloads.** x86-64 allows them, but a load that crosses a cache line costs more, and atomic access is not possible (a split lock at best).
- **Other architectures** may trap on unaligned access or emulate it slowly.
- **Small gain, worse calls.** It saves only 25% (12 bytes) or 44% (9 bytes). A struct with unaligned fields has class MEMORY in the SysV ABI, so it is passed on the stack instead of in two registers.

### 38.3 NaN-boxing (8 bytes)

LuaJIT style: a value is a `double`, and the other types live in the payload bits of a NaN.

- Floats stay inline, with no tag to check.
- A 64-bit `Int` does not fit in the free bits (about 48 to 51). Large Ints would need heap boxes, which means allocation and GC pressure in arithmetic, or the language would have to narrow `Int`'s range.
- The classic layout puts the tag in the high bits, so a stored pointer is not a valid address and Boehm cannot see it.
- The pointer-favouring variant (JavaScriptCore style: raw pointers, doubles offset by 2^48) keeps pointers visible to Boehm, but it still cannot hold a 64-bit Int.

### 38.4 Low-bit pointer tagging (8 bytes)

Ruby and OCaml style: heap objects are 8-byte aligned, so the low bits of a pointer are free for a tag.

- It works with Boehm because this build recognises interior pointers (§38.1): `p + 1` still points inside the object. Small ints with the low bit set can look like pointers and keep some garbage alive, as any conservative scan may.
- Ints become 62 or 63 bits. That is a language change: `Int` is 64-bit today, and overflow would move.
- Floats need heap boxes. Ruby's flonum trick keeps most doubles inline by rotating the exponent bits into a tagged word, but doubles outside that range are still boxed.

### 38.5 Struct of arrays (9 bytes)

A container keeps a separate array of 1-byte tags next to an array of 8-byte payloads. That is 9 bytes per value, everything stays aligned, and pointers stay visible to Boehm. The cost is complexity in every container (lists, structs, enum payloads, captures, `Result`, Json, registers): each one manages two arrays and rebuilds an `agc_value` on every read.

### 38.6 Direction: use the static types

The checker already knows the type of every value, so most tags are redundant. Lowering gets the types today (`check #:types`). In order of payoff:

1. **Unboxed `List[Int]` and `List[Float]`**: 8 bytes per item and no tag, in an atomic object that the GC does not scan. It lands together with the persistent vector of 8d, whose leaves can be typed arrays. It also enables the vector sort of §19 item 4.
2. **Typed registers in the JIT** (roadmap 7m, §22): Int and Float stay in machine registers with no tag.
3. **Compact struct fields**: a struct type knows its field types, so an Int, Float or Bool field can be stored in 8 bytes with no tag, and a pointer field as a bare, aligned pointer.

This halves memory where values are numerous, keeps `Int` at 64 bits, and keeps pointers aligned and visible to the GC. `agc_value` stays as the general form in registers, calls and generic code; a typed container rebuilds it from the static type on a read.

### 38.7 Decision rule

Measure first, with the benchmarks of roadmap order rows 9 (the server measurement, 7j) and 14 (cross-language, phase 12): wall time and peak RSS. Change `agc_value` itself only if those numbers show that the value size, and not lists or dispatch, is the limit, and only to a form that keeps 64-bit Ints and aligned pointers.

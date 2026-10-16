## 19. SIMD in the VM

**Status:** on demand. It starts only if profiling (the server measurement,
roadmap 7j, or the cross-language benchmarks, phase 12) shows time spent in the
routines below. No language change.

**Targets:** AVX2 first, then AVX-512 on x86-64; NEON on ARM later. AVX-512 can
lower the clock speed on some Intel CPUs, so a routine uses it only where it was
measured faster than AVX2.

**Candidates:**

1. Strings (`vm/strings.c`, `vm/text.c`): UTF-8 validation, code point counting
   (`length`), char index to byte offset (`at`, `slice`), search (`index_of`,
   `contains?`, `split`, `replace`), and ASCII `upcase`/`downcase`.
2. The JSON encoder (`vm/json_value.c`): scanning a string for quotes,
   backslashes and control characters before escaping.
3. Comparing and copying: call libc `memcpy`, `memcmp` and `memchr` in place of
   hand-written byte loops. glibc already picks AVX2 or AVX-512 versions at run
   time, so this needs no build change and can land at any time.
4. Sorting `List[Int]` and `List[Float]` with an AVX-512 sort (for example
   Intel's x86-simd-sort, BSD-3-Clause, which fits the dependency policy).
   Step 3 of faster lists (8d) added unboxed Int and Float storage, so these
   lists hold raw 8-byte numbers and a vector sort can work on them. Today
   `List.sort` sorts `(key, item)` entries with a scalar merge.
5. HTTP head parsing: picohttpparser (`vm/http_pico.c`, behind
   `vm/http_parse.h`, `docs/vm/10-io-http.md` 10.6) has an SSE4.2 path that the
   baseline build leaves off. Enable it with run-time dispatch like the other
   routines, only if the server measurement shows time in header parsing.

**Not useful:** instruction dispatch, the builtins that take a callback, the
HAMT (it already uses POPCNT), SipHash (kept as it is for its resistance to hash
flooding), and the GC.

**Build:**

- The default release build stays at baseline x86-64. A SIMD routine is a
  function compiled with `__attribute__((target("avx2")))` or
  `target("avx512bw")`, picked once at start-up with `__builtin_cpu_supports`
  and kept in the read-only runtime data.
- Opt-in flags for local builds skip the run-time choice:
  `make MARCH=x86-64-v3` (AVX2) or `MARCH=x86-64-v4` (AVX-512).
- Every SIMD routine keeps its scalar version. The C tests and the differential
  tests run both: a test-only switch forces the scalar path, so each path is
  checked on the same inputs (non-ASCII text, invalid UTF-8, lengths around the
  vector width).


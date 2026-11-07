# Native modules

A native module is C code written against the VM's C API
(`agentica_native.h`). An `extern module "NAME"` block declares its functions
with Agentica types; one call can take and return lists, maps and the
program's structs and enums.

~~~ruby
struct Summary
  count: Int
  mean: Float
end

extern module "stats"
  ## The count and mean of the values; none for no values.
  def summary(values: List[Float]) -> Optional[Summary]
  def empty?(text: String) -> Bool
end
~~~

- `NAME` is a library as in an `extern` block (a name, an absolute path, or
  the package's `[native.NAME]`).
- Names are the module table's, `?` and `!` allowed. Only `def` and
  `compute def` lines; `resource`, `callback`, `struct`, `out`, `...` and
  `= "symbol"` are `PARSE-EXTERN-MODULE`; a `C.` type is `PARSE-EXTERN-TYPE`.
- Types that cross: `Int`, `Float`, `Bool`, `String`, `Bytes`, `Void` (result),
  `List`, `Optional`, `Result` of them, `Map` with `Int`, `String` or `Bytes`
  keys, and non-generic structs and enums of the program whose fields cross.
  Anything else, or two crossing types of one bare name in a block, is
  `CHECK-NATIVE-TYPE`.
- The first call binds the function: the module's table must have the same
  canonical signature, mode and type shapes, else `RUNTIME-NATIVE-SIGNATURE`;
  a library that does not load is `RUNTIME-NATIVE-LOAD`. A `compute def` of a
  module is `RUNTIME-NATIVE-SIGNATURE` (this VM runs short functions only).
- `an_raise`, `an_badarg` or a bad constructor in C fail the call with
  `RUNTIME-NATIVE-ERROR` at the `def` line.
- The C side ends with `AN_MODULE_TYPES("stats", functions, types, NULL)`
  (`AN_MODULE` without types): function rows such as
  `{"summary", "(List[Float]) -> Optional[Summary]", summary, AN_SHORT}` and
  type rows such as `{"Summary", AN_STRUCT, "count: Int, mean: Float"}`. Each
  getter returns `false` for another type; terms last until the C function
  returns. A short function is thread-safe and never blocks or sleeps.

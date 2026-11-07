## 2. Reference behavior

The rules the VM follows. The goldens (§1, §12.1) pin the exit code, stdout,
program stderr and diagnostic code. Messages, spans and step counts may change
in a PR that rewrites the goldens.

### 2.1 Steps

- One step is charged when each statement starts and when each expression
  starts, before its children run.
- Not charged: `if` branches, `case` arms, patterns, map entries, named
  arguments, string parts of an interpolation, function entry, binding the `for`
  variable, and work inside builtins.
- A resolved method or field node (`s.to_s` on a String, `xs.size`) charges only
  its resolved node.
- A `while` condition is charged on every evaluation, including the last false
  one. A `for` over a list charges nothing per iteration. A `for` over a range
  charges one step per iteration at the `for` span, before the body, so a huge
  range always reaches `--max-steps`.
- `Range.each`, `Int.times`, `Int.upto` and `Int.downto` charge one step at the
  call span before each callback. Callbacks of the `List` builtins charge only
  their bodies.
- Without `--max-steps` nothing is counted. With limit N the first N entries run
  and entry N+1 fails with `RUNTIME-STEP-LIMIT` at its span. All tasks share one
  counter. Limits above `INT64_MAX` are clamped.

### 2.2 Numbers

- Int arithmetic is checked against int64: overflow is
  `RUNTIME-INTEGER-OVERFLOW` at the operator span. `INT64_MIN / -1` overflows;
  `INT64_MIN % -1` is `0`.
- Int or Float division and modulo by zero fail at the operator span. For Float,
  a `0.0` or `-0.0` divisor fails; a NaN divisor does not.
- Float `+ - *` never fail: overflow gives infinities, and `inf - inf` or `inf *
  0.0` give NaN. Unary minus flips the sign bit, so NaN stays NaN.
- Ordering with NaN on either side is false for `< <= > >=`.
- Float literals are `digits.digits` only. The lexer converts them and the
  bytecode carries the IEEE bits, so the VM never parses literal text.
- `==` on numbers uses `=`: NaN differs from itself and `0.0 == -0.0`. A `case`
  literal uses `equal?`, so pattern `0.0` does not match `-0.0`.
- `-9223372036854775808` is legal: the literal 2^63 under unary minus is
  accepted (3.3).
- `Float.to_int` truncates and fails on NaN, infinity or a value outside Int.
- The `Int` bit builtins work on the 64-bit two's complement form. `shift_left`
  wraps, `shift_right` is arithmetic, `shift_right_unsigned` is logical, and a
  count of 64 or more shifts every bit out (`shift_right` gives 0 or -1). A
  negative count is `RUNTIME-INVALID-COUNT` at the count. `Float.to_bits` and
  `Float.to_bits32` give the IEEE 754 bits with the canonical NaN
  (`0x7FF8000000000000`, `0x7FC00000`); `Float.from_bits32` outside `0 ..
  4294967295` is `RUNTIME-INVALID-NUMBER`.
- `String.to_int` accepts `^[+-]?[0-9]+$` (ASCII digits only) and fails with an
  error value past 64 bits. `String.to_float` accepts
  `^[+-]?[0-9]+(\.[0-9]+)?$`. Text without a dot is an integer that is rounded
  (`-0` gives `0.0`, `-0.0` gives `-0.0`); a huge one gives infinity. Conversion
  uses `strtod` in the "C" locale.
- Float text (`vm/value.c`, checked by `vm/tests/float_text_test.c`): take the
  shortest round-trip digits `d1...dn` and decimal exponent `e`. Use exponent
  form when `e < -4`, or when `e >= 0` and both `pos > 16` and `pos > sci`. Here
  `pos` is the positional length (`n + 1` with a fraction, else `e + 3` for
  `ddd.0`) and `sci` is `n + (n > 1 ? 1 : 0) + 2 + digits(e)`. Exponents print
  as `e+14` and `e-5`; one digit has no point (`1e+21`). Otherwise print
  positionally with at least one fractional digit (`100.0`, `0.0001`). Specials:
  `+nan.0` (any NaN), `+inf.0`, `-inf.0`, `-0.0`, `0.0`. Exact ties round up in
  magnitude, and at a power of two the neighbour above can win, so the shortest
  string is not always the nearest one.

### 2.3 Strings and text

- Strings are sequences of Unicode scalar values: `length`, `at`, `slice`,
  `index_of`, `reverse` and `split(s, "")` count code points.
- `String.trim` removes exactly space, `\t`, `\n`, `\f` and `\r`; NBSP, `\v` and
  U+3000 stay.
- `split(s, sep)` with a non-empty `sep` splits at every non-overlapping match
  and keeps empty parts, so joining with `sep` gives `s`: `",,a,,"` gives `["",
  "", "a", "", ""]`. `split("", "")` gives `[]`; `split("", sep)` gives `[""]`.
- `replace` replaces every non-overlapping match; an empty `from` inserts at
  every position (`"abc"` gives `"xaxbxcx"`).
- `upcase` and `downcase` are full Unicode mappings (`"straße"` gives
  `"STRASSE"`). Final sigma `Σ` becomes `ς` only after a cased letter and not
  before one (`ΑΣ` gives `ας`). The tables are frozen in `vm/unicode_data.c`;
  its header says how a future generator must match them.
- Debug form of a String: the escapes `\"`, `\\`, `\a \b \t \n \v \f \r \e`;
  other characters that are not printed raw become `\uXXXX` or `\UXXXXXXXX`
  (uppercase hex). A joiner (U+200C, U+200D, U+E0020 to U+E007F) prints raw only
  after a raw, non-blank character, so family emoji and flags print raw.
- Stdin is decoded per byte: each byte that does not start a complete valid
  UTF-8 sequence becomes one U+FFFD (`E2 82 63` gives two U+FFFD, then `c`).
  `IO.gets` ends lines at LF, CR or CRLF. A read decodes only the bytes it
  consumes.
- `System.args` on Linux and macOS is UTF-8 with one `?` per invalid byte, as
  glibc `iconv` gives. Other locales and Windows code pages are outside the
  contract.
- `System.env(name)` is the value of the first `name=value` entry. An empty
  name, a name with `=` or NUL, and an unset name give an error Result; a set
  empty value gives `ok("")`. Values decode per byte. The VM's own entries
  (`AGENTICA_CHANNEL`, and `UV_USE_IO_URING` when the VM set it) are hidden. No
  flag is needed.
- `System.pid()` is the VM's `getpid()`, with no flag. `--driver-pid` checks its
  argument against the VM's parent, so a program that starts a VM passes
  `System.pid()`.
- `String.code` needs exactly one code point and `String.from_code` a Unicode
  scalar value, else `RUNTIME-INVALID-CHARACTER` at the argument span (the
  receiver for `s.code`). `at` fails with `RUNTIME-INDEX-OUT-OF-RANGE` at the
  index span, `slice` at the call span.
- `to_int!` fails with `RUNTIME-INVALID-NUMBER` or `RUNTIME-INTEGER-OVERFLOW`,
  `to_float!` with `RUNTIME-INVALID-NUMBER`, both at the call span. The `Result`
  forms return the same text as an `error(...)` value.
- `String.from_bytes` decodes a `Bytes` strictly: no surrogates, no overlong
  forms, no code points above U+10FFFF. It costs by size.
- `Bytes.decode` and `String.encode` (`vm/text_codec.c`) cover UTF-8, UTF-16,
  UTF-32, ASCII, Latin-1, ISO-8859-15 and Windows-1252 (the last two from small
  frozen tables of the bytes where they differ from Latin-1). A decode checks
  the input and sizes the String in one pass and fills it in a second. An error
  is an `error(...)` value that ends with the offset Python reports as the start
  of its Unicode error: a byte offset for a decode, a character index for an
  encode. They cost by size.
- The `Digest`, `HMAC`, `Base64`/hex, `Cipher` and `CMAC` builtins take and give
  `Bytes` (catalog key `<name>.bytes`), use OpenSSL's EVP API
  (`vm/digest_openssl.c`, behind `digest.h`) and charge `AGC_COST_SIZE`
  (§10.2.1). Those that read only their arguments run without the shared lock.
  `OpenSSL.HMAC.secure_compare` compares in constant time. The key, IV and input
  sizes are checked first and give an error `Result`; a library failure is
  `RUNTIME-INTERNAL` at the call. A two-key `des_ede3` key is expanded to K1 K2
  K1 and the copy is wiped. An `aes_256_gcm` encrypt writes the tag after the
  ciphertext; a decrypt wipes the plaintext when the tag is wrong.
- `OpenSSL.KDF.pbkdf2_hmac_sha256` and `OpenSSL.KDF.scrypt` check their
  parameters first, their work included (`PBKDF2_MAX_WORK`, `SCRYPT_MAX_WORK` in
  `vm/crypto.c`: a started call cannot be stopped, and it holds a compute pool
  thread), then park the task on a compute job (`agc_io_compute`; refused with
  `RUNTIME-NATIVE-CALLBACK` inside a callback of native code). `PBKDF2` runs
  with `pkcs5` set, so no SP 800-132 floors. Password and key copies are wiped.
  The jobs run without the shared lock.
- `OpenSSL.RSA.public_encrypt_oaep` reads the first PEM block of at most 64 KiB
  with `OSSL_DECODER` (public key structures only, no passphrase callback),
  takes only an `RSA` key of 43 to 2048 bytes (OpenSSL's 16384-bit cap) with an
  odd modulus and an odd exponent from 3 to 64 bits (OpenSSL takes any exponent
  below a modulus of 3072 bits or less, which costs a private-key operation),
  and data of at most its size less 42, and encrypts with OAEP SHA-1 into a
  stack buffer. A refused input or key is an error `Result`; a failure of the
  encryption after those checks (memory, the seed draw) is `RUNTIME-INTERNAL`.
  It runs without the shared lock.
- `OpenSSL.Random.random_bytes(n)` and `hex(n)` check `0 <= n <= 1048576` (else
  `RUNTIME-INVALID-COUNT` at the argument) and draw with `RAND_bytes`; `uuid`
  draws 16 bytes and sets the version and variant bits. A failed draw is
  `RUNTIME-INTERNAL`. They run without the shared lock: OpenSSL 3 keeps one
  generator per thread.

### 2.4 Printing values

- Text form: a String as is, a `Json` as its JSON text, anything else in debug
  form. A list stays in debug form (`puts(["a"])` prints `["a"]`).
- Debug form: `nil`, `true`, Int, Float (2.2), String (2.3), `[a, b]`, `{k: v}`
  in insertion order, `Name(f: v, ...)` in declaration order, `Enum.Variant` or
  `Enum.Variant(a, b)`, `ok(v)`, `ok()` for Void, `error("msg")`, and the handle
  forms `<Json>`, `<Fn>`, `<Task>`, `<Socket>`, `<Listener>`, `<HttpClient>`,
  `<FileHandle>`, `<Process>`.
- Struct and enum names print as declared: an imported `Point` prints `Point(x:
  1)`, not the linker's `@2::` identity. A field-less struct prints `Name()`; a
  nullary variant prints `Enum.Variant`, even when written `Enum.Variant()`. The
  VM never looks a type up by its display name.
- JSON text sorts object keys, uses short escapes (`\n`) and lowercase `\u007f`
  for DEL, keeps non-ASCII raw, prints floats per 2.2 and big integers in
  decimal. `JSON.encode` of a non-Json value keeps struct declaration order and
  map insertion order; only a `Json` inside is sorted. `JSON.from`,
  `JSON.object` and `JSON.array` build a `Json`, so their text is sorted. A
  non-finite Float in either is `RUNTIME-JSON-ENCODE` at the call span.

### 2.5 Diagnostics, streams and exit codes

- A runtime diagnostic carries a code, a message, a span and, when there is one,
  the call stack of the failing task (6.1). Only the code is contract. The
  `--ai` and `--json` shapes are pinned by `tests/test_vm_stack.py` and the
  `stack-trace-*` goldens in `tests/fixtures/vm/step-limited/`.
- `--json` keys, in order: `code`, `file`, `message`, `range`, `spawned_at`,
  `stack`, `stack_omitted`, `task` (the last four only when they apply). Each
  stack object has `column`, `file`, `function`, `line`, `repeat` and `tail`.
- A frame is `name at file:line:column`, with ` (N times)` for a merged run and
  ` (after a tail call)`. A cut stack shows `... N frames not shown ...` after
  the 15th line, counting frames, and a task ends with `task spawned at
  file:line:column`. Names drop the linker's `@N::` prefix; a block is `block`.
  A line break in a name or file is written `\n` or `\r`. A name or path over
  256 bytes is cut at a character boundary with `...`; the diagnostic's first
  line is never cut.
- The stack shows for every `RUNTIME-` diagnostic raised while a task runs (the
  step limit, the stack overflow, a task's crash line) when that task has more
  than one frame or is not `main`. It is not shown for `System.exit`, the
  out-of-memory exit (6.3), the stall check (`RUNTIME-INTERNAL`, raised between
  turns) or a failed flush at the end of the run.
- Columns count characters. Source lines split on LF, with a trailing CR
  removed. Source names and lines print as raw bytes.
- Order: flush stdout, write the diagnostic to stderr, exit 1. How the two
  streams interleave at buffer boundaries is not contract.
- Before each blocking stdin read, stdout is flushed when it is a terminal.
- SIGPIPE is ignored. Every `fwrite` and `fflush` result is checked; a failed
  write ends the run with `RUNTIME-INTERNAL`, exit 1.
- `RUNTIME-INTERNAL` is at the program span; its message is not contract.
- Normal end exits 0. `System.exit(n)` exits with `n` for `1 <= n <= 255`, else
  0.

### 2.6 JSON parsing

- A raw character below U+0020 in a string is an error; DEL passes. Any other
  syntax error, including a lone `\u` surrogate, is an error. A surrogate pair
  decodes to one character.
- Empty input is an error, and so is anything after the value other than space,
  tab, CR or LF, or a number that is not finite. Checks run in this order:
  control characters over the whole text, syntax, trailing content, finite
  check, so `1e400 x` fails as trailing content. All parse errors have the
  `JSON.parse: ` prefix.
- A number ends at the first byte its grammar does not take: `01` is `0`
  followed by trailing content, and `[01]` is invalid. A literal followed by
  `[A-Za-z0-9_]` (`truex`) is invalid; `true-` is trailing content.
- A number with a fraction or an exponent is a Float (`1e2` is `100.0`); others
  are integers of any size.
- A Float is the exact decimal rounded to nearest, ties to even. A mantissa of
  only zeros gives `0.0` (so `-0e5` is `0.0`); a non-zero negative value that
  rounds to zero is `-0.0`. `-0` is the integer 0.
- A repeated key keeps the last value. Objects sort by key bytes, stably.
- The VM reads the tree with the yyjson reader (10) and copies it into `Json`
  nodes. Numbers reach the VM as text.

### 2.7 Typed JSON

The user-facing rules (which fields are required, the `JsonField` and
`Optional` forms, the enum object, the schema shape) are in
`site/content/library/text-and-data/json.md`. The VM side:

- `JSON.decode(s, T)` parses `s` like `JSON.parse`, then walks `T` in field
  order and stops at the first problem. A `Json` source skips the parse. A
  decoded map is built in sorted key order.
- A `JsonField[T]` field (type kind 7) is `Absent` when its key is missing and
  `Null` for JSON `null`; the encoders leave out the key of an `Absent` struct
  field, write `null` for `Null` and the payload for `Value`. They know the
  variants by the ids of the `JsonField` enum, which the loader finds and checks
  (Absent, Null, Value with arities 0, 0, 1).
- An `Optional[T]` (type kind 8) may be any type of the table, not only a field.
  The encoders write `none` as `null` and `some(x)` as `x`, at any depth and for
  the root, so `some(none)` is `null`. The loader finds the builtin `Optional`
  enum by its name and shape (None, Some with arities 0, 1); an enum named
  `Optional` of another shape, from an older file, is an ordinary enum.
- An enum (type kind 9) is the object `{"tag": name, "values": [...]}`; the
  encoders write both keys, `tag` first, for any enum value that is not an
  `Optional` or a `JsonField`. `JSON.decode` checks, in this order, each an
  error at the object's path: the value is an `object`; `tag` is there (`tag:
  expected required field`), a `String` and the name of a variant (`tag:
  expected one of A, B`); `values` is there for a variant with payloads, an
  `array`, and has `array of N items`. A payload error has the path
  `<object>.values[i]` and then its own path. A variant with no payload may
  leave `values` out, and it is then the shared value.
- Errors are values `"<path>: expected <what>"`. The path is `$`, `a.b` for
  fields, `a[3]` for list items and `a["k"]` for map keys. `<what>` is `object`,
  `array`, `required field`, `signed 64-bit Int` (a JSON float, or an integer
  outside int64), `finite Float` (a big integer that rounds to infinity fails),
  `Bool` or `String`, with ` or null` after it where a `JsonField` or
  `Optional` applies.
- `JSON.schema(T)` writes each struct and enum reached once in `$defs` under its
  linked name (`@2::Point` for an imported one), referenced by `{"$ref":
  "#/$defs/<name>"}` with `~` written `~0` and `/` written `~1`. Int is
  `{"type": "integer", "minimum": -2^63, "maximum": 2^63-1}`.
- The VM walks the JSON tree and the type table with an explicit stack and
  builds the error path only on failure. Schema uses a queue. Neither recurses,
  so recursive structs and deep values are safe.

### 2.8 Files and paths

Every failure is an error value. The checks run in this order:

- Arguments: text above 1 MiB; `File.write_bytes` at most 1 MiB per call;
  `File.read_bytes` `max_bytes` 1 to 1 MiB; a positive timeout.
- The mode, then the handle: a closed handle, or one not readable or writable,
  fails. `File.close` of a closed handle does no I/O.
- A path is a nonempty String without NUL. A relative path is completed with the
  working directory, read once at startup; runs of `/` collapse.
- Output is buffered, 4096 bytes per handle. A write that fits (pending + n <=
  4096) goes into the buffer; otherwise pending and new bytes are written
  together. `File.flush`, `File.close` and the end of the run write the buffer.
  A write error shows at the call that writes it. A timeout that closes a handle
  drops its buffer.
- Kinds follow `stat` (symlinks followed): `directory` or `file`. A FIFO, pipe
  or device that can wait is read on the loop (10.2.2). Writes refuse a
  directory and create a missing file.
- `File.read_text` refuses a file over 1 MiB by its size and decodes strictly.
  `File.read_line` strips LF or CRLF and fails after 1 MiB without a LF.
  `File.read_bytes` reads to `max_bytes` or EOF.
- `File.sha256` streams a whole regular file in 64 KiB chunks (no 1 MiB cap);
  the `fstat` of the open descriptor decides regular, anything else is
  `filesystem: path does not refer to a regular file`. A cancel or a timeout
  detaches the job like the other whole-file calls.
- `File.chunks` reads a regular file in `Bytes` chunks of at most `size`
  bytes. A zlib step of a Lazy run (`vm/lazy.c`) holds one zlib stream owned by
  the task that runs the terminal, freed when the run or the task ends. A
  decoder's output buffer is one byte past what `max_bytes` still allows, so an
  overflow is found without handing on a byte past the cap. The errors are
  `zlib: invalid compressed data`, `zlib: truncated stream`, `zlib: trailing
  bytes after stream end` (a second member or any trailing byte) and `zlib:
  checksum mismatch`. The `Zlib` and `__lazy_*` builtins use `Bytes`.
- `File.stat` of a missing path is an error without a kind. A directory's size
  is 0. `modified_seconds` is the mtime; `mode` is `st_mode & 07777`.
- `File.lstat` is `lstat`: a link has `kind` `"link"`, `size_bytes` as its text
  length, and its own mode, owner and mtime. Other paths give what `File.stat`
  gives.
- `File.open` mode `create_private` is `open` with `O_WRONLY | O_CREAT | O_EXCL
  | O_NOFOLLOW` and mode 0600 (less where the umask clears bits). Any existing
  entry, a dangling link included, is an error.
- `File.try_lock(handle, timeout_ms)` is `flock(LOCK_EX | LOCK_NB)` in a pool
  job. `ok(true)` means the lock is taken (again on the same handle, too);
  `ok(false)` means another open file description holds it. The lock lasts
  until the handle closes or the process ends. A non-regular file is
  `filesystem: only a regular file can be locked` (`fstat` decides). There is no
  unlock call and no waiting lock.
- `Dir.mkdir_private` is one `mkdir` with mode 0700 (less where the umask clears
  bits). It makes no parents; an existing path is an error (`filesystem:
  cannot make directory`).
- `Path.remove(path, timeout_ms)` never follows a link and runs in a pool job.
  It calls `unlink` first: a file or symbolic link goes, and `ENOENT` is `ok()`.
  Other `unlink` errors are reported (`ENOTDIR` for `file/child` included, so
  `link/` never reports `ok()`). Only `EISDIR` starts the tree walk
  (`agc_remove_tree`, `vm/tree.c`): `openat(O_NOFOLLOW | O_DIRECTORY)` on the
  root and `unlinkat` on each directory's descriptor, so a link in the tree goes
  as a link and its target is never touched. At most 128 open levels. A
  directory is reread while its last pass removed something, since POSIX leaves
  entries after an unlinked one unspecified; a pass that removed nothing ends
  with `ENOTEMPTY`. The walk crosses mount points, as `rm -rf` does. A path
  whose last component is empty, `.` or `..` is refused before anything opens
  (`agc_tree_refused`); Windows refuses an unsafe path. A failure names the
  entry that failed, not the root. After a timeout the job runs to its end
  (14.3).
- `Path.rename(from, to, timeout_ms)` is one `renameat2(AT_FDCWD, from,
  AT_FDCWD, to, RENAME_NOREPLACE)` in a pool job. It never replaces: an existing
  `to`, an empty directory included, is `EEXIST`. The call is atomic, so of
  several processes racing for one name exactly one wins. A final link moves as
  a link. The error is `filesystem: cannot rename path`. Without
  `RENAME_NOREPLACE` the call answers `EINVAL`, which is reported; there is no
  check-first fallback, since that would race.
- `File.replace(path, data, timeout_ms)` is one pool job (at most 16 MiB). The
  target is found with `uv_fs_realpath` and must be a regular file, so a link
  stays a link. The data goes to `.agc-PID-N.tmp` in the target's folder
  (exclusive, no link followed, mode 0600 while written), then `fchmod` to the
  target's mode, `fsync`, and a rename over the target (`MoveFileExW` on
  Windows, which refuses a read-only target before anything is written); the
  folder is then flushed on POSIX. A reader sees the old file or the new one,
  never neither. A failure removes the new file; a killed process can leave it
  behind. It works by path, like `Path.rename`: a folder of the path swapped
  between the `realpath` and the rename by someone with write access to its
  parent is not defended. After a timeout the job runs to its end (14.3).
- `Dir.list` drops `.` and `..`, decodes names with U+FFFD and sorts them by
  code point. `Dir.mkdir` creates missing parents with mode 0777; an existing
  directory or file is not an error.
- `Path.join` checks every part and refuses an absolute later part.
  `Path.resolve` drops `.`, pops `..` (never above `/`) and collapses `/`; the
  result ends in `/` when the input did, or ended in `.` or `..`.
- `Path.real` is `uv_fs_realpath` in a pool job with no deadline. The path must
  exist; a link loop, too many links or a non-directory in the middle fail
  (`filesystem: cannot resolve path`). An empty or NUL path gives
  `filesystem: invalid path`. A relative path starts at the working directory,
  and the result decodes per byte. macOS fails an absolute form of 1024 bytes
  or more; on Windows `.` and `..` are dropped before a link is followed and an
  absolute form of 260 characters or more fails unless `LongPathsEnabled` is 1.
- After a timeout on an active handle operation the handle is closed: later
  operations fail with "file handle is closed", and `File.close` gives `ok()`.
- A timed-out read on a FIFO or device ends at the timeout (10.2.2);
  `File.read_text` of a pipe reads to end of file.
- `File.each_line` accepts a line of at most `buffer_bytes` bytes counting its
  terminator, and a last unterminated line of exactly `buffer_bytes`. It checks
  the buffer range first (`RUNTIME-INVALID-COUNT`), then the timeout, then the
  path.

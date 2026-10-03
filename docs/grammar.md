# Agentica: grammar and language design

Status: implemented by the interpreter in Racket (`src/`). This document describes only what the interpreter accepts; planned syntax lives in [`future.md`](future.md).

## 1. What we want to validate

Agentica is a language designed so AI agents can write, read, and fix programs easily. The priority is to experiment with the syntax, the rules, and the diagnostics. Performance, concurrency, and the final runtime come later.

The direction is KISS: Ruby-like syntax, static types, local inference, and few ways to express each operation. This specification does not depend on the language the interpreter is written in.

## 2. Design decisions

| Aspect | Rule |
|---|---|
| Syntax | `def`, `struct`, `if`, `while`, `for`, `end`; blocks end with `end` |
| Types | Static, with local inference where it is evident |
| Calls | Parentheses are required |
| Signatures | Explicit return type and required annotations |
| Data | Variables can be reassigned; lists, maps, and structs are immutable |
| Numbers | 64-bit `Int`, no implicit conversions |
| Names | Function names may end in `?` (predicate) or `!` (halting form), independently of whitespace before `(` |
| Library | Builtin modules `Map`, `List`, `String`, `IO`, `System`, `Result`, `JSON`, `BDD`, `Task`, `File`, `Dir`, `Path`, `TCP`, `TLS`, and `HTTP` |

Enums, `Option`, interpolation, and other extensions are not part of the current language; they are in [`future.md`](future.md).

## 3. A core program

```ruby
struct User
  name: String
  age: Int
end

def is_adult(user: User) -> Bool
  return user.age >= 18
end

def main() -> Nil
  users = [
    User(name: "Ana", age: 25),
    User(name: "Luis", age: 16)
  ]

  for user in users
    if is_adult(user)
      puts(user.name)
    end
  end
end
```

Blocks end with `end`. Indentation helps reading but does not determine structure. Calls use parentheses, even when they take no arguments. Structs are built with named fields; ordinary functions take positional arguments.

The executable starts by calling `main()`. The core has no executable statements at the top level, only declarations. This avoids having two different entry models.

## 4. Lexical conventions

- The file is UTF-8; core identifiers use ASCII characters.
- A comment starts with `#` and ends at the end of the line.
- Names of variables, functions, and fields start with a lowercase letter or `_`.
- Type names start with an uppercase letter.
- Identifiers are case-sensitive.
- Reserved words cannot be used as identifiers.
- Spaces and tabs separate tokens; they have no structural meaning.
- A newline separates statements, except inside `(...)`, `[...]`, and `{...}`.
- CRLF is normalized to LF. A comment does not remove the newline that follows it.
- The lexer emits one `NL` token for each LF or CRLF outside delimiters, including blank and comment lines. The parser ignores extra `NL` tokens between declarations and statements.
- If the file does not end with a newline, the lexer adds one before `EOF`.
- `;`, backslash continuation, and expressions that continue implicitly after an operator are not supported.

So a long expression must be wrapped in parentheses. Inside lists and calls you can use several lines and a trailing comma.

```ruby
total = (
  base +
  extra
)

names = [
  "Ana",
  "Luis",
]
```

Reserved words of the core:

```text
def struct end if elsif else while for in return try
true false nil and or not
```

Future extensions will introduce more reserved words; they are not available.

A trailing `?` or `!` is part of a lowercase `NAME`, regardless of the next parenthesis or whitespace: `contains? (s, part)` is valid. `!` is not a suffix when followed by `=`, so `a!=b` still means `a != b`. By convention, `?` marks a predicate that returns `Bool`, and `!` marks the version that halts the run with an error instead of returning a `Result`. Variables, fields, and parameters cannot have the suffix.

The type and module names `Int`, `Float`, `Bool`, `String`, `Nil`, `List`, `Map`, `Result`, `IO`, and `System` are reserved and cannot be redefined. `ok` and `error` remain NAME tokens, but cannot be declared as user functions, variables, parameters, loop variables, or fields (`CHECK-REDEFINED-NAME`).

### Literals

```ebnf
NAME       = LOWER_OR_UNDERSCORE, { LETTER | DIGIT | "_" }, [ "?" | "!" ] ;
TYPE_NAME  = UPPER, { LETTER | DIGIT | "_" } ;
INTEGER    = DIGIT, { DIGIT } ;
FLOAT      = DIGIT, { DIGIT }, ".", DIGIT, { DIGIT } ;
STRING     = '"', { STRING_CHAR | ESCAPE }, '"' ;
ESCAPE     = "\\", ( '"' | "\\" | "n" | "r" | "t" ) ;
```

`LETTER` is `A`–`Z` or `a`–`z`; `DIGIT`, `0`–`9`; `LOWER_OR_UNDERSCORE`, `a`–`z` or `_`; `UPPER`, `A`–`Z`. `STRING_CHAR` is any Unicode character except double quotes, backslash, and newlines. `NL` and `EOF` are tokens produced by the lexer.

The minus sign is an operator, not part of the literal. The core has no exponents, alternative bases, numeric separators, multiline strings, or interpolation. `"#{name}"` is literal text in this version.

## 5. Core EBNF grammar

This is a descriptive grammar: it will be translated to the notation of the chosen tool. `{ X }` means zero or more repetitions, `[ X ]` means optional, and `|` expresses alternatives. Terminals appear in quotes; uppercase names are lexical tokens.

### File and declarations

```ebnf
program          = [ NL ], { declaration }, EOF ;
declaration      = function_decl | struct_decl ;

function_decl    = "def", NAME, "(", [ parameters ], ")",
                   "->", type, NL, block, "end", NL ;
parameters       = parameter, { ",", parameter }, [ "," ] ;
parameter        = NAME, ":", type ;

struct_decl      = "struct", TYPE_NAME, NL,
                   { field_decl }, "end", NL ;
field_decl       = NAME, ":", type, NL ;

type             = TYPE_NAME, [ "[", type, { ",", type }, "]" ] ;
```

The parser allows type applications such as `List[Int]`. The checker restricts the core to primitive types, structs, `List[T]`, `Map[K, V]`, and `Result[T]`: a form being syntactically valid does not mean the type exists. There are no user-declared type parameters in the core.

Struct and function declarations appear only at the top level. There are no methods, classes, inheritance, closures, or nested functions.

### Statements and blocks

```ebnf
block            = { statement } ;
statement        = simple_statement, NL
                 | if_statement
                 | while_statement
                 | for_statement ;

simple_statement = binding | return_statement | expression ;
binding          = NAME, [ ":", type ], "=", expression ;
return_statement = "return", [ expression ] ;

if_statement     = "if", expression, NL, block,
                   { "elsif", expression, NL, block },
                   [ "else", NL, block ], "end", NL ;
while_statement  = "while", expression, NL, block, "end", NL ;
for_statement    = "for", NAME, "in", expression, NL,
                   block, "end", NL ;
```

Assignments are statements: they do not produce a value. `if`, `while`, and `for` are not expressions either. The core has no `break`, `continue`, compound assignments, or assignment to fields or indexes.

### Expressions and precedence

```ebnf
expression       = or_expr ;
or_expr          = and_expr, { "or", and_expr } ;
and_expr         = equality_expr, { "and", equality_expr } ;
equality_expr    = comparison_expr,
                   [ ( "==" | "!=" ), comparison_expr ] ;
comparison_expr  = additive_expr,
                   [ ( "<" | "<=" | ">" | ">=" ), additive_expr ] ;
additive_expr    = multiplicative_expr,
                   { ( "+" | "-" ), multiplicative_expr } ;
multiplicative_expr = unary_expr,
                   { ( "*" | "/" | "%" ), unary_expr } ;
unary_expr       = ( "-" | "not" | "try" ), unary_expr | postfix_expr ;
postfix_expr     = primary, { ".", NAME
                            | ".", "call", "(", [ arguments ], ")"
                            | "[", expression, "]" } ;

primary          = literal
                 | "&", NAME
                 | NAME, [ "(", [ arguments ], ")" ]
                 | TYPE_NAME, ".", NAME, "(", [ arguments ], ")"
                 | TYPE_NAME, "(", [ named_arguments ], ")"
                 | list_literal
                 | map_literal
                 | "(", expression, ")" ;

arguments        = expression, { ",", expression }, [ "," ] ;
named_arguments  = named_argument, { ",", named_argument }, [ "," ] ;
named_argument   = NAME, ":", expression ;
list_literal     = "[", [ arguments ], "]" ;
map_literal      = "{", [ map_entry, { ",", map_entry }, [ "," ] ], "}" ;
map_entry        = expression, ":", expression ;
literal          = INTEGER | FLOAT | STRING | "true" | "false" | "nil" ;
```

Calls are to named functions or function values via `.call(...)`; arbitrary user methods are not supported. `&name` references a declared top-level function without capturing variables. `call` is not a reserved word. `user.name`, `users[0]`, and `find_user(1).name` also fit the grammar.

`TYPE_NAME, ".", NAME, "(" … ")"` is a call to a function of a builtin module (`Map.put(...)`); the core has no user modules.

`and` and `or` short-circuit. Additions, subtractions, multiplications, divisions, and modulos group from left to right. Comparisons and equality checks do not chain: `a < b < c` is invalid; write `a < b and b < c`.

| Precedence, high to low | Operations |
|---|---|
| 1 | Named call, field `.`, index `[]`, grouping |
| 2 | Unary `-`, `not`, `try` |
| 3 | `*`, `/`, `%` |
| 4 | `+`, `-` |
| 5 | `<`, `<=`, `>`, `>=` |
| 6 | `==`, `!=` |
| 7 | `and` |
| 8 | `or` |

`not` has high precedence: to negate a comparison, write `not (age >= 18)`.

## 6. Minimal semantic rules

The grammar determines what can be written. The following rules determine which programs are valid and how they run. They are the rules the interpreter implements.

### Types and inference

| Type | Rule |
|---|---|
| `Int` | Signed 64-bit integer; overflow is a runtime error |
| `Float` | IEEE 754 binary64 |
| `Bool` | Only `true` and `false`; there is no truthiness |
| `String` | Unicode text; concatenation with `+` |
| `Nil` | A single value, `nil`; also marks a return without a result |
| `List[T]` | Homogeneous, immutable list; `Int` indexes, from zero |
| `Map[K, V]` | Homogeneous, immutable dictionary; the key `K` is `Int` or `String`; keeps insertion order |
| `Result[T]` | Exactly one payload type; successful `ok(value)` or String-valued `error(message)` |
| `Json` | Opaque JSON value, accessed through the `JSON` module |
| `Fn[A, ..., R]` | Named function value; final type is its return, preceding types are parameters; no closures |
| `Task[R]` | Opaque lightweight task with exactly one result type |
| Network handles | Opaque `Socket`, `Listener`, `HttpClient`, `HttpServer`, `HttpBody`, `HttpWriter` |
| Builtin records | `Header`, `Request`, `Response`, `HttpClientOptions`, `HttpServerOptions` |
| Declared struct | Nominal type, typed and immutable fields |

Parameters and the return type of functions require an annotation. Local variables can be inferred from the initializer:

```ruby
count = 3
names: List[String] = []
```

An empty list needs an expected type, which can come from an annotation, a parameter, a field, or the return type of a function. A non-empty list must have elements of the same type. There is no implicit numeric conversion and no dynamic `Any` type.

`Nil` is not a nullable wildcard: `name: String = nil` is invalid. Optional values will arrive with `Option[T]`.

### Operators

- `+`, `-`, `*`, and `/` accept two operands of the same numeric type. Also, `+` concatenates two `String` values.
- Integer division truncates toward zero. `%` accepts only integers and is defined by `a = (a / b) * b + (a % b)`.
- Dividing by zero is a runtime error, also for `Float`. Integer operations that do not fit in `Int` produce an error.
- The ordering operators accept only two numbers of the same type.
- `==` and `!=` accept values of the same primitive type. The core has no list or struct equality.
- `and`, `or`, and `not` accept only `Bool`.
- There is no user-defined operator overloading.

Expressions, arguments, and constructor fields are evaluated from left to right. A float comparison follows IEEE 754; in particular, a NaN is not equal to itself.

### Variables and scope

The first assignment introduces a variable in the current scope. A later assignment changes its value without changing its type. An annotation can appear only when the variable is introduced.

Each function and each control block introduces a lexical scope. A visible variable cannot be shadowed by another with the same name. An assignment without an annotation updates the visible variable if it already exists; otherwise it introduces a local in the current block.

Parameters and the `for` variable are already-initialized bindings. The `for` variable is local to the body and cannot be reassigned. Variables created in a block are not visible after its `end`.

```ruby
count = 0
while count < 3
  puts("hello")
  count = count + 1
end
```

### Functions and entry point

- Functions can be called before their declaration and can be recursive.
- There is no overloading, default values, or named arguments in ordinary functions.
- A function with a return type other than `Nil` must return on every reachable path. In the initial checker, a loop does not by itself guarantee a return.
- The last expression does not return implicitly.
- `return` without a value is the same as `return nil`.
- Reaching the end of a `-> Nil` function returns `nil`.
- An executable must declare exactly one `main() -> Nil` function with no parameters.

### Structs and lists

All fields of a constructor are required and given exactly once. The order of named fields is free. There are no default fields and no extra fields.

```ruby
user = User(age: 25, name: "Ana")
```

List indexes must be between zero and length minus one; a negative or out-of-range index is an error. Indexing costs O(n) in this interpreter; prefer `for` for traversal rather than repeated indexed access. `for` iterates over `List[T]` in order. Slices and string indexing are not supported in the core.

### Maps

`Map[K, V]` associates keys with values. The key `K` can only be `Int` or `String`; `V` can be any type. `Map` takes exactly two type arguments.

```ruby
stock: Map[String, Int] = {"apple": 3, "pear": 0}
apples = stock["apple"]
more = Map.put(stock, "kiwi", 7)
```

- A literal uses braces and `key: value`; it allows several lines and a trailing comma. An empty `{}` needs an expected type, like `[]`; without it the diagnostic is `CHECK-EMPTY-MAP-TYPE` (`CHECK-EMPTY-LIST-TYPE` is only for `[]`).
- `m[key]` returns the value. The key must have type `K`. A missing key is a runtime error.
- If a literal repeats a key, the last value wins; the key keeps its first-insertion position. Replacing a key with `Map.put` also preserves its position.
- Maps are immutable, like lists: there is no `m[key] = value`. `Map.put` returns a new map and leaves the original intact.
- There is no map equality and no `for` over a map; iterate with `Map.keys`, which returns the keys in insertion order.
- This interpreter uses Racket immutable hashes: lookup, `Map.has_key?`, and `Map.put` are effectively constant-time in map size (technically O(log n), excluding key hashing/comparison). `Map.size` is O(1); `Map.keys` is O(n). Updates share unchanged storage rather than copying the whole map.

### Minimal builtin functions

```text
puts(value: String) -> Nil
```

`puts` writes the text and a newline. The name is reserved and cannot be redefined.

To work with maps and lists there are two builtin modules, `Map` and `List`, called as `Module.function(...)`. Their functions are generic, so the checker treats them specially. The names `Map` and `List` are reserved and cannot be redefined.

```text
Map.has_key?(map: Map[K, V], key: K) -> Bool
Map.keys(map: Map[K, V]) -> List[K]
Map.size(map: Map[K, V]) -> Int
Map.put(map: Map[K, V], key: K, value: V) -> Map[K, V]
Map.get(map: Map[K, V], key: K) -> Result[V]
Map.get(map: Map[K, V], key: K, default: V) -> V
Map.delete(map: Map[K, V], key: K) -> Map[K, V]
Map.values(map: Map[K, V]) -> List[V]
List.size(list: List[T]) -> Int
List.append(list: List[T], value: T) -> List[T]
List.set(list: List[T], index: Int, value: T) -> List[T]
List.repeat(value: T, count: Int) -> List[T]
List.reverse(list: List[T]) -> List[T]
```

Collection operations preserve their inputs. `List.append`, `List.set`, and `List.reverse` cost O(n); repeated appends can cost O(n²). `List.repeat` costs O(count), accepts 0..1048576, and returns an empty typed list for zero. Invalid counts halt with `RUNTIME-INVALID-COUNT` at the count argument. `List.set` uses zero-based indexes and halts with `RUNTIME-INDEX-OUT-OF-RANGE` at the index argument if it is negative or outside the list.

`Map.get` with two arguments returns `ok(value)` for a present key and `error(message)` for an absent key. With three arguments it returns the present value or the default; the default is always evaluated, even when the key exists. False and nil are present values. `Map.delete` ignores absent keys, preserves the order of remaining keys, and costs O(n) to maintain that order. A deleted key reinserted with `Map.put` goes to the end. `Map.values` follows `Map.keys` order and costs O(n). Expected types flow into these operations for contextual empty collections and Results; without enough context the existing empty-collection diagnostics apply.

The `String` module works on text. `String.length` and `String.slice` count Unicode characters, not bytes; a `slice` out of range is a runtime error. `String.split(s, "")` returns a list with one Unicode character per element. The conversions `String.to_int!` and `String.to_float!` accept decimal numbers with an optional sign; `to_int!` fails with `RUNTIME-INVALID-NUMBER` if the text is not a decimal integer and with `RUNTIME-INTEGER-OVERFLOW` if it is outside the range of `Int`, while `to_float!` rejects text that is not a real decimal with `RUNTIME-INVALID-NUMBER`.

```text
String.length(s: String) -> Int
String.upcase(s: String) -> String
String.downcase(s: String) -> String
String.trim(s: String) -> String
String.split(s: String, separator: String) -> List[String]
String.join(parts: List[String], separator: String) -> String
String.contains?(s: String, part: String) -> Bool
String.starts_with?(s: String, prefix: String) -> Bool
String.ends_with?(s: String, suffix: String) -> Bool
String.replace(s: String, from: String, to: String) -> String
String.slice(s: String, start: Int, length: Int) -> String
String.from_int(n: Int) -> String
String.from_float(x: Float) -> String
String.from_bytes(data: List[Int]) -> Result[String]
String.to_int(s: String) -> Result[Int]
String.to_float(s: String) -> Result[Float]
String.to_int!(s: String) -> Int
String.to_float!(s: String) -> Float
```

The `IO` module writes and reads through the standard ports; `IO.warn` writes to standard error. `IO.inspect` prints any value in a stable debug form and returns it. `IO.gets` returns `ok(line)` without its terminator (LF, CR, or CRLF), or an error value at EOF. A blank line is `ok("")`, not EOF. `IO.gets!` returns the line directly and halts with `RUNTIME-END-OF-INPUT` at EOF; `IO.eof?` lets you check first. The `System` module exposes the program arguments and ends the run with a code.

```text
IO.puts(value: String) -> Nil
IO.print(value: String) -> Nil
IO.warn(value: String) -> Nil
IO.inspect(value: T) -> T
IO.gets() -> Result[String]
IO.gets!() -> String
IO.read() -> String
IO.read_bytes(count: Int) -> Result[List[Int]]
IO.flush() -> Nil
IO.eof?() -> Bool
System.args() -> List[String]
System.exit(code: Int) -> Nil
```

- `IO.read()` drains text until EOF; do not use it to read one message from a peer that keeps stdin open. `IO.gets()` reads a line instead. Both use Racket's buffered input port.
- `IO.read_bytes(count)` waits for exactly `count` bytes or EOF and returns a list of integers in `0 .. 255`, with no UTF-8 decoding. A short final read succeeds; EOF before any bytes is `ok([])`. Zero returns `ok([])` without consuming input, even before EOF. Counts must be `0 .. 1048576` (1 MiB per call), bounding eager allocation; invalid counts return an error without consuming input. Input-port failures also return an error. Larger streams can be processed in multiple reads.
- `String.from_bytes(data)` checks every integer is `0 .. 255`, then decodes UTF-8 strictly. Empty bytes produce `ok("")`; invalid, overlong, surrogate, or incomplete sequences return an error, never replacement characters. Byte reads may split a multibyte character; decode only when its complete bytes are available. Existing text and byte readers share one port; text readers should only be used at a complete character boundary.
- `IO.eof?()` peeks at the next byte without consuming it. It can block while awaiting data or EOF, but never waits to decode a whole UTF-8 character. It is not a readiness poll. Reads have no timeout, and the step budget cannot interrupt blocking I/O.
- `IO.flush()` flushes stdout and returns nil; it does not close the stream or flush stderr. Output functions do not automatically flush. For interactive stdio protocols, write one compact JSON message per line and flush after each response; logs go to stderr with `IO.warn`.

### Result and propagation

```text
ok(value: T) -> Result[T]
error(message: String) -> Result[T]
Result.ok?(r: Result[T]) -> Bool
Result.unwrap!(r: Result[T]) -> T
Result.unwrap_or(r: Result[T], default: T) -> T
Result.message(r: Result[T]) -> String
```

- `Result[T]` is builtin, not a user enum. It can nest and contain any valid payload type. Results have no equality, fields, or indexing.
- `ok(1)` infers `Result[Int]`. An expected `Result[T]` checks the payload against `T`, including empty lists/maps.
- `error("bad")` needs an expected Result type from an annotation, existing binding, parameter, field, return, or typed container element. Otherwise it is `CHECK-RESULT-TYPE`; no success type is guessed.
- `Result.unwrap!` passes its expected output type `T` to the operand as `Result[T]`. On an error it halts with `RUNTIME-UNWRAP-ERROR`, the stored message, and the unwrap call span.
- `Result.unwrap_or` uses the expected output type, or infers it from the default. Both arguments run eagerly, left to right, even for a success.
- `Result.ok?` and `Result.message` need an argument whose Result type is known. A success's message is `""`. `ok(false)` and `ok(nil)` are successes.
- Container inference still uses the first element: `[ok(1), error("bad")]` infers, but the reverse order needs an annotation.
- Non-bang String conversions use the same signed-decimal syntax and integer bounds as bang forms, but invalid text/overflow return errors rather than halting. Unrelated runtime failures are not converted to Results.
- `IO.inspect` prints recursive `ok(...)` / `error(...)` forms and returns its argument. Error values do not print diagnostics or change the run's exit code.
- `try` has unary precedence: it evaluates one `Result[T]` operand once and produces `T` on success, or returns its error from the current function. Only a function returning `Result[...]` may use it (`CHECK-TRY-CONTEXT` otherwise). Operand and enclosing success types may differ. An expected expression type `T` supplies `Result[T]` to the operand; the enclosing return type alone does not infer it. A success still needs an explicit return from the function.

```ruby
def read_age(text: String) -> Result[Int]
  age = try String.to_int(text)
  return ok(age)
end
```

### JSON

`Json` and `JSON` are reserved builtin names. A `Json` is opaque: it has no constructor, equality, fields, or direct indexing. `IO.inspect` prints `<Json>` without exposing its contents. Use the JSON functions to read it or `JSON.encode` to print JSON text.

```text
JSON.parse(s: String) -> Result[Json]
JSON.encode(value: T) -> String
JSON.get(j: Json, key: String) -> Result[Json]
JSON.at(j: Json, index: Int) -> Result[Json]
JSON.string(j: Json) -> Result[String]
JSON.int(j: Json) -> Result[Int]
JSON.float(j: Json) -> Result[Float]
JSON.bool(j: Json) -> Result[Bool]
JSON.list(j: Json) -> Result[List[Json]]
```

- `JSON.parse` reads exactly one JSON value, with optional surrounding JSON whitespace (space, tab, CR, LF). Empty input, malformed JSON, trailing content, invalid Unicode escapes, raw control characters in strings, or non-finite parsed numbers return an error. A repeated object key keeps the last value.
- `JSON.get` requires an object and a present key; `JSON.at` requires an array and an index in `0 .. length - 1`. Missing keys, bad indexes, and wrong kinds return errors, not runtime diagnostics. JSON `false` and `null` are valid present values.
- String and Bool extraction require the exact JSON kind. `JSON.int` requires an integer within signed 64-bit bounds; a decimal or exponent form is not an Int, even if mathematically integral. `JSON.float` accepts an integer or decimal/exponent number and converts it to finite binary64, with normal rounding; conversion overflow returns an error. Parsed integers may exceed Int bounds until extracted.
- `JSON.list` returns an array's elements as opaque Json values in order; heterogeneous arrays are valid. JSON null stays inside Json, distinct from a Bool or Nil extraction (there is no null extractor yet).
- `JSON.encode` accepts Int, Float, Bool, String, Nil (as `null`), Json, lists, String-keyed maps, and structs whose nested types are also encodable. Results and Int-keyed maps, including empty or nested ones, are `CHECK-NOT-ENCODABLE` errors. Untyped empty containers still need an annotation.
- Encoding produces compact JSON, preserving struct declaration order and map insertion order. Parsed Json object order is unspecified. Non-finite Floats halt with `RUNTIME-JSON-ENCODE` at the encode call; they are never silently replaced by null. Racket's bundled `json` library supplies parsing and scalar escaping.
- Typed struct decoding, JSON builders, and schemas are later phases. See `examples/json.agc` for encoding, extraction, and `try`.

### Function values and BDD

`Fn` and `BDD` are reserved builtin names. `f: Fn[Int, Int] = &double` refers to a declared function with exactly those parameter and return types; `f.call(21)` invokes it. References can travel through lists, maps, parameters, returns, and fields. A bare function name remains invalid as a value. Functions have no equality, field access, indexing, or JSON encoding; `IO.inspect` prints `<Fn>`.

`BDD.run(feature_path: String, step_files: List[String]) -> Result[Json]` executes `.feature` specifications using local processes. Verification failures return a report with `ok: false`; infrastructure failures return an error Result. `agentica test [PATH...] [--steps FILE]` enforces the verdict as its exit code. Every scenario runs independently; failure stops its remaining steps and execution continues with the next scenario. Step handlers register with `BDD.step(pattern: String, handler: Fn[List[String], Nil]) -> Nil`. See [`bdd.md`](bdd.md) for the supported Gherkin syntax, step catalog, contextual builtins, reports, and process lifetime.

### Lightweight tasks

`Task` is reserved. Tasks use Racket coroutine threads for I/O concurrency, without closures, new keywords or CPU parallelism.

```text
Task.spawn(f: Fn[A, R], arg: A) -> Task[R]
Task.await(task: Task[R]) -> R
Task.sleep(milliseconds: Int) -> Nil
```

Spawn starts a named function immediately with one argument; use a struct for multiple values. Each task has independent scopes, call depth and return handling. Await returns the cached result and may be repeated. False, nil and Result.error are normal results. Handles belong to one execution; awaiting one in another halts with RUNTIME-TASK-CONTEXT. Tasks have no constructor, equality, fields, indexing or JSON encoding; inspect shows `<Task>`.

Any task diagnostic terminates the whole evaluation with its original code and span, even when unawaited. System.exit in any task terminates the evaluation with its code. The first terminal outcome published by the supervisor wins. Returning from the entrypoint cancels pending tasks: explicitly await work that must finish. External interruption also cancels tasks and closes resources created under the execution custodian, preserving caller-supplied ports.

Sleep takes nonnegative milliseconds; zero yields. Negative durations halt with RUNTIME-INVALID-DURATION at the argument. Tasks inherit ports, arguments and contextual builtin services. Shared streams have no cross-task ordering guarantee; coordinate who reads input. All tasks, including nested tasks, share the execution's synchronized --max-steps counter.

BDD registration and step handlers support tasks but must finish them before returning, normally through Task.await. Pending work fails that handler with RUNTIME-BDD-PENDING-TASKS. Child failures stop the current handler while later scenarios continue. BDD registration, state and assertions are synchronized; stdin and stdout have independent locks whose wait counts against the operation timeout.

### TCP, TLS and HTTP/1.1

Networking uses the existing expression syntax and lightweight Racket tasks.
`TCP`, `TLS`, `HTTP`, `Socket`, `Listener`, `HttpClient`, `HttpServer`,
`HttpBody`, `HttpWriter`, `Header`, `Request`, `Response`,
`HttpClientOptions` and `HttpServerOptions` are reserved. Handles are opaque:
no constructor, equality, fields or JSON encoding; inspect prints their type
in angle brackets. Handles belong to their evaluation and close when it ends.
Network access needs no CLI permission flag.

```text
TCP.connect(host: String, port: Int, timeout_ms: Int) -> Result[Socket]
TCP.listen(host: String, port: Int) -> Result[Listener]
TCP.accept(listener: Listener, timeout_ms: Int) -> Result[Socket]
TCP.send(socket: Socket, text: String, timeout_ms: Int) -> Result[Nil]
TCP.send_bytes(socket: Socket, bytes: List[Int], timeout_ms: Int) -> Result[Nil]
TCP.recv_bytes(socket: Socket, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
TCP.read_line(socket: Socket, timeout_ms: Int) -> Result[String]
TCP.close(socket: Socket) -> Nil
TCP.close_listener(listener: Listener) -> Nil
TCP.local_port(listener: Listener) -> Int
TLS.connect(host: String, port: Int, ca_file: String, timeout_ms: Int) -> Result[Socket]
TLS.listen(host: String, port: Int, cert_file: String, key_file: String) -> Result[Listener]
```

Listen on port zero for an assigned port. TLS listeners and sockets use the
same TCP operations. TLS verifies certificates and hostnames with TLS 1.2 or
later; an empty CA path uses system trust, a nonempty path selects a PEM CA.
The server takes a PEM certificate chain and private key.

Timeouts are positive milliseconds and cover the whole operation, including
lock waits. Read and write directions have independent locks; coordinate
which task reads a stream and the order of writes. Timing out an active I/O
operation closes that socket. Waiting for a lock alone does not close it.
Failures return Results; explicit close is idempotent.

Send encodes UTF-8 and flushes. Byte values must be 0..255, at most 1 MiB per
send_bytes call. recv_bytes accepts 1..1048576, returns available data up to
that count, and returns ok([]) at EOF. TCP supplies a stream, not messages.
read_line handles fragmented UTF-8, strips LF or CRLF, accepts a final line
without a terminator, and errors on empty EOF or a line over 1 MiB.

Builtin records are immutable and use the existing named-field constructors:

| Record | Fields |
| --- | --- |
| Header | name: String, value: String |
| Request | method: String, target: String, path: String, headers: List[Header], body: HttpBody |
| Response | status: Int, headers: List[Header], body: HttpBody |
| HttpClientOptions | timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int, ca_file: String |
| HttpServerOptions | header_timeout_ms: Int, idle_timeout_ms: Int, max_connections: Int, max_body_bytes: Int |

Request.target preserves the origin-form target including the query; path is
the part before `?`, with no percent decoding. Incoming header names are
lowercase. Lists preserve duplicates and order, including Set-Cookie.
Header values use the HTTP Latin-1 byte range; names must be HTTP tokens.
CR/LF injection, control characters and user-supplied framing headers are
rejected. Host is supplied by the client; Content-Length and Transfer-Encoding
are supplied by framing operations.

```text
HTTP.client_options() -> HttpClientOptions
HTTP.server_options() -> HttpServerOptions
HTTP.client() -> Result[HttpClient]
HTTP.client(options: HttpClientOptions) -> Result[HttpClient]
HTTP.close_client(client: HttpClient) -> Nil
HTTP.get(client: HttpClient, url: String) -> Result[Response]
HTTP.post(client: HttpClient, url: String, headers: List[Header], body: String) -> Result[Response]
HTTP.request(client: HttpClient, method: String, url: String, headers: List[Header], body: String) -> Result[Response]
HTTP.request_stream(client: HttpClient, method: String, url: String, headers: List[Header], length: Int, producer: Fn[A, HttpWriter, Result[Nil]], argument: A) -> Result[Response]
HTTP.read(body: HttpBody, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
HTTP.text(body: HttpBody, timeout_ms: Int) -> Result[String]
HTTP.trailers(body: HttpBody) -> Result[List[Header]]
HTTP.close_body(body: HttpBody) -> Nil
HTTP.header_values(headers: List[Header], name: String) -> List[String]
```

Options helpers return defaults: 30 s operation/header timeout, 30 s idle
timeout, 4 connections per client origin or 128 server connections, 64 MiB per
body, and system CA trust. Construct options records to customize them; numeric
options must be positive, and max_connections is capped at 65536.
Request acquisition, DNS, connection, TLS and response headers share one
client timeout. HTTP.wait deliberately waits until explicit close.

The pool groups connections by scheme, hostname and port. Each connection has
one active exchange. Reuse requires complete upload and complete response
consumption, including chunk terminators and trailers. Connection: close,
EOF-framed bodies, invalid framing, or abandoned bodies prevent reuse.
Closing a client closes its pool and active exchanges. A pending pool wait
may time out without affecting another exchange.

get/post/request return as soon as response headers are available. HTTP 4xx
and 5xx are normal Response values. request_stream runs a supervised producer
concurrently with response reception; length -1 uses chunked, otherwise it is
the exact byte length. Pass producer data through argument; no closures are
needed. The producer can finish with trailers; otherwise successful return
finishes automatically. An error Result aborts the exchange and appears on
the request or a subsequent body read. Producer diagnostics terminate the
evaluation with their original location.

read accepts 1..1048576 bytes and returns progress, not an entire requested
buffer. ok([]) means body EOF. text collects up to 1 MiB within one total
deadline and decodes UTF-8 strictly. Decode arbitrary streamed chunks only
after assembling complete characters. trailers requires completed consumption;
close_body abandons an unread body. Header lookup is case-insensitive.
Content encoding remains raw: there is no automatic gzip decompression.

```text
HTTP.listen(host: String, port: Int, handler: Fn[Request, HttpWriter, Nil], options: HttpServerOptions) -> Result[HttpServer]
HTTP.listen_tls(host: String, port: Int, cert_file: String, key_file: String, handler: Fn[Request, HttpWriter, Nil], options: HttpServerOptions) -> Result[HttpServer]
HTTP.local_port(server: HttpServer) -> Int
HTTP.wait(server: HttpServer) -> Result[Nil]
HTTP.close_server(server: HttpServer) -> Nil
HTTP.begin(writer: HttpWriter, status: Int, headers: List[Header], length: Int, timeout_ms: Int) -> Result[Nil]
HTTP.write(writer: HttpWriter, text: String, timeout_ms: Int) -> Result[Nil]
HTTP.write_bytes(writer: HttpWriter, bytes: List[Int], timeout_ms: Int) -> Result[Nil]
HTTP.finish(writer: HttpWriter, trailers: List[Header], timeout_ms: Int) -> Result[Nil]
HTTP.respond(writer: HttpWriter, status: Int, headers: List[Header], text: String, timeout_ms: Int) -> Result[Nil]
```

Connections run concurrently with independent evaluator contexts and one
shared step budget. Each connection processes requests sequentially. begin
starts a response with status 200..599; length -1 selects chunked. write and
write_bytes flush each part, at most 1 MiB per call. Fixed lengths must match
exactly. finish emits the final chunk/trailers or validates a fixed length.
respond combines begin/write/finish for a UTF-8 string.

HEAD suppresses response bytes; 204 and 304 have no response body. The server
supports 100 Continue and rejects unsupported expectations. It finishes a
valid response on handler return; a handler that never begins a response
gets 500 and connection close. Unconsumed request bodies close the connection.
Writers become inactive on handler/producer return. Coordinate ownership:
immutable records do not make socket operations atomic across tasks.

close_server stops acceptance, cancels handlers and nested tasks, closes all
connections and wakes wait. It is idempotent. Main return and global failure
also close services. An awaited task cancelled by resource shutdown reports
RUNTIME-TASK-CANCELLED; intentional shutdown itself is not a global failure.
BDD handlers must close services and finish tasks before returning.

HTTP/1.1 supports fixed lengths, chunked transfer, trailers and informational
responses. Ambiguous framing is rejected. Header limits are 64 KiB, 100
entries and 8 KiB per line. Body limits apply incrementally. Protocol errors
before dispatch affect only their connection; body read failures return Results.
A handler's explicit unwrap failure remains a global diagnostic.
HTTP/1.0, upgrades, proxies, automatic redirects/retries, cookie management and
a dedicated SSE API are outside this phase.

### Files and paths

`File`, `Dir`, `Path`, `FileHandle` and `FileInfo` are reserved. File handles
are opaque, belong to one evaluation, and close when it ends. The interpreter
uses the host user's filesystem permissions; there is no filesystem permission
flag. File operations accept regular files and symlinks to regular files, and
reject directories and special files.

```text
File.open(path: String, mode: String, timeout_ms: Int) -> Result[FileHandle]
File.read_bytes(handle: FileHandle, max_bytes: Int, timeout_ms: Int) -> Result[List[Int]]
File.read_line(handle: FileHandle, timeout_ms: Int) -> Result[String]
File.write(handle: FileHandle, text: String, timeout_ms: Int) -> Result[Nil]
File.write_bytes(handle: FileHandle, bytes: List[Int], timeout_ms: Int) -> Result[Nil]
File.flush(handle: FileHandle, timeout_ms: Int) -> Result[Nil]
File.close(handle: FileHandle, timeout_ms: Int) -> Result[Nil]
File.read_text(path: String, timeout_ms: Int) -> Result[String]
File.write_text(path: String, text: String, timeout_ms: Int) -> Result[Nil]
File.append_text(path: String, text: String, timeout_ms: Int) -> Result[Nil]
File.stat(path: String, timeout_ms: Int) -> Result[FileInfo]
Dir.list(path: String, timeout_ms: Int) -> Result[List[String]]
Dir.mkdir(path: String, timeout_ms: Int) -> Result[Nil]
Path.cwd() -> Result[String]
Path.join(parts: List[String]) -> Result[String]
Path.resolve(path: String) -> Result[String]
```

`File.open` modes are `read`, `write` and `append`. Read requires an existing
regular file; write creates or truncates; append creates or appends. Text is
strict UTF-8. Whole-text helpers and each stream read/write are limited to
1 MiB; `read_bytes` takes 1..1048576 bytes and returns `ok([])` at EOF.
`read_line` removes LF or CRLF, accepts a final unterminated line, and returns
an error for EOF before any line or invalid UTF-8. Byte values are 0..255.
`File.close` flushes output and is idempotent. Explicit flush and close return
Results so I/O failures remain recoverable.

Timeouts are positive milliseconds and include the serialized handle lock wait.
Timing out active I/O closes that handle; timing out while waiting for its lock
leaves it open. Errors are Results. `File.stat` follows symlinks and reports
`FileInfo(kind: String, size_bytes: Int, modified_seconds: Int)`; directory
sizes are zero. `Dir.list` returns immediate entry names sorted by name.
`Dir.mkdir` creates parents and succeeds when the directory already exists.
`Path.join` follows the host's path rules. `Path.resolve` makes a lexical
absolute path and does not resolve symlinks.

### Builtin discovery and execution budget

`Map.get` and `HTTP.client` select signatures by arity. Their text help lists all variants; JSON help contains `name`, `description`, `effects`, and `overloads`, whose entries describe each signature. Other builtin help keeps the single-signature JSON format.

`agentica help NAME --json` prints name, arity, parameter types, result, signature, effects, and description from the same catalog used by checking and execution. Effects describe I/O only; they are not permission enforcement. Unknown help targets exit 2. Options may also precede `help`.

`agentica --max-steps N program.agc` limits execution to N expression/statement entries, including repeated loop conditions across all tasks. N must be a positive integer (bad CLI values exit 2). Runs are unlimited by default; checking never executes or spends the budget. Exhaustion is `RUNTIME-STEP-LIMIT` at the next node to execute. The synchronized counter resets per evaluation. This is not a wall-clock or blocking-I/O timeout.

## 7. Diagnostics for agents

Each error includes a stable code, file, line, column, a concrete explanation, and the source line with a mark under the span. Spans travel from the tokens to the AST.

```text
example.agc:2:14 error[CHECK-TYPE-MISMATCH]
expected Int, found String

2 |   age: Int = "25"
  |              ^^^^
```

When the checker knows a certain fix, the diagnostic ends with a `= help:` line, and secondary spans are marked with `-` and a short note:

```text
example.agc:5:7 error[CHECK-UNKNOWN-NAME]
unknown function "totl"

5 |   x = totl(1)
  |       ^^^^^^^
  = help: did you mean "total"?
```

`agentica --ai` and `agentica --json` print the same diagnostic as compact text or as one JSON object.

The code carries the prefix of the stage that failed: `LEX-`, `PARSE-`, `CHECK-` (before running), or `RUNTIME-` (while running). Each stage stops at the first error. The minimal cases to tell apart are: invalid syntax, unknown name, incompatible type, wrong arity, unknown or missing field, missing return, and runtime error.

Diagnostics refer to Agentica and never expose host exceptions or tracebacks.

## 8. Examples to review the design

### Function and control flow

```ruby
def classify(age: Int) -> String
  if age >= 18
    return "adult"
  elsif age >= 13
    return "teen"
  else
    return "child"
  end
end

def main() -> Nil
  puts(classify(25))
end
```

### Lists and field access

```ruby
struct Todo
  title: String
  done: Bool
end

def main() -> Nil
  tasks: List[Todo] = [
    Todo(title: "Probar Agentica", done: false),
    Todo(title: "Revisar gramática", done: true)
  ]

  for task in tasks
    if not task.done
      puts(task.title)
    end
  end
end
```

### Maps

```ruby
def main() -> Nil
  stock: Map[String, Int] = {"apple": 3, "pear": 0}
  stock = Map.put(stock, "kiwi", 7)
  for name in Map.keys(stock)
    if stock[name] > 0
      puts(name)
    end
  end
end
```

### Programs that must be rejected

```ruby
age: Int = "25"        # Incompatible types.
if 1                   # The condition must be Bool.
  puts("hello")
end
values = []            # Missing expected type for the empty list.
puts "hello"           # The call requires parentheses.
```

These statements are shown as function body fragments. At the top level they would also be invalid because they are not declarations.

## 9. Guide for whoever implements the prototype

Implement the rules of sections 4–6 first. Keep the grammar, the AST, the checker, the evaluator, and the builtin functions independent. Do not generate host code without preserving the rules of Agentica: for example, `if 1` must be rejected even if the host accepts truthiness.

If a rule turns out to be too costly, change this specification and the examples explicitly before creating a silent exception. The goal is that any agent can consult a short document and predict the behavior of a program.

The first evaluation of the language should measure correct programs, attempts needed, and how useful the errors are. Run time can be measured later; the first question is whether the syntax and the rules help agents produce and repair code.

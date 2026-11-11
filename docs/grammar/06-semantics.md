## 6. Minimal semantic rules

The grammar determines what can be written. The rules below determine which
programs are valid and how they run.

### Types and inference

- `Int`: Signed 64-bit integer; overflow is a runtime error
- `Float`: IEEE 754 binary64
- `Bool`: Only `true` and `false`; there is no truthiness
- `String`: Unicode text; concatenation with `+`, repetition with `* Int`
- `Bytes`: Immutable byte string, one byte for each item (`0..255`); no literal
  (§6, "Bytes")
- `Nil`: A single data value, `nil`
- `Void`: Completion without a usable value; no literal
- `List[T]`: Homogeneous, immutable list; `Int` indexes from zero
- `Map[K, V]`: Homogeneous, immutable map; the key `K` is `Int`, `String` or
  `Bytes`; keeps insertion order
- `Set[T]`: Immutable set of distinct `Int`, `String` or `Bytes` values; keeps
  first-insertion order
- `Result[T]`: `ok(value)`, or `error(message)` with a `String` message
- `Optional[T]`: `some(value)`, or `none` for a value that is missing
- `Json`: Opaque JSON value, used through the `JSON` module
- `Range`: Immutable `Int` range: `a..b` includes `b`, `a...b` excludes it
- `Fn[A, ..., R]`: Function value; the last type is its return, the others are
  its parameters
- `Task[R]`: Opaque lightweight task with one result type
- `TaskRef`: Opaque running task from `Task.current`, with no result type: it
  can be monitored, cancelled and identified, not awaited
- `Await[T]`: Builtin enum of a timed `Task.await`: `Await.Done(value)` or
  `Await.TimedOut`; matched with `case` like a user enum
- `LogLevel`: Builtin enum of `std/logger`: `LogLevel.Debug`, `LogLevel.Info`,
  `LogLevel.Warning` and `LogLevel.Error`, in that order; matched with `case`
  like a user enum
- `LogEvent`: Builtin record of `std/logger` that a log handler receives:
  `level: LogLevel`, `message: String`, `fields: Map[String, String]`, `time_ms:
  Int` and `task: Int`; it is not JSON-decodable
- `StructMember`: Builtin record of `Type.members`: `name: String` and `type:
  String`, the field name and its type written as source
- `TaskExit`: Builtin enum of how a task ended: `TaskExit.Ok`,
  `TaskExit.Crashed` and `TaskExit.Cancelled`
- `TaskDown`: Builtin record that `Task.monitor` sends when a task ends:
  `task_id: Int`, `reason: TaskExit`, and the diagnostic of a crash, `code:
  String`, `message: String`, `file: String`, `line: Int` and `column: Int`; it
  is not JSON-decodable
- `Channel[T]`: Opaque bounded queue of `T` values that tasks send into and
  receive from
- `Enum[T, ...]`: User-declared nominal sum type
- Declared struct: Nominal type with typed, immutable fields

Parameters and function return types need annotations. Local variables may be
inferred from the initializer, as in `count = 3`. An empty list, map or
`Set.new([])` needs an expected type, from an annotation, a parameter, a field
or a return type: `names: List[String] = []`. A non-empty list has one element
type. There is no implicit numeric conversion and no `Any` type. `Nil` is not a
nullable wildcard: `name: String = nil` is invalid; use `Optional[T]`.

### Operators

- `+`, `-`, `*` and `/` take two operands of one numeric type; `+` also
  concatenates `String`s, `Bytes` and two lists of one type (a new list), and
  `s * n` repeats a `String` `n`
  (an `Int`) times; a negative `n`, or a result over 256 MiB, is
  `RUNTIME-INVALID-COUNT`. Integer `/` truncates toward zero, and `%`
  takes integers only, with `a = (a / b) * b + (a % b)`. Division by zero is
  `RUNTIME-DIVISION-BY-ZERO`, for `Float` too. An integer result outside `Int`
  is an error.
- Ordering operators take two numbers of one type. `==` and `!=` take two
  values of one type that has equality: a primitive type, `Range` (equal when
  start, end and kind match), `Bytes` (the same length and bytes), and `List`,
  `Map`, `Set`, `Optional`, `Result`, structs and enums whose parts have
  equality. Lists are equal when they have the same length and equal items in
  order; maps when they have the same keys with equal values, and sets the same
  elements, in any order; Optionals, Results and enums when they have the same
  variant and equal payloads (`error` compares the message, and `ok() == ok()`
  for `Result[Void]`); structs when they have the same type and equal fields.
  A struct or enum that holds itself (`children: List[Node]`) has equality when
  no type of its group lacks it. Functions, tasks, channels, handles and
  `Json` have no equality, nor does any type that holds one, nor a type
  variable of a generic function: `CHECK-TYPE-MISMATCH`, whose message names
  the field or variant without equality. A `Float` follows IEEE 754 at any
  depth, so a list or struct that holds a NaN is not equal to itself. A list,
  map, set, `Optional`, `Result`, struct or enum on the left gives its type to
  the right side, so `x == none` and `xs == []` check. `..` and `...` take two
  `Int` values.
- `and`, `or` and `not` take only `Bool`. `&&`, `||` and `!` are the same
  operators. A `!` directly after a name belongs to it (`read!`); `!=` is
  inequality.
- There is no operator overloading. Expressions, arguments and constructor
  fields are evaluated left to right. Float comparisons follow IEEE 754: NaN is
  not equal to itself.

### Variables and scope

The first assignment introduces a variable in the current scope, and an
annotation is allowed only there. Later assignments change its value, not its
type. Each function and control block is a lexical scope. An assignment without
annotation updates a visible variable of that name, or else introduces a local
in the current block. A new name cannot shadow a visible one, so one name means
one variable in a scope. Parameters and the `for` variable are initialized
bindings; the `for` variable cannot be reassigned. Variables created in a block
are not visible after its `end`.

`_` is a discard wherever a name is bound: an assignment target (`_ = f()`), a
`for` variable, a block or function parameter and a pattern slot. It binds
nothing, so it can repeat and never conflicts with another name. Reading `_` is
`CHECK-UNKNOWN-NAME`, and `_: Int = x` is `PARSE-UNEXPECTED-TOKEN`.

A name that is never read is `CHECK-UNUSED-VARIABLE`, unless it starts with `_`
(`_count`): the opt-out for a name kept on purpose, and the name can still be
read. The rule covers a variable introduced by an assignment, a `for` variable,
a block parameter and a name in a `case` pattern; it never covers a function
parameter, which is part of the signature that callers, `&name` callbacks and
adapters depend on. A name is read when it is evaluated as an expression
anywhere in its scope, in a nested block too. An assignment to the name itself
is not a read of it: in `x += 1`, `x = x + 1` and `xs = xs.push(v)` the `x` on
the right does not count, so a counter that is only incremented, or a list that
is only appended to, is unused. The rule is per variable, not per assignment:
`x = 1`, `x = 2`, `puts(x)` is valid. The error is at the place where the name
is introduced (the assignment statement, the `for` variable, the block
parameter or the pattern name), the first in the source when several are unused,
and it is found at the end of the function, after every other error of it. To
drop a value, write `_ = f()`; to ignore a loop variable, a parameter or a
payload, write `for _ in 0...n`, `|_, i|` or `error(_)`. The query commands
(`type-at`, `refs`, `symbol`) do not report it in the file they are asked about,
since an editor writes a name before its first use; the files that file imports
keep the rule.

### Module constants

A constant (section 5) is a value fixed for the whole run. It is read by its
name, as an expression, so everything that works on a value works on it:
`LEVELS.get(kind, 0)`, `KEYWORDS.include?(word)`, `CLASSES[code]`,
`CONFIG.port`, `"#{LIMIT}"`. A local variable, a parameter or a block parameter
is never an all-capitals name, so a constant cannot be shadowed, and nothing
assigns to one: `LIMIT = 2` or `LIMIT += 1` inside a function is
`PARSE-INVALID-ASSIGNMENT-TARGET`. A constant is not a pattern: `case` patterns
are literals and variants, and a constant name where a pattern goes is
`PARSE-UNEXPECTED-TOKEN` with the help `a constant is not a pattern; compare
with if`. A constant of a struct type can be updated like any struct value:
`CONFIG.with(port: 81)` gives a copy and the constant stays as it was.

The initializer is a constant expression, and its rules are checked after the
whole program is read, in the order the constants depend on each other (a
constant may read one declared later in its file). It may contain literals,
string interpolation, list, map and `Set.new` literals, ranges, construction of
structs, enum variants and `ok`/`error` values, operators, field access and
indexing, reads of other constants, regex literals, and calls of builtins whose
catalog row has no effects, with block literals passed to them (the body of
such a block may use assignments, `if`, `case`, `for`, `break`, `next` and
`return`). It may not
contain a call of a function declared with `def`, a function value (`&name`), a
block that is not an argument of a builtin, a `while` loop, or a call of a
builtin with effects (`stdout`, `stdin`, `filesystem`, `network`, `subprocess`,
`clock`, `random`, `concurrency` and the rest): each is
`CHECK-CONSTANT-EXPRESSION`, located at that form. Every expression inside the
initializer, not only the result, has a data type: numbers, `String`, `Bool`,
`Nil`, `Bytes`, `List`, `Map`, `Set`, `Range`, `Result`, `Optional` and `JSON`
of data types, and structs and enums whose fields and payloads are data; a
function, `Channel`, task, handle or `ATS` table type (and `Void`) is
`CHECK-CONSTANT-TYPE`, located at the expression. `Channel.new` has no
effects, but it makes a value with identity and state, which is why the type
rule exists.

A scalar literal constant is part of the bytecode. Every other constant is built
once, in dependency order, before `main` starts, and only if a function that
`main` can reach reads it (directly, or through another constant): a constant
that nothing reads never runs. An initializer that fails (`BAD = [1][5]`, an
index out of range) stops the program before `main` prints anything, with a
stack trace that names the constant.

Constants that read each other in a loop, directly or through others, are
`CHECK-CONSTANT-CYCLE`, located at the read that closes the cycle, with the help
`the cycle is A -> B -> A`. The checker follows the reads of an initializer in
the order of their start offsets in the source, constants in the order of the
linked declarations, which also gives the order the constants are set up in. An
unknown name in capitals is `CHECK-UNKNOWN-NAME`, with a `did you mean` help
over the constants the file can read: its own, declared above or below, and the
ones it imports by name, by the name written. The nesting limit
(`CHECK-TOO-DEEP`) counts initializers too.

**Decided against.** Literals only, with no evaluation: it cannot express the
compiler's own tables (`Set.new(...)` is a call, the character classes are a
fold, the builtin rows are struct constructors). Compile-time evaluation: it
would put the semantics of every allowed builtin in the compiler and the VM
both. Lazy initialization on first read: an initializer error would surface in
the middle of a run, a read would need a branch, and tasks could race on the
first read. Calls of user functions in an initializer. An Elixir-style `@name`
attribute or a `const` keyword, since the capitals already mark a constant. A
constant in a `case` pattern: patterns are literals and variants. Folding
literal arithmetic. One line holding both import forms.

### Regex literals

A regex literal (lexical form in [§4](04-lexical.md)) has the type
`Regex.Regex` of `std/regex`, and its value is `Regex.compile` of the body,
after `(?i)`, `(?s)` or `(?is)` for the flags `i`, `m` or both. So `/a.b/im`
has the `source` `(?is)a.b`. The file must import `std/regex`, in any form (an
alias, another alias, or a name list); without one the literal is
`CHECK-REGEX-IMPORT`, at the literal. The checker compiles the pattern with
`std/regex`, so a literal never fails at run time: a pattern it refuses is
`CHECK-INVALID-REGEX`, at the character of the body that the error names, or
at the whole literal when the place is past the body.

A literal in a function or block body is built once, before `main`, as a
constant is, and only if a function that `main` can reach holds it: a loop does
not compile it again. A literal in a constant initializer is built with that
constant. `^` and `$` are text anchors, not line anchors as in Ruby;
`/(?m)^a/` gives line anchors. There is no `=~` and no `$1`: use
`Regex.match?`, `Regex.match` and the groups of the match.

### Void completion

`Void` has no literal and no usable payload. It is allowed as a function's
return type, as the last type of `Fn`, and as the completion type of `Result` or
`Task`. Bare Void variables, parameters, fields, list elements and map values
are `CHECK-VOID-TYPE`. Wrappers such as `List[Result[Void]]` are valid.

A Void call may be a statement, or be returned from a Void function. Assigning,
passing, constructing, operating on or inspecting a Void result is
`CHECK-VOID-VALUE`, and so is `Result.unwrap!` on `Result[Void]`, `Task.await`
on `Task[Void]`, or a successful `try` on `Result[Void]`. `ok()` infers
`Result[Void]`, and `ok(nil)` is `Result[Nil]`. `Result.unwrap_or` cannot
operate on `Result[Void]`. The timed `Task.await(task, timeout_ms)` on a
`Task[Void]` is not a Void value: it gives `Await[Void]`, which is matched as
`Await.Done(_)` or `Await.TimedOut`.

### Functions and entry point

- Functions can be called before their declaration, and can be recursive.
  Arguments are positional: there is no overloading or named argument for
  ordinary functions. A parameter may have a default value (below).
- A function with a non-`Void` return type must give a value on every reachable
  path. A loop does not guarantee one.
- The value of such a function is its last expression, unless a `return` leaves
  before it. When the last statement is an `if` with an `else`, or a `case`, the
  rule applies to the last statement of each branch and each arm, at any depth.
  An `if` without `else`, a loop, a binding or a `try` statement at the end
  gives no value: `CHECK-MISSING-RETURN` at the function. A last expression of
  type `Void` (a call) gives none either: `CHECK-MISSING-RETURN` at that
  expression. A last value of another type is `CHECK-TYPE-MISMATCH` there.
- The rule reads the result type as written. In a `Void` function, and in one
  whose result is an alias of `Void`, the last expression is a statement whose
  value is dropped: `CHECK-UNUSED-VALUE` and `CHECK-UNUSED-RESULT` apply to it.
  Blocks give their last expression already (below).
- `return` without a value completes a `Void` function. A `Nil` function ends
  with `nil`.
- An executable declares exactly one `main() -> Void` with no parameters and no
  type parameters. A run and `agentica compile` report `CHECK-MAIN` without it;
  `agentica check` does not need a `main`, but one that is declared must have
  this signature. Under `agentica test` a `*_test.agc` file with no `main` gets
  one that runs its `test_*` functions (`06c-tasks-and-tests.md`).

### Default parameter values

```agentica
def join(xs: List[String], sep: String = ", ") -> String = xs.join(sep)

join(["a", "b"])        # a, b
join(["a", "b"], "-")   # a-b
```

A parameter written `NAME: type = expression` has a default value, which a call
may leave out. After a parameter with a default, every parameter has a default,
except a last parameter of type `Fn[...]`, which stays without one so that a
block can still fill it. Any other parameter without a default after one with a
default is `CHECK-DEFAULT-ORDER`, located at that parameter.

A default is a constant: an `Int`, `Float` or `String` literal (a minus sign is
allowed before a number, and a string has no `#{...}`), `true`, `false`, `nil`,
`none`, `[]`, `{}`, or a nullary enum variant (`Level.Info`, `LogLevel.Info` for
a builtin enum, or `Models.Level.Info` through an import alias). A parameter
may also default to a struct built with no arguments, `options: Options =
Options()`: each field takes its own default, and a field without one is
`CHECK-MISSING-FIELD` at the default. A default may also name a module
constant (`limit: Int = LIMIT`): one of the same file, an imported one through
its alias (`Limits.LIMIT`) or one imported by name, as long as the value of
the constant is itself one of these forms (not a call, an operation, another
constant, a non-empty list or map; a struct with no arguments only for a
parameter). The name is the value written in its place, so the default is the
same at every call and a caller in another module that leaves the argument out
gets it without importing the constant. Anything else (a call such as
`some(1)`, any other name, `&name`, a struct with arguments, a variant with a
payload, a non-empty list or map, an interpolated string, an operation) is
`CHECK-DEFAULT-VALUE`, located at the expression, with a help that says to make
the parameter required. A default cannot read another parameter.

The type of a default is checked against the type of its parameter like an
initializer: `[]` and `{}` take the parameter type as their expected type, and a
mismatch is `CHECK-TYPE-MISMATCH` at the default. A default is built at each
call, so no call shares a value with another.

A call to a function with `N` parameters without a default and `M` in all takes
`N` to `M` arguments; any other count is `CHECK-ARITY`. Arguments fill the
parameters from the left. When the last parameter is an `Fn` without a default,
the block (or else the last argument) always goes to it, and the other arguments
fill the parameters before it from the left. With `def each_line(path: String,
timeout_ms: Int = 1000, f: Fn[String, Void]) -> Void`, both `each_line("a.txt")
do |line| ... end` and `each_line("a.txt", 50, &show)` are calls, and
`each_line("a.txt", 50)` gives `50` to `f`, so it is `CHECK-TYPE-MISMATCH`, not
`CHECK-ARITY`.

A call through an import alias leaves out defaults too (`Util.join(xs)`), and an
alias call written without parentheses fills all its defaults: `x =
Util.connect` is valid when every parameter of `connect` has a default. A
function value takes every argument: `&join` has type `Fn[List[String], String,
String]`, and `.call` needs both arguments. Defaults are part of an exported
signature. A default is resolved in the module that declares the function, so
`Models.Level.Info` means the same for a caller that does not import that file.

A builtin can have defaults by the same rules, in its catalog row:
`Zlib.crc32(data, seed = 0)` takes 1 or 2 arguments, in call, method and pipe
form alike. A builtin default may also be an empty `Bytes`, shown as `"".bytes`
(`auth_data` of `OpenSSL.Cipher.aes_256_gcm_encrypt`). The call site fills the
arguments left out, so the VM always gets a full call; `CHECK-ARITY` names the
range (`expects 1 to 2 argument(s)`). A builtin has no function value
(`&Zlib.crc32` is `CHECK-UNKNOWN-NAME`). A Lazy method row can have defaults
too: `lz.deflate(level = 6, raw = false)`. `agentica help` shows the default
(`seed: Int = 0`).

### Enums and pattern matching

Enums are nominal sum types and may declare type parameters. Variants are
qualified by their enum, and payloads are positional. A nullary variant is
written `Command.Show` or `Command.Show()`, and a method reads on it
(`Command.Show.to_s`). Constructor type parameters come
from the payloads and the expected type; unresolved or conflicting ones are
errors.

A type alias is transparent: `type Grid = List[List[Float]]` means the same type
as `List[List[Float]]` in annotations, arguments, returns and builtin type
arguments. An alias adds no runtime representation or conversion. It can name a
builtin, struct, enum or function type, or another alias; a cycle is
`CHECK-TYPE-ALIAS-CYCLE`. An alias is not a constructor or enum: construct or
match using the underlying struct or enum name.

Generic aliases (`type Matrix[T] = List[List[T]]`) are in section 5.

`case value ... end` is a statement. An arm may put one simple statement on the
arrow line (`1 -> puts("one")`), and more lines of the same arm may follow. A
pattern is a primitive literal, `_`, `ok(...)` or `error(...)`, or a qualified
variant with one slot per payload position. A slot is a name (a binding), `_`, a
literal (a negative number too), or another variant pattern, `ok(...)` or
`error(...)`, to any depth (the parser's nesting limit applies, one level for
each nested variant). Bindings are local to the arm, and a name may appear once
in an arm (`CHECK-SHADOWED-NAME` otherwise, at the variant pattern that holds
the second one). A nested literal has the type of its payload position
(`CHECK-PATTERN-TYPE`), and a nested variant must belong to the enum of its
position. A name alone is not a top-level pattern. Payloads are positional:
there are no struct or list patterns.

An arm may carry a guard, `pattern if condition -> ...`. The condition is a
`Bool` expression (`CHECK-TYPE-MISMATCH` otherwise) that sees the bindings of
its own arm. The arm runs when the pattern matches and the condition is `true`;
otherwise the case goes on with the next arm. The parser looks for the guard of
an arm up to the first `->` of its line, so a guard stays on the line of its
pattern.

An arm may list several patterns on its line, separated by commas: `"ex", "px"
-> ttl(value)`. The arm runs when one of them matches, tried left to right, and
its guard applies to all of them. Such an arm binds no names
(`CHECK-CASE-ARM-BINDING`, at the patterns): write `_` in the slots, or one arm
per pattern. Each pattern counts on its own for exhaustiveness and
reachability, so a pattern that an earlier arm or an earlier pattern of the
same arm already covers is `CHECK-UNREACHABLE-CASE-ARM` at that pattern.

Enum values need every variant, unless there is a catch-all `_`. `Result[T]`
matches as `Result.Ok(value)` and `Result.Err(message)`, or as `ok` and `error`;
`Result.Ok(_)` discards the payload. `Optional[T]` matches as `some(value)` and
`none`. The builtin `Await[T]` of a timed
`Task.await` matches as `Await.Done(value)` and `Await.TimedOut`, with the same
rules. Every other `case`, including one on `Bool` or `Nil`, needs `_`. A
catch-all is the last arm when it has no guard, and duplicate or unreachable
arms are rejected. The codes are `CHECK-ENUM-TYPE-INFERENCE`,
`CHECK-PATTERN-TYPE`, `CHECK-NON-EXHAUSTIVE-CASE` and
`CHECK-UNREACHABLE-CASE-ARM`.

A `case` gives a value in three places, and is a statement everywhere else:

- the right side of an assignment, `text = case r ... end`, also with an
  annotation (`x: T = case ...`) or `+=` and the like;
- after `return`, `return case s ... end`;
- the last line of a block, `items.map do |item| case item ... end end`.

Each arm of such a case ends with an expression, which is the value of the arm;
lines may come before it (`CHECK-CASE-ARM-VALUE` when an arm ends with another
statement, such as `return`, `next`, `break` or a nested `case`, or has no
body). All arms have one type, which is the annotation of the assignment or the
type the context expects when it has one, else the type of the first arm:
`CHECK-TYPE-MISMATCH`, at the last expression of the arm that differs. So write
`x: Result[Int] = case ...` when the first arm is `error(...)`, `[]` or `none`.
The case must be exhaustive by the rules above.

On the last line of a block the case stays a statement when the block's result
is `Void` (the block of `each`) or when an arm ends with another statement. When
the block's result is not known from its context (the block of `Task.spawn`),
a case whose arms are `Void` or of one other type, with at least one `Void`, is
a statement and the block gives no value; otherwise it gives the value. Arms of
two different non-`Void` types are `CHECK-TYPE-MISMATCH`, even when another arm
is `Void`.

Exhaustiveness and reachability are conservative, and no deeper analysis is
done. An arm covers its variant only when it has no guard and every slot is a
name or `_`. An arm with a guard, a literal slot or a nested variant covers
nothing: it is a test that may fail. So a guarded `_ if c ->` does not make a
case exhaustive, and a case that matches only `Shape.Boxed(some(n))` (a variant
with an `Optional` payload) needs a `Shape.Boxed(_)` arm (or `_`) after it, as
`ok(Reading.Value(n))` needs `ok(_)` and `some(0)` needs `some(n)` or `_`. An
arm is unreachable (`CHECK-UNREACHABLE-CASE-ARM`) only when an earlier arm
without a guard already covers its variant with names and `_`, or follows an
unguarded catch-all. The same pattern may come again after a guarded or
refutable arm, guarded or not.

The example declares a user generic enum, to show the rules; a value that may be
missing is the builtin `Optional[T]` (see "Optional values").

```ruby
enum Option[T]
  Some(T)
  None
end

def display(option: Option[Int]) -> Void
  case option
    Option.Some(item) -> puts(String.from_int(item))
    Option.None -> puts("empty")
  end
end

def label(option: Option[Int]) -> String
  case option
    Option.Some(0) -> return "zero"
    Option.Some(n) if n < 0 -> return "negative"
    Option.Some(_) -> return "positive"
    Option.None -> return "empty"
  end
end
```

### Structs and lists

A struct constructor gives each field at most once, by name, in any order. A
field written `NAME: type = expression` has a default value, which a
constructor may leave out; the field then gets the default. A field without a
default must be given (`CHECK-MISSING-FIELD`, located at the constructor), and
a name that is not a field is `CHECK-UNKNOWN-FIELD`. A field that is given twice
is `CHECK-DUPLICATE-FIELD`.

A field default follows the rules of a parameter default (see "Default
parameter values"): it is a constant of the same forms, or the name of a
constant with such a value, except a struct built
with no arguments (`CHECK-DEFAULT-VALUE`: its own defaults could build the
struct again at each construction, without end), anything else is
`CHECK-DEFAULT-VALUE` at the expression, and its type is checked against the
field type (`[]` and `{}` take the field type, a mismatch is
`CHECK-TYPE-MISMATCH`). There is no order rule: a constructor names its fields,
so any field may have a default. A default is checked where the struct is
declared, even when no constructor leaves the field out. It is built at each
construction that leaves the field out, so no two values share one, and it is
resolved in the module that declares the struct, so a constructor in another
module can leave the field out without importing what the default names.
`value.with(...)` is not affected. A builtin record takes the defaults that the
catalog gives its fields: every field of `HttpClientOptions` and
`HttpServerOptions` has one, the other records have none.

`value.with(name: expr, ...)` is a copy of a struct with some fields changed;
the original is unchanged. The receiver must be a struct (any other type is
`CHECK-UNKNOWN-METHOD`, with help that `with` copies structs), each name must be
a field of it (`CHECK-UNKNOWN-FIELD`), given at most once
(`CHECK-DUPLICATE-FIELD`), with a value of the field's type
(`CHECK-TYPE-MISMATCH`; `[]` and `{}` take the field type). A bare
`value.with(...)` whose result is dropped is `CHECK-UNUSED-VALUE`. The receiver
is evaluated first, then the values from left to right, and all values see the
receiver as it was before the update: `p.with(a: p.b, b: p.a)` swaps the two
fields. The result has the receiver's type, so updates chain and nest:
`a.with(address: a.address.with(city: "Lima"))`. Changing some fields of an
existing value is what `with` is for; a constructor with every field is how to
build a new one. An update builds a value, so it follows the rules of
construction: a value of a struct that another module keeps private cannot be
updated by an importer (`CHECK-IMPORT-NAME`, as for constructing it), and the
importer needs the struct's own module among its imports, by an alias or by
names (a module imported by names counts with all its exported structs, not only
the ones it names). A field named `with` is allowed when its type is not a
function type: a field of type `Fn[...]` named `with` (or of a type parameter,
see "Generic structs") is `CHECK-REDEFINED-NAME`, because `value.with(...)` is
always the update; `value.with` without parentheses reads a data field of that
name.

`Type.members` lists the fields of a struct type, in declaration order, as a
`List[StructMember]`. `StructMember` is a builtin record, reserved like
`LogEvent`, with two `String` fields: `name`, the field name, and `type`, its
type written as source (`Int`, `List[String]`, `Map[String, Int]`,
`Result[Int]`, `Address`, `Shape[String]`). The text is the checker's printed
form: an alias is expanded (`type Id = Int` gives `Int`) and a struct or enum
from another module is written by its own name, without the import alias, so
`A.Point` and `B.Point` both give `Point`. `Type` is a struct you declare, one
you import by name or through an alias (`Models.User.members`), or a builtin
record such as `HttpResponse`. It is written without parentheses and not
piped: `User.members()` and `x |> User.members()` are `CHECK-UNKNOWN-NAME`, and
`Models.User.members()` is `CHECK-TYPE-MISMATCH`. There is no form on a value:
`user.members` is the field of that name, so a struct may have a field called
`members`. The list needs no runtime support beyond the instructions that build
it, but each evaluation builds it again, so hoist `Type.members` out of a hot
loop. Any other type name is an error: an enum or a resource is
`CHECK-UNKNOWN-METHOD`, an alias is `CHECK-UNKNOWN-TYPE` (name the struct
itself), and a name that is no declared type, or a builtin type such as `Int`,
is `CHECK-UNKNOWN-NAME`.

A list index runs from zero to length minus one; a negative or out-of-range
index is `RUNTIME-INDEX-OUT-OF-RANGE`. Indexing takes O(log32 n) time, at most
four steps for a million items; `for` visits the items in order. `for` iterates
a `List` in order, a `Set` in first-insertion order, a `Range`, or a `Bytes`
byte by byte. The core has
no slices and no string indexing.

### Generic structs

A struct declares type parameters after its name, as an enum does:
`struct Box[T] ... end`, `struct Pair[A, B] ... end`. The parameter names follow
the enum rules: type names that are not repeated and not reserved
(`CHECK-REDEFINED-NAME`). A field may use a parameter anywhere a type goes
(`value: T`, `items: List[T]`, `get: Fn[String, Result[T]]`, `next:
Option[Box[T]]`), and a struct may mention itself (`kids: List[Tree[T]]`). A
parameter may be a `Map` key or a `Set` element nowhere in the declaration
(`CHECK-MAP-KEY-TYPE`, `CHECK-SET-ELEMENT-TYPE`, as for enums). A field named
`with` whose type is a parameter is `CHECK-REDEFINED-NAME` at the field, since
the parameter could be an `Fn` and `value.with(...)` is always the update.

```ruby
struct Storage[T]
  get: Fn[String, Result[T]]
  put: Fn[String, T, Result[Void]]
end

struct Box[T]
  value: T
  items: List[T] = []
end

b = Box(value: 41)                     # Box[Int]
e: Box[List[String]] = Box(value: [])  # T from the annotation
```

A type is written with one argument for each parameter: `Box[Int]`,
`Pair[String, List[Int]]`. A bare `Box` and a wrong number of arguments are
`CHECK-UNKNOWN-TYPE` at the type, and an argument is checked as an enum
argument is (`Void` is `CHECK-VOID-TYPE`). An imported struct is written
`M.Box[Int]`, or `Box[Int]` after `import {Box} from "m"`; a parameter name in
its fields keeps its own meaning in the importing file.

A construction takes the arguments from the values, from left to right as they
are written, and from the expected type (an annotation, a parameter, a field or
a return type): `Box(value: 41)` is `Box[Int]`. A value of the wrong type for an
argument already known is `CHECK-TYPE-MISMATCH` at the value
(`Pair(a: 1, b: "x")` for `struct Pair[T]` with two `T` fields). An empty
list or map cannot say what an argument is, so it needs the expected type:
without one it is `CHECK-ENUM-TYPE-INFERENCE` at the value, and so is a
parameter that no given value fixes (a parameter no field uses, or a field left
out by its default), at the construction. The code keeps its enum name.

Every rule applies after substitution. `b.value` is `Int` for a `Box[Int]`;
`b.with(value: 7)` has the type of `b` and checks the new value against `Int`. A
generic instance has `to_s`, `inspect` and `Test.eq` when its arguments are data
types, so `Box[Int]` prints and `Box[Fn[Int, Int]]` does not
(`CHECK-TYPE-MISMATCH`). `Type.members` is on the bare name (`Box.members`) and
writes the field types as declared, so `value: T` gives `T`.

`JSON.encode` and `JSON.from` accept a generic instance whose fields are
encodable after substitution (`Box[List[Int]]`), and give `CHECK-NOT-ENCODABLE`
when one is not (`Box[Fn[Int, Int]]`). `JSON.decode` and `JSON.schema` reject a
generic instance anywhere in the target (a field `b: Box[Int]`, or an alias of
one) with `CHECK-NOT-DECODABLE`, because the schema is keyed by the bare struct
name and `Box[Int]` and `Box[String]` would share it; a bare generic struct as
the target is `CHECK-UNKNOWN-TYPE`. A type argument counts after substitution
for `JsonField` too (rules in `06b-builtins.md`, "Optional and nullable
fields"). A C struct of an `extern` block takes no type parameters
(`PARSE-UNEXPECTED-TOKEN` at the `[`). Type parameters exist only in the
checker: the VM sees a struct of its field names and order, as before.

### Generic functions

A function declares type parameters after its name: `def first_or[T](xs:
List[T], fallback: T) -> T`. The names follow the enum rules, with one more: a
name that a struct, enum or alias of the file already has (declared there or
imported by name) would hide that type, so it is `CHECK-REDEFINED-NAME` at the
parameter, as are a repeated name and a reserved one (`Int`, `List`). `def f[]`
is `PARSE-UNEXPECTED-TOKEN`. `main` with type parameters is `CHECK-MAIN`. A type
parameter that no parameter type and no result type mentions cannot be inferred:
`CHECK-ENUM-TYPE-INFERENCE` at its name. A parameter whose type mentions a type
parameter takes a default as any other: `none`, `[]` and `{}` fit `Optional[T]`,
`List[T]` and `Map[String, T]`, and `x: T = 1` is `CHECK-TYPE-MISMATCH` at the
default. A call that leaves out every argument that shows a type parameter
cannot infer it (`CHECK-ENUM-TYPE-INFERENCE` at the call).

```ruby
def first_or[T](xs: List[T], fallback: T) -> T
  return fallback if xs.length == 0

  return xs[0]
end

def max_by[T](xs: List[T], key: Fn[T, Int]) -> Optional[T]
  # ...
end

puts(first_or(["ana", "ben"], "none"))  # T is String
puts(first_or([], 0))                   # T is Int, from 0; [] is checked last
```

**Inference.** A call gives no type arguments. The checker finds them in four
steps; a call has its own type variables, so the `T` of the callee and the `T`
of the caller do not mix:

1. The arguments that have a type of their own, from left to right. Each one
   binds the type parameters of its parameter type; a value of another type
   than one already bound is `CHECK-TYPE-MISMATCH` (`first_or([1], "x")`).
2. The expected type of the call (an annotation, a parameter, a field or a
   return type) is matched with the result type, for the parameters still open.
   The arguments win over it. A parameter that only the result mentions, as in
   `def empty_of[T]() -> List[T]`, comes from here.
3. The arguments that need an expected type are checked against their parameter
   type as far as it is known, and bind nothing: `[]`, `{}`, `Set.new([])`,
   `error(...)`, a variant of a generic enum without a payload, a list or map
   literal that holds one of them, and `&f` of a generic function. As the
   argument of a builtin method, `&f` gets its type only where the method fixes
   the whole `Fn` type: the callback of `filter`, `any?`, `all?` and `each`,
   and the predicate of `find`, `partition` and `take_while`. Elsewhere, as in
   `map`, bind it first: `f: Fn[Int, Bool] = &name`.
4. The block, the last argument. Its parameter types come from the `Fn`
   parameter; one that is still open must be annotated in the block (`do |x:
   Int|`), which binds it, else `CHECK-BLOCK-TYPE`. The block's result binds the
   open parameters of the `Fn` result (`R` in `Result[R]`); a result that does
   not fit is `CHECK-TYPE-MISMATCH`. A step 3 argument whose parameter type is
   still open waits for the block. A step 3 argument binds nothing: with
   `def apply[A, B](x: A, f: Fn[A, B])`, the call `apply(3, &id)` leaves `B`
   open.

A type parameter still open after step 4 is `CHECK-ENUM-TYPE-INFERENCE` at the
call. The call has the result type with the arguments put in. Recursion, mutual
recursion and a generic function that calls another work; a recursive call may
use other type arguments, because the checker builds no copy per type. A type
argument may be `Void` where `Void` is valid after substitution (a result, the
last type of an `Fn`, the completion of a `Result` or a `Task`: `ok()` binds `R`
to `Void` in `Result[R]`); a parameter or a list item that becomes `Void` is
`CHECK-VOID-TYPE` at the call. `try f(x)`, with `f` returning `Result[T]`, gives
`T`. A call is no constant expression (`CHECK-CONSTANT-EXPRESSION`).

**Inside the body.** A type parameter stands only for itself, and the body is
checked once, whatever the types of the calls. A `T` value can be stored,
returned, put in a `List`, a `Result`, a `Map` value, a struct or an enum
payload, captured by a block, and passed to anything that takes that type. A
`T` annotation is valid in the body (`x: T`, `do |y: T|`). These are errors, as
they are for an `Fn`:

- `==`, `!=`, arithmetic and ordering: `CHECK-TYPE-MISMATCH`.
- `puts`, interpolation and the other printing forms: `CHECK-TYPE-MISMATCH`;
  `x.to_s` and `x.inspect` are `CHECK-UNKNOWN-METHOD`, like any method of `T`.
- a field or a method (`x.name`, `x.with(...)`): `CHECK-UNKNOWN-METHOD`;
  `x.call(...)`: `CHECK-TYPE-MISMATCH`.
- a literal or variant arm in `case x`: `CHECK-PATTERN-TYPE`.
- `JSON.decode(text, T)`: `CHECK-NOT-DECODABLE`, since decoding needs the type
  at run time. Take a `Codec[T]` parameter instead
  (`docs/grammar/06b-builtins.md`, JSON).
- `T` as a `Map` key or a `Set` element: `CHECK-MAP-KEY-TYPE` and
  `CHECK-SET-ELEMENT-TYPE`, wherever it is written; a call with `Int` does not
  help.

`JSON.encode(x)` and `JSON.from(x)` are allowed when the type of `x` holds
type parameters (`T`, `List[T]`, `Map[String, T]`, `Box[T]`, `Optional[T]`)
and some types for them would make it encodable; otherwise (`Task[T]`, an
`Fn`) they are `CHECK-NOT-ENCODABLE` in the body. The check of the types moves
to each call: when a call (or a reference `&f`) binds the type parameters,
the bound types must be encodable, else `CHECK-NOT-ENCODABLE` at the argument
that binds them (at the call, or the reference, when no argument does). A
generic function that passes its own `T` to such a function takes on the same
requirement, wherever the two are declared.

Behaviour comes from `Fn` parameters, as in `max_by`: there are no traits or
constraints on a type parameter. The data-type and effect rules are judged on
the substituted types at each call: with `fns: List[Fn[Int, Int]]`,
`puts(first_or(fns, &id))` is `CHECK-TYPE-MISMATCH`, because `T` is that `Fn`.

**References.** `&first_or` is a value only where the expected `Fn` type fixes
each type parameter: `f: Fn[List[Int], Int, Int] = &first_or` is valid, and `f =
&first_or` is `CHECK-ENUM-TYPE-INFERENCE` at the reference. A type parameter of
the enclosing function counts as fixed.

**Modules.** An exported generic function is called as any function
(`M.first_or(xs, 0)`, or `first_or(xs, 0)` after `import {first_or} from "m"`).
Linking keeps the type parameters local, in the signature and the body: a bare
`T` does not get the module prefix. Type parameters exist only in the checker:
the bytecode of a body is the same for any type argument. Not in the language:
constraints on type parameters, type arguments written at a call, generic
`extern` functions and generic `Map` keys.

### Ranges

`a..b` includes `b`; `a...b` excludes it, as in Ruby. A `Range` is a small
immutable value (start, end and kind); it never holds a list. Its functions
are in the
[`Range` page](../../site/content/library/data-structures/range.md).

- `for x in range` yields each `Int` in order. An end before the start is empty,
  and there is no reverse iteration. Iterating up to the largest `Int` does not
  overflow. The range is evaluated once.
- `Int.times`, `upto` and `downto` return `Void`. A negative literal receiver
  needs parentheses: `(-5).times do ... end`; `-5.times do ... end` is
  `-(5.times ...)`, a `CHECK-VOID-VALUE`.
- Ranges are not JSON-encodable and cannot be `Map` keys. Ranges of `String` or
  `Float`, and `step`, are not supported.

### Bytes

`Bytes` is an immutable string of bytes, one byte for each item, read as an
`Int` in `0..255`. It holds data that is not text. There is no literal: write
`"PK".bytes`, `OpenSSL.Digest.hexdecode(text)` or `Bytes.from_list([80, 75])`.
The methods, the encodings, the costs and the errors are in the [`Bytes`
page](../../site/content/library/data-structures/bytes.md). The language fixes:

- `for byte in b` visits the bytes in order.
- `==` and `!=` compare length and bytes. They are not constant time: compare a
  MAC or a token with `OpenSSL.HMAC.secure_compare`. A `Bytes` never equals a
  `String` with the same bytes (`CHECK-TYPE-MISMATCH`). There is no ordering
  (`<`).
- A `Bytes` is a `Map` key, an `ATS` key or a `Set` item, and a field, a list
  item or a map value. It is not JSON-encodable or decodable
  (`CHECK-NOT-ENCODABLE`, `CHECK-NOT-DECODABLE`).
- `Bytes` is a reserved type name (`CHECK-REDEFINED-NAME`). `String` has no
  index (`CHECK-NOT-INDEXABLE`); `s.bytes[i]` reads a byte.

### Maps

`Map[K, V]` has exactly two type arguments: `K` is `Int`, `String` or `Bytes`,
and `V` is any type.

```ruby
stock: Map[String, Int] = {"apple": 3, "pear": 0}
apples = stock["apple"]
more = Map.put(stock, "kiwi", 7)
```

- A literal uses braces and `key: value` pairs. An empty `{}` needs an expected
  type, like `[]`: `CHECK-EMPTY-MAP-TYPE` (`CHECK-EMPTY-LIST-TYPE` is for `[]`).
- `m[key]` returns the value; the key must have type `K`. A missing key is a
  runtime error (`RUNTIME-KEY-NOT-FOUND`).
- A repeated key in a literal keeps the last value at the first position.
  `Map.put` on an existing key keeps its position.
- Maps are immutable: there is no `m[key] = value`, and `Map.put` returns a new
  map. There is no `for` over a map; iterate `Map.keys`,
  which is in insertion order.
- Lookup, `Map.key?` and `Map.put` take effectively constant time;
  `Map.keys` is O(n).

### Sets

`Set[T]` has one type argument, `Int`, `String` or `Bytes`, like a `Map` key:
any other element type is `CHECK-SET-ELEMENT-TYPE`. A set holds each value once
and keeps the order of first insertion. Its functions are in the
[`Set` page](../../site/content/library/data-structures/set.md).

```ruby
seen: Set[String] = Set.new([])
seen = seen.add("a").add("b").add("a")
puts(seen)
```

- `Set.new([])` needs an expected type, like `[]` and `{}`:
  `CHECK-EMPTY-SET-TYPE`.
- Sets are immutable: `Set.add` and `Set.delete` return a new set.
- `for x in set` visits the elements in order. The set is read once before the
  loop, so assigning the variable in the body does not change the loop.
- `==` and `Test.eq` compare two sets in any order; there is no index
  (`CHECK-NOT-INDEXABLE`). A set is not JSON-encodable (`CHECK-NOT-ENCODABLE`)
  and cannot be a `Map` key, but it may be a field, a list item or a map value.

### Result and propagation

- `ok(value)`, `ok()` and `error(message)` build Results. `Result.Ok(x)`,
  `Result.Ok()` and `Result.Err(m)` are the same calls.
- `Result[T]` is builtin, not a user enum. It can nest and hold any payload. It
  has no fields or indexing; `==` compares it when `T` has equality.
- `ok(1)` infers `Result[Int]`. An expected `Result[T]` checks the payload
  against `T`, including empty lists and maps. `error("bad")` needs an expected
  Result type from an annotation, a binding, a parameter, a field, a return or a
  typed container element; otherwise it is `CHECK-RESULT-TYPE`. A block whose
  result type is not known (`map`, `Native.memory_pointer`, `Task.map`) takes
  it from its other `ok(...)` returns, so `return error("bad")` before the last
  `ok(x)` checks; a block with only `error(...)` still needs the annotation.
  Container inference uses the first element, so `[ok(1), error("bad")]` infers
  and the reverse order needs an annotation.
- The functions are in the
  [`Result` page](../../site/content/library/errors/result.md).
  `Result.unwrap!` on an error halts with `RUNTIME-UNWRAP-ERROR` at the call.
  `Result.ok?` and `Result.message` need a known Result type. `ok(false)` and
  `ok(nil)` are successes. An error value never prints a diagnostic or changes
  the exit code. Non-bang String conversions return an error for bad text or
  overflow; other runtime failures are never turned into Results.
- `try` has unary precedence. It evaluates one `Result[T]` operand once: on
  success it gives `T`; on error it returns the error from the current function.
  Only a function that returns `Result[...]` may use it (`CHECK-TRY-CONTEXT`
  otherwise). An expected type `T` gives the operand `Result[T]`; the return
  type alone does not. A success still needs an explicit `return ok(...)`.
- A `Result[T]` that is dropped, as an expression statement or as the last
  statement of a `Void` block, is `CHECK-UNUSED-RESULT` at the expression. It
  does not matter who made it (a user function, a builtin with or without
  effects, `Task.await`, `.call`) or what `T` is (`Result[Void]` too). It is
  checked before `CHECK-UNUSED-VALUE`, so a pure builtin that gives a Result,
  such as `s.to_i`, is this error. Handle the Result with `try`, a `case`,
  `.unwrap!`, or drop it on purpose with `_ = f()`. `IO.inspect(r)` gives back
  what it printed, so it is exempt. A dropped `Task[Result[T]]`
  (`Task.spawn(&save)`) is not a Result and stays valid.

```ruby
def read_age(text: String) -> Result[Int]
  age = try String.to_int(text)
  return ok(age)
end
```

### Optional values

- `some(value)` and `none` build Optionals. `Optional[T]` is builtin, not a user
  enum. It is allowed wherever a type is (variables, parameters, returns,
  fields, list and map items, type arguments) and can nest; `Optional[Void]` is
  `CHECK-VOID-TYPE`.
- `some(1)` infers `Optional[Int]`. `none` needs an expected Optional type, as
  `error(...)` needs a Result type (`CHECK-OPTIONAL-TYPE` otherwise), and a
  block of unknown result type takes it from its `some(...)` values.
- The functions are in the
  [`Optional` page](../../site/content/library/data-structures/optional.md).
  `o.unwrap!` on `none` halts with `RUNTIME-UNWRAP-NONE` at the receiver.
- An Optional prints as `some(1)` or `none`. `none` may be the default of a
  parameter or field (`port: Optional[Int] = none`).
- In JSON, `none` is `null` and `some(x)` is `x`; decode reads `null` or a
  missing key as `none` (06b-builtins.md, "Optional values in JSON").

### Function values

`f: Fn[Int, Int] = &double` refers to a declared function with exactly those
types, and `f.call(21)` invokes it. Function values can travel through lists,
maps, parameters, returns and fields. A bare function name is not a value.
Functions have no equality, fields, indexing or JSON encoding; `IO.inspect`
prints `<Fn>`.

A builtin is a function value too: `&Time.now_ms` is `Fn[Int]`, and a method
written on its type, `&Int.to_s`, takes the receiver first (`Fn[Int, String]`).
It takes every parameter, those with a default included (`&Zlib.crc32` is
`Fn[Bytes, Int, Result[Int]]`). Only a builtin with one form, no rule of its own
and no type parameter can be one, written as Ruby writes it (`&String.strip`,
not `&String.trim`); any other (`&File.open`, `&List.map`, `&puts`) is
`CHECK-UNKNOWN-NAME` with a help: pass a block that calls it.

A field of type `Fn` is called through the struct, without `.call`:
`store.put(a, b)` is `store.put.call(a, b)`. The arguments are checked against
the parameters of the field's type (`CHECK-ARITY`, `CHECK-TYPE-MISMATCH`), the
value is the result of the function, and `store.put` without parentheses still
reads the function. Structs have no methods, so the name of an `Fn` field
cannot clash with one, except `to_s` and `inspect`: an `Fn` field of that name
wins, as the field does when it is read. A field named `with` cannot hold a
function, so `x.with(...)` is always the struct update. Calling a field of any
other type, or a name that is no field, is `CHECK-UNKNOWN-METHOD`.

### Blocks and closures

A block is a function written at the call site, as the last argument of a call:

```ruby
doubled = xs.map do |x|
  x * 2
end
total = xs.reduce(0) do |sum, x| sum + x end
```

- **Where.** `do |a, b| ... end` comes right after the `)` of a call, or after a
  method name without parentheses. The called function's last parameter must be
  a `Fn`; otherwise `CHECK-BLOCK-TARGET`, for user functions and builtins alike.
  A user function keeps its parentheses; only a function reached through an
  import alias may drop them (`Util.start do ... end`). `do || ... end` is
  rejected.
- **Headers.** `case`, `while` and `for` headers may end with an optional `do`,
  which is never a block; a block in such a header needs parentheses.
- **Parameter types** come from the expected `Fn` or the builtin's rule
  (`xs.map` gives `x` the element type), or from annotations such as `do |x:
  Int|`. With neither, `CHECK-BLOCK-TYPE`. A wrong number of parameters is
  `CHECK-ARITY`.
- **Result.** `return` leaves the block, not the function. Without `return`, the
  last expression statement is the value. For `map` and `sort_by` the result
  type comes from the body, where every `return` and the last expression must
  agree (`CHECK-TYPE-MISMATCH`). A non-`Void` block must return on every path
  (`CHECK-MISSING-RETURN`).
- **`try`** in a block returns the error from the block, so the block's result
  must be a `Result` (`CHECK-TRY-CONTEXT` otherwise). The result type must come
  from the call, so `try` is not available in `map` and `sort_by` blocks. The
  block of `Task.map` gives a `Result[R]` with `R` not known from the call, and
  `try` works in it, since the outer type is always `Result`. In a block of a
  `Lazy` method (a step, `Lazy.produce` or a terminal) `try` works whatever the
  block's result type: a failed `try` ends the pipeline, and the terminal
  returns its error (`docs/grammar/06b-builtins.md`, `Lazy[T]`). A block nested
  in that block follows the rule above.
- **Capture by value.** A block sees the variables visible where it is written,
  with their values at creation; later outer assignments do not change it.
  Assigning to an outer variable inside a block is `CHECK-CAPTURED-ASSIGNMENT`;
  use `reduce` or a `for` loop. Block parameters and new variables cannot reuse
  a visible name (`CHECK-SHADOWED-NAME`).
- **Values.** A block has type `Fn[A, ..., R]` and works wherever a function
  value does, including as a BDD step. It shares the caller's step budget and
  call-depth limit. Blocks have no equality or JSON form.

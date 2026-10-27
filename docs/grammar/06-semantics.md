## 6. Minimal semantic rules

The grammar determines what can be written. The rules below determine which
programs are valid and how they run.

### Types and inference

- **Type:** `Int`
  - **Rule:** Signed 64-bit integer; overflow is a runtime error

- **Type:** `Float`
  - **Rule:** IEEE 754 binary64

- **Type:** `Bool`
  - **Rule:** Only `true` and `false`; there is no truthiness

- **Type:** `String`
  - **Rule:** Unicode text; concatenation with `+`

- **Type:** `Nil`
  - **Rule:** A single data value, `nil`

- **Type:** `Void`
  - **Rule:** Completion without a usable value; no literal

- **Type:** `List[T]`
  - **Rule:** Homogeneous, immutable list; `Int` indexes from zero

- **Type:** `Map[K, V]`
  - **Rule:** Homogeneous, immutable map; the key `K` is `Int` or `String`;
    keeps insertion order

- **Type:** `Set[T]`
  - **Rule:** Immutable set of distinct `Int` or `String` values; keeps
    first-insertion order

- **Type:** `Result[T]`
  - **Rule:** `ok(value)`, or `error(message)` with a `String` message

- **Type:** `Json`
  - **Rule:** Opaque JSON value, used through the `JSON` module

- **Type:** `Range`
  - **Rule:** Immutable `Int` range: `a..b` includes `b`, `a...b` excludes it

- **Type:** `Fn[A, ..., R]`
  - **Rule:** Function value; the last type is its return, the others are its
    parameters

- **Type:** `Task[R]`
  - **Rule:** Opaque lightweight task with one result type

- **Type:** `Await[T]`
  - **Rule:** Builtin enum of a timed `Task.await`: `Await.Done(value)` or
    `Await.TimedOut`; matched with `case` like a user enum

- **Type:** `LogLevel`
  - **Rule:** Builtin enum of `std/logger`: `LogLevel.Debug`, `LogLevel.Info`,
    `LogLevel.Warning` and `LogLevel.Error`, in that order; matched with `case`
    like a user enum

- **Type:** `LogEvent`
  - **Rule:** Builtin record of `std/logger` that a log handler receives:
    `level: LogLevel`, `message: String`, `fields: Map[String, String]`,
    `time_ms: Int` and `task: Int`; it is not JSON-decodable

- **Type:** `StructMember`
  - **Rule:** Builtin record of `Type.members`: `name: String` and
    `type: String`, the field name and its type written as source

- **Type:** `Channel[T]`
  - **Rule:** Opaque bounded queue of `T` values that tasks send into and
    receive from

- **Type:** `Enum[T, ...]`
  - **Rule:** User-declared nominal sum type

- **Type:** Declared struct
  - **Rule:** Nominal type with typed, immutable fields

Parameters and function return types need annotations. Local variables may be
inferred from the initializer, as in `count = 3`. An empty list, map or
`Set.new([])` needs an expected type, from an annotation, a parameter, a field
or a return type: `names: List[String] = []`. A non-empty list has one element
type. There is no implicit numeric conversion and no `Any` type. `Nil` is not a
nullable wildcard: `name: String = nil` is invalid; use an enum such as
`Option[T]`.

### Operators

- `+`, `-`, `*` and `/` take two operands of one numeric type; `+` also
  concatenates `String`s. Integer `/` truncates toward zero, and `%` takes
  integers only, with `a = (a / b) * b + (a % b)`. Division by zero is
  `RUNTIME-DIVISION-BY-ZERO`, for `Float` too. An integer result outside `Int`
  is an error.
- Ordering operators take two numbers of one type. `==` and `!=` take one
  primitive type, or two `Range` values (equal when start, end and kind match).
  There is no list or struct equality. `..` and `...` take two `Int` values.
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
indexing, reads of other constants, and calls of builtins whose catalog row has
no effects, with block literals passed to them (the body of such a block may use
assignments, `if`, `case`, `for`, `break`, `next` and `return`). It may not
contain a call of a function declared with `def`, a function value (`&name`), a
block that is not an argument of a builtin, a `while` loop, or a call of a
builtin with effects (`stdout`, `stdin`, `filesystem`, `network`, `subprocess`,
`clock`, `random`, `concurrency` and the rest): each is
`CHECK-CONSTANT-EXPRESSION`, located at that form. Every expression inside the
initializer, not only the result, has a data type: numbers, `String`, `Bool`,
`Nil`, `List`, `Map`, `Set`, `Range`, `Result` and `JSON` of data types, and
structs and enums whose fields and payloads are data; a function, `Channel`,
task, handle or `ATS` table type (and `Void`) is `CHECK-CONSTANT-TYPE`, located
at the expression. `Channel.new` has no effects, but it makes a value with
identity and state, which is why the type rule exists.

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
literal arithmetic. One line holding both import forms. A static data form for
the initializers is a later option, only if start-up numbers ask for it.

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
- A function with a non-`Void` return type must return on every reachable path.
  A loop does not guarantee a return.
- The last expression does not return implicitly. `case` is a statement; a
  non-`Void` function may end with an exhaustive `case` only when every arm
  returns.
- `return` without a value completes a `Void` function. A `Nil` function uses
  `return nil`.
- An executable declares exactly one `main() -> Void` with no parameters. A run
  and `agentica compile` report `CHECK-MAIN` without it; `agentica check` does
  not need a `main`, but one that is declared must have this signature.

### Default parameter values

```agentica
def join(xs: List[String], sep: String = ", ") -> String
  return xs.join(sep)
end

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
`[]`, `{}`, or a nullary enum variant (`Level.Info`, `LogLevel.Info` for a
builtin enum, or `Models.Level.Info` through an import alias). Anything else (a
call, a name, `&name`, a struct, a variant with a payload, a non-empty list or
map, an interpolated string, an operation) is `CHECK-DEFAULT-VALUE`, located at
the expression, with a help that says to make the parameter required. A default
cannot read another parameter or a module constant.

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
form alike. The call site fills the arguments left out, so the VM always gets a
full call; `CHECK-ARITY` names the range (`expects 1 to 2 argument(s)`). A
builtin has no function value (`&Zlib.crc32` is `CHECK-UNKNOWN-NAME`). A
Lazy method row can have defaults too: `lz.deflate(level = 6, raw = false)`.
`agentica help` shows the default (`seed: Int = 0`).

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

Enum values need every variant, unless there is a catch-all `_`. `Result[T]`
matches as `Result.Ok(value)` and `Result.Err(message)`, or as `ok` and `error`;
`Result.Ok(_)` discards the payload. The builtin `Await[T]` of a timed
`Task.await` matches as `Await.Done(value)` and `Await.TimedOut`, with the same
rules. Every other `case`, including one on `Bool` or `Nil`, needs `_`. A
catch-all is the last arm when it has no guard, and duplicate or unreachable
arms are rejected. The codes are `CHECK-ENUM-TYPE-INFERENCE`,
`CHECK-PATTERN-TYPE`, `CHECK-NON-EXHAUSTIVE-CASE` and
`CHECK-UNREACHABLE-CASE-ARM`.

Exhaustiveness and reachability are conservative, and no deeper analysis is
done. An arm covers its variant only when it has no guard and every slot is a
name or `_`. An arm with a guard, a literal slot or a nested variant covers
nothing: it is a test that may fail. So a guarded `_ if c ->` does not make a
case exhaustive, and a case that matches only `Shape.Boxed(Option.Some(n))`
needs a `Shape.Boxed(_)` arm (or `_`) after it, as `ok(Reading.Value(n))` needs
`ok(_)`. An arm is unreachable (`CHECK-UNREACHABLE-CASE-ARM`) only when an
earlier arm without a guard already covers its variant with names and `_`, or
follows an unguarded catch-all. The same pattern may come again after a guarded
or refutable arm, guarded or not.

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
parameter values"): it is a constant of the same forms, anything else is
`CHECK-DEFAULT-VALUE` at the expression, and its type is checked against the
field type (`[]` and `{}` take the field type, a mismatch is
`CHECK-TYPE-MISMATCH`). There is no order rule: a constructor names its fields,
so any field may have a default. A default is checked where the struct is
declared, even when no constructor leaves the field out. It is built at each
construction that leaves the field out, so no two values share one, and it is
resolved in the module that declares the struct, so a constructor in another
module can leave the field out without importing what the default names.
`value.with(...)` is not affected, and neither are the builtin records.

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
a `List` in order, a `Set` in first-insertion order, or a `Range`. The core has
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
the target is `CHECK-UNKNOWN-TYPE`. `JsonField[T]` is allowed only as the type
of a struct field, so it is also refused as a type argument
(`CHECK-JSON-FIELD-PLACE`). A C struct of an `extern` block takes no type
parameters (`PARSE-UNEXPECTED-TOKEN` at the `[`). Type parameters exist only in
the checker: the VM sees a struct of its field names and order, as before.

### Ranges

`a..b` includes `b`; `a...b` excludes it, as in Ruby. A `Range` is a small
immutable value (start, end and kind); it never holds a list.

```ruby
for i in 0...3 do
  puts(i)
end
```

- `for x in range` yields each `Int` in order. An end before the start is empty,
  and there is no reverse iteration. Iterating up to the largest `Int` does not
  overflow. Each iteration costs one step plus its body. The range is evaluated
  once.
- `Int.times`, `upto` and `downto` (`n.times(f)`, `a.upto(b, f)`, `a.downto(b,
  f)`) return `Void`. A negative literal receiver needs parentheses: `(-5).times
  do ... end`; `-5.times do ... end` is `-(5.times ...)`, a `CHECK-VOID-VALUE`.
- `Range` functions are in
  [`library/data-structures/range.md`][agentica-link-1].
  `Range.size` is `RUNTIME-INTEGER-OVERFLOW` when the count does not fit in
  `Int`, and `Range.to_a` above 1048576 values is `RUNTIME-INVALID-COUNT`.
  `first` and `last` of an empty range are `error("the range is empty")`; unlike
  Ruby, `(1...5).last` is `ok(4)`.
- Ranges print as `1..5`. They are not JSON-encodable and cannot be `Map` keys.
  Ranges of `String` or `Float`, and `step`, are not supported.

### Maps

`Map[K, V]` has exactly two type arguments: `K` is `Int` or `String`, and `V` is
any type.

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
  map. There is no map equality and no `for` over a map; iterate `Map.keys`,
  which is in insertion order.
- Lookup, `Map.key?` and `Map.put` take effectively constant time;
  `Map.keys` is O(n).

### Sets

`Set[T]` has one type argument, `Int` or `String`, like a `Map` key: any other
element type is `CHECK-SET-ELEMENT-TYPE`. A set holds each value once and keeps
the order of first insertion.

```ruby
seen: Set[String] = Set.new([])
seen = seen.add("a").add("b").add("a")
puts(seen)
```

- `Set.new(items)` takes a `List[T]` and drops repeated items; the first one
  keeps its place. `Set.new([])` needs an expected type, like `[]` and `{}`:
  `CHECK-EMPTY-SET-TYPE`.
- Sets are immutable. `Set.add` and `Set.delete` return a new set and leave the
  input unchanged; adding a member or deleting a missing element gives an equal
  set. An element deleted and added again goes to the end.
- `Set.include?`, `Set.size` and `Set.empty?` read the set. `Set.to_a` gives the
  elements in order. `Set.union(a, b)` gives the elements of `a`, then those of
  `b` that `a` lacks; `Set.intersection` and `Set.difference` keep the order of
  `a`; `Set.subset?(a, b)` is true when every element of `a` is in `b`.
- `for x in set` visits the elements in order. The set is read once before the
  loop, so assigning the variable in the body does not change the loop.
- Sets print as `Set[1, 2]` (strings in their `inspect` form). There is no `==`
  on sets and no index (`CHECK-NOT-INDEXABLE`); `Test.eq` compares two sets in
  any order. A set is not JSON-encodable (`CHECK-NOT-ENCODABLE`) and cannot be a
  `Map` key, but it may be a field, a list item or a map value.
- Functions are in
  [`library/data-structures/set.md`][agentica-link-2].
  `Set.include?` and `Set.add` take effectively constant time; `Set.to_a` and
  the set operations are O(n).

### Result and propagation

- `ok(value)`, `ok()` and `error(message)` build Results. `Result.Ok(x)`,
  `Result.Ok()` and `Result.Err(m)` are the same calls.
- `Result[T]` is builtin, not a user enum. It can nest and hold any payload. It
  has no equality, fields or indexing.
- `ok(1)` infers `Result[Int]`. An expected `Result[T]` checks the payload
  against `T`, including empty lists and maps. `error("bad")` needs an expected
  Result type from an annotation, a binding, a parameter, a field, a return or a
  typed container element; otherwise it is `CHECK-RESULT-TYPE`. A block whose
  result type is not known (`map`, `Native.memory_pointer`, `Task.map`) takes
  it from its other `ok(...)` returns, so `return error("bad")` before the last
  `ok(x)` checks; a block with only `error(...)` still needs the annotation.
  Container inference uses the first element, so `[ok(1), error("bad")]` infers
  and the reverse order needs an annotation.
- `Result.unwrap!` passes `Result[T]` to its operand. On an error it halts with
  `RUNTIME-UNWRAP-ERROR`, the stored message, at the call. `Result.unwrap_or`
  evaluates both arguments, left to right, even on success.
- `Result.ok?` and `Result.message` need a known Result type. A success's
  message is `""`. `ok(false)` and `ok(nil)` are successes. An error value never
  prints a diagnostic or changes the exit code. Non-bang String conversions
  return an error for bad text or overflow; other runtime failures are never
  turned into Results.
- `try` has unary precedence. It evaluates one `Result[T]` operand once: on
  success it gives `T`; on error it returns the error from the current function.
  Only a function that returns `Result[...]` may use it (`CHECK-TRY-CONTEXT`
  otherwise). An expected type `T` gives the operand `Result[T]`; the return
  type alone does not. A success still needs an explicit `return ok(...)`.

```ruby
def read_age(text: String) -> Result[Int]
  age = try String.to_int(text)
  return ok(age)
end
```

### Function values

`f: Fn[Int, Int] = &double` refers to a declared function with exactly those
types, and `f.call(21)` invokes it. Function values can travel through lists,
maps, parameters, returns and fields. A bare function name is not a value.
Functions have no equality, fields, indexing or JSON encoding; `IO.inspect`
prints `<Fn>`.

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

[agentica-link-1]: ../../site/content/library/data-structures/range.md
[agentica-link-2]: ../../site/content/library/data-structures/set.md

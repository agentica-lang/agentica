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
| Names | A `?` (predicate) or `!` (version that halts the run) suffix on functions, only when followed by `(` |
| Library | Builtin modules `Map`, `List`, `String`, `IO`, and `System` |

Enums, `Result`, `Option`, interpolation, function values, JSON, networking, and other extensions are not part of the current language; they are in [`future.md`](future.md).

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
- The lexer emits one `NL` token per newline outside delimiters, except that it groups consecutive blank lines; a comment line produces its own `NL`. The parser ignores the extra `NL` tokens between declarations and statements.
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
def struct end if elsif else while for in return
true false nil and or not
```

Future extensions will introduce more reserved words; they are not available.

The `?` or `!` suffix is part of the `NAME` only when the next character is `(`: `contains?(`, `to_int!(`. So `a!=b` is still `a != b`, and `x?` or `x!` without parentheses are not names. By convention, `?` marks a predicate that returns `Bool`, and `!` marks the version that halts the run with an error instead of returning a `Result`. Variables, fields, and parameters cannot have the suffix.

The type and module names `Int`, `Float`, `Bool`, `String`, `Nil`, `List`, `Map`, `IO`, and `System` are reserved and cannot be redefined.

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

The parser allows type applications such as `List[Int]`. The checker restricts the core to primitive types, structs, `List[T]`, and `Map[K, V]`: a form being syntactically valid does not mean the type exists. There are no user-declared type parameters in the core.

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
unary_expr       = ( "-" | "not" ), unary_expr | postfix_expr ;
postfix_expr     = primary, { ".", NAME | "[", expression, "]" } ;

primary          = literal
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

Calls in the core are to named functions, and `user.method()` is not supported. `user.name`, `users[0]`, and `find_user(1).name` do fit the grammar.

`TYPE_NAME, ".", NAME, "(" … ")"` is a call to a function of a builtin module (`Map.put(...)`); the core has no user modules.

`and` and `or` short-circuit. Additions, subtractions, multiplications, divisions, and modulos group from left to right. Comparisons and equality checks do not chain: `a < b < c` is invalid; write `a < b and b < c`.

| Precedence, high to low | Operations |
|---|---|
| 1 | Named call, field `.`, index `[]`, grouping |
| 2 | Unary `-`, `not` |
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

List indexes must be between zero and length minus one; a negative or out-of-range index is an error. `for` iterates over `List[T]` in order. Slices and string indexing are not supported in the core.

### Maps

`Map[K, V]` associates keys with values. The key `K` can only be `Int` or `String`; `V` can be any type. `Map` takes exactly two type arguments.

```ruby
stock: Map[String, Int] = {"apple": 3, "pear": 0}
apples = stock["apple"]
more = Map.put(stock, "kiwi", 7)
```

- A literal uses braces and `key: value`; it allows several lines and a trailing comma. An empty `{}` needs an expected type, like `[]`.
- `m[key]` returns the value. The key must have type `K`. A missing key is a runtime error.
- If a literal repeats a key, the last one wins.
- Maps are immutable, like lists: there is no `m[key] = value`. `Map.put` returns a new map and leaves the original intact.
- There is no map equality and no `for` over a map; iterate with `Map.keys`, which returns the keys in insertion order.

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
List.size(list: List[T]) -> Int
```

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
String.to_int!(s: String) -> Int
String.to_float!(s: String) -> Float
```

The `IO` module writes and reads through the standard ports; `IO.warn` writes to standard error. `IO.inspect` prints any value in a stable debug form and returns it. `IO.gets` returns the next line without its terminator (LF, CR, or CRLF) and fails with `RUNTIME-END-OF-INPUT` at the end of input; `IO.eof?` lets you check first. The `System` module exposes the program arguments and ends the run with a code.

```text
IO.puts(value: String) -> Nil
IO.print(value: String) -> Nil
IO.warn(value: String) -> Nil
IO.inspect(value: T) -> T
IO.gets() -> String
IO.read() -> String
IO.eof?() -> Bool
System.args() -> List[String]
System.exit(code: Int) -> Nil
```

Files, JSON, networking, and richer conversions need a later API; see [`future.md`](future.md).

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
struct Task
  title: String
  done: Bool
end

def main() -> Nil
  tasks: List[Task] = [
    Task(title: "Probar Agentica", done: false),
    Task(title: "Revisar gramática", done: true)
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

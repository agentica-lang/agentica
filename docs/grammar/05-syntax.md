## 5. Core EBNF grammar

This is a descriptive grammar: it will be translated to the notation of the chosen tool. `{ X }` means zero or more repetitions, `[ X ]` means optional, and `|` expresses alternatives. Terminals appear in quotes; uppercase names are lexical tokens.

### File and declarations

```ebnf
program          = [ NL ], { declaration }, EOF ;
declaration      = function_decl | struct_decl | enum_decl | import_decl
                 | "export", ( function_decl | struct_decl | enum_decl ) ;
import_decl      = "import", STRING, "as", TYPE_NAME, NL ;

function_decl    = "def", NAME, "(", [ parameters ], ")",
                   "->", type, NL, block, "end", NL ;
parameters       = parameter, { ",", parameter }, [ "," ] ;
parameter        = NAME, ":", type ;

struct_decl      = "struct", TYPE_NAME, NL,
                   { field_decl }, "end", NL ;
field_decl       = NAME, ":", type, NL ;

enum_decl        = "enum", TYPE_NAME, [ type_parameters ], NL,
                   variant_decl, { variant_decl }, "end", NL ;
type_parameters  = "[", TYPE_NAME, { ",", TYPE_NAME }, "]" ;
variant_decl     = TYPE_NAME, [ "(", type, { ",", type }, ")" ], NL ;

qualified_type   = TYPE_NAME, [ ".", TYPE_NAME ] ;
type             = qualified_type, [ "[", type, { ",", type }, "]" ] ;
```

A function, struct or enum declaration (exported or not) must be followed by a blank line before the next declaration; a line with only a comment counts as blank. Otherwise the parser reports `PARSE-MISSING-BLANK-LINE` at the next declaration. Imports may follow each other directly; an import after a declaration also needs the blank line. Other text after a declaration's `end` (a stray `end` or statement) stays `PARSE-TOP-LEVEL-STATEMENT`.

The parser allows type applications such as `List[Int]` and `Option[String]`. The checker restricts applications to supported builtins and declared enums; only enum declarations may declare type parameters. Generic functions and generic structs are not supported.

Struct, enum, and function declarations appear only at the top level. There are no user methods, classes, inheritance, or nested functions; closures are written as blocks. Imports, exports and the `std/` modules are in "File modules and imports".


### Statements and blocks

```ebnf
block            = { statement } ;
statement        = simple_statement, NL
                 | if_statement
                 | case_statement
                 | while_statement
                 | for_statement ;

simple_statement = binding | compound_binding | return_statement | loop_control | expression ;
binding          = NAME, [ ":", type ], "=", expression ;
compound_binding = NAME, ( "+=" | "-=" | "*=" | "/=" | "%=" ), expression ;
return_statement = "return", [ expression ] ;
loop_control     = "break" | "next" ;

if_statement     = "if", expression, NL, block,
                   { "elsif", expression, NL, block },
                   [ "else", NL, block ], "end", NL ;
while_statement  = "while", expression, [ "do" ], NL, block, "end", NL ;
for_statement    = "for", NAME, "in", expression, [ "do" ], NL,
                   block, "end", NL ;
case_statement   = "case", expression, [ "do" ], NL,
                   match_arm, { match_arm }, "end", NL ;
match_arm        = pattern, "->", ( NL, block | simple_statement, NL, block ) ;
pattern          = "_" | literal | "-", INTEGER | "-", FLOAT
                 | qualified_variant, [ "(", pattern_bindings, ")" ]
                 | ( "ok" | "error" ), "(", pattern_bindings, ")" ;
qualified_variant = TYPE_NAME, ".", TYPE_NAME, [ ".", TYPE_NAME ] ;
pattern_bindings = pattern_binding, { ",", pattern_binding } ;
pattern_binding  = NAME | "_" ;
```

Assignments are statements: they do not produce a value. `if`, `while`, and `for` are not expressions either. `x += e` (also `-=`, `*=`, `/=`, `%=`) means `x = x op e`: the target is a plain name that is already visible and assignable, and the checker applies the same rules as the long form. `break` leaves the innermost `while` or `for`; `next` skips to its next iteration. Each stands alone as a statement; `break` and `next` are not reserved words, so a statement that is only one of them is loop control and they can still name variables. They are valid only inside a loop body of the same function or block: a block cannot break or skip its caller's loop, and a function cannot either (`CHECK-LOOP-CONTROL`). Inside a block, `return` leaves the block, like Ruby's `next`. There are no statement modifiers (`break if x`), no `continue`, and no assignment to fields or indexes.

### Expressions and precedence

```ebnf
expression       = or_expr, [ ( ".." | "..." ), or_expr ] ;
or_expr          = and_expr, { ( "or" | "||" ), and_expr } ;
and_expr         = equality_expr, { ( "and" | "&&" ), equality_expr } ;
equality_expr    = comparison_expr,
                   [ ( "==" | "!=" ), comparison_expr ] ;
comparison_expr  = additive_expr,
                   [ ( "<" | "<=" | ">" | ">=" ), additive_expr ] ;
additive_expr    = multiplicative_expr,
                   { ( "+" | "-" ), multiplicative_expr } ;
multiplicative_expr = unary_expr,
                   { ( "*" | "/" | "%" ), unary_expr } ;
unary_expr       = ( "-" | "not" | "!" | "try" ), unary_expr | postfix_expr ;
postfix_expr     = primary, { ".", NAME
                            | ".", NAME, "(", [ arguments ], ")"
                            | "[", expression, "]"
                            | block } ;
block            = "do", [ "|", block_param, { ",", block_param }, "|" ],
                   block_body, "end" ;
block_param      = NAME, [ ":", type ] ;
block_body       = NL, { statement } | simple_statement ;

primary          = literal
                 | "&", ( NAME | TYPE_NAME, ".", NAME )
                 | NAME, [ "(", [ arguments ], ")" ]
                 | TYPE_NAME, ".", TYPE_NAME, ".", TYPE_NAME, [ "(", [ arguments ], ")" ]
                 | TYPE_NAME, ".", TYPE_NAME, "(", [ arguments ], ")"
                 | qualified_type, "(", [ named_arguments ], ")"
                 | qualified_type
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

Calls are to named functions or function values via `.call(...)`; arbitrary user methods are not supported. `&name` references a declared top-level function without capturing variables; a block (see "Blocks and closures") captures them. `call` is not a reserved word. `user.name`, `users[0]`, and `find_user(1).name` also fit the grammar. A bare `gets` or `gets!` is a call with no arguments. A bare `qualified_type` of the form `Enum.Variant`, where `Enum` is an enum of the same file, is that nullary variant; `M.Enum.Variant` without parentheses is one through an import alias. `Result.Ok(...)` and `Result.Err(...)` are the `ok`/`error` calls. `puts`, `print`, `gets` and `gets!` cannot name variables, parameters, loop variables or pattern bindings (`CHECK-REDEFINED-NAME`).

`TYPE_NAME, ".", NAME, "(" … ")"` calls a builtin module function (`Map.put(...)`) or an exported function through an import alias. Without arguments the parentheses may be dropped: `IO.gets!` is `IO.gets!()`, and `while !IO.eof? do` reads like Ruby. This holds for imported functions too: `f = Util.helper` calls `helper`; write `&Util.helper` for the function value.

`a..b` and `a...b` build a `Range` (see "Ranges"). They have the lowest precedence and do not chain: `0...n + 1` is `0...(n + 1)`, and `1..2..3` is `PARSE-UNEXPECTED-TOKEN` at the second operator. `x = 0...n`, `f(0..n)` and `for i in 0...n` need no parentheses; a method call does: `(1..5).to_a`. A line that ends in `..` or `...` does not continue on the next line. `1..5` lexes as two integers around `..`, never as a Float.

`and` and `or` short-circuit. Additions, subtractions, multiplications, divisions, and modulos group from left to right. Comparisons and equality checks do not chain: `a < b < c` is invalid; write `a < b and b < c`.

| Precedence, high to low | Operations |
|---|---|
| 1 | Named call, field `.`, index `[]`, grouping |
| 2 | Unary `-`, `not` / `!`, `try` |
| 3 | `*`, `/`, `%` |
| 4 | `+`, `-` |
| 5 | `<`, `<=`, `>`, `>=` |
| 6 | `==`, `!=` |
| 7 | `and` / `&&` |
| 8 | `or` / `\|\|` |
| 9 | `..`, `...` (not associative) |

`not` has high precedence: to negate a comparison, write `not (age >= 18)`.

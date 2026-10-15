## 5. Core EBNF grammar

This is a descriptive grammar. `{ X }` means zero or more repetitions, `[ X ]` means optional, and `|` expresses alternatives. Terminals appear in quotes; uppercase names are lexical tokens.

### File and declarations

```ebnf
program          = [ NL ], [ module_doc ], { declaration }, EOF ;
module_doc       = DOC, NL, NL ;
declaration      = import_decl
                 | [ DOC, NL ], ( function_decl | struct_decl | enum_decl
                 | "export", ( function_decl | struct_decl | enum_decl ) ) ;
import_decl      = "import", STRING, "as", TYPE_NAME, NL ;

function_decl    = "def", NAME, "(", [ parameters ], ")",
                   "->", type, NL, block, "end", NL ;
parameters       = parameter, { ",", parameter }, [ "," ] ;
parameter        = NAME, ":", type ;

struct_decl      = "struct", TYPE_NAME, NL,
                   { field_decl }, "end", NL ;
field_decl       = [ DOC, NL ], NAME, ":", type, NL ;

enum_decl        = "enum", TYPE_NAME, [ type_parameters ], NL,
                   variant_decl, { variant_decl }, "end", NL ;
type_parameters  = "[", TYPE_NAME, { ",", TYPE_NAME }, "]" ;
variant_decl     = [ DOC, NL ], TYPE_NAME, [ "(", type, { ",", type }, ")" ], NL ;

qualified_type   = TYPE_NAME, [ ".", TYPE_NAME ] ;
type             = qualified_type, [ "[", type, { ",", type }, "]" ] ;
```

A function, struct or enum declaration, exported or not, needs a blank line before the next declaration; a line with only a comment counts, but a doc line does not, because it belongs to the declaration after it: the blank line goes before the doc block. Otherwise `PARSE-MISSING-BLANK-LINE` is reported at the next declaration, or at the first line of its doc block. Imports may follow each other directly, but an import after a declaration also needs the blank line. Other text after a declaration's `end` is `PARSE-TOP-LEVEL-STATEMENT`.

A doc block (a `DOC` token, section 4) documents what comes on the next line: a `def`, `struct` or `enum` declaration, with or without `export`, a field inside a `struct`, or a variant inside an `enum`. The first doc block of a file is the module doc when only blank lines and ordinary `#` comment lines come before it and a blank line follows it; a `#` comment line right after it does not count as that blank line. A file has at most one module doc. Any other doc block is `PARSE-DETACHED-DOC`, reported at its first line: a block followed by a blank line (other than the module doc), by a `#` comment line, by an `import`, or by the end of the file, a block inside a function body, and a block inside `(...)`, `[...]` or `{...}`. Docs are optional and have no effect when the program runs.

```ruby
## Adds two numbers.
def add(a: Int, b: Int) -> Int
  return a + b
end
```

Struct, enum and function declarations appear only at the top level. There are no user methods, classes, inheritance or nested functions; closures are blocks (§6). The parser accepts type applications such as `List[Int]`. The checker allows them only for supported builtins and declared enums, and only enums take type parameters: generic functions and generic structs are not supported.

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

Assignments, `if`, `while` and `for` are statements, not expressions. `x += e` (also `-=`, `*=`, `/=`, `%=`) means `x = x op e`, with the same checks as the long form.

`break` leaves the innermost `while` or `for`; `next` skips to its next iteration. Both are `CHECK-LOOP-CONTROL` outside a loop of the same function or block: a block cannot break or skip its caller's loop. Inside a block, `return` leaves the block. There are no statement modifiers (`break if x`), no `continue`, and no assignment to fields or indexes.

### Expressions and precedence

```ebnf
expression       = or_expr, [ ( ".." | "..." ), or_expr ] ;
or_expr          = and_expr, { ( "or" | "||" ), and_expr } ;
and_expr         = equality_expr, { ( "and" | "&&" ), equality_expr } ;
equality_expr    = comparison_expr,
                   [ ( "==" | "!=" ), comparison_expr ] ;
comparison_expr  = pipe_expr,
                   [ ( "<" | "<=" | ">" | ">=" ), pipe_expr ] ;
pipe_expr        = additive_expr, { "|>", pipe_target } ;
pipe_target      = [ "try" ], call_with_parentheses ;
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

Calls are to named functions, or to function values through `.call(...)`; there are no user methods. Parentheses are required for every call. They may be dropped only for builtin methods, and for module functions without arguments, builtin or reached through an import alias: `s.length`, `IO.gets!`, `while !IO.eof? do`, `Util.reset`. So `f = Util.helper` calls `helper`; write `&Util.helper` for the function value. `&name` references a declared top-level function without captures. A bare `Enum.Variant` of an enum in the same file is that nullary variant, and `M.Enum.Variant` through an import alias is one too.

`x |> f(a, b)` means `f(x, a, b)`: the left value becomes the first argument of the call on the right. The right side is a call with parentheses, `name(args)` or `Alias.name(args)` (a user function, an imported function or a builtin), optionally preceded by `try`: `x |> try f(a)` is `try f(x, a)`. A trailing block works: `xs |> each_pair() do |a, b| ... end`. Anything else on the right (a bare name, a field, an index, a method chain such as `f(1).g`, a literal) is `PARSE-PIPE-TARGET` at the right side; wrap the expression in parentheses and use `.` on the result, as in `(x |> f()).unwrap!`. A builtin that has a method form for the type of the left value is `CHECK-PIPE-METHOD` at the right side, with the method form as help: `x |> String.trim()` gives `x.trim`. So `|>` is for user functions and for builtins without a method form, and the two styles mix: `s.trim |> try parse() |> try validate()`. `|>` binds lower than `+` and `-` and higher than the comparisons, and groups from left to right: `a + 1 |> f()` is `f(a + 1)`, `x |> f() == y` is `f(x) == y`, and `x |> f() |> g()` is `g(f(x))`. `try` and unary operators bind tighter: `try x |> f()` is `f(try x)`. The call keeps its normal order of evaluation (the left value first, then the other arguments) and its normal diagnostics: the piped argument's span is the left expression's span. A chain over several lines goes in parentheses, one step per line.

`a..b` and `a...b` have the lowest precedence and do not chain: `1..2..3` is `PARSE-UNEXPECTED-TOKEN` at the second operator, and `0...n + 1` is `0...(n + 1)`. A method on a range needs parentheses: `(1..5).to_a`. `1..5` lexes as two integers. A line that ends in `..` or `...` does not continue on the next line.

`and` and `or` short-circuit. Operators group from left to right, except that comparisons and equality do not chain: `a < b < c` is invalid. From high to low, the precedence is: named call, field, index and grouping; unary `-`, `not`, `!` and `try`; `*`, `/`, `%`; `+`, `-`; `|>`; comparisons; equality; `and`; `or`; ranges. `not` binds tighter than comparisons, so to negate one, write `not (age >= 18)`.

Nesting is limited to 1,000 levels (`PARSE-TOO-DEEP`, at the token that passes the limit). Each statement, expression, prefix operator (`-`, `not`, `!`, `try`) and type counts one level inside the one around it, and so does each operator of a chain (`a + b + c`, `x |> f() |> g()`) and each `.name`, `[index]` or `do` block after a primary (`a.b.c`). Real programs stay far below it; it keeps the parser and the passes after it inside the VM call limit of 10,000.

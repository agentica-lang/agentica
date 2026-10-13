## 5. Core EBNF grammar

This is a descriptive grammar. `{ X }` means zero or more repetitions, `[ X ]` means optional, and `|` expresses alternatives. Terminals appear in quotes; uppercase names are lexical tokens.

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

A function, struct or enum declaration, exported or not, needs a blank line before the next declaration; a line with only a comment counts. Otherwise `PARSE-MISSING-BLANK-LINE` is reported at the next declaration. Imports may follow each other directly, but an import after a declaration also needs the blank line. Other text after a declaration's `end` is `PARSE-TOP-LEVEL-STATEMENT`.

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

Calls are to named functions, or to function values through `.call(...)`; there are no user methods. Parentheses are required for every call. They may be dropped only for builtin methods, and for module functions without arguments, builtin or reached through an import alias: `s.length`, `IO.gets!`, `while !IO.eof? do`, `Util.reset`. So `f = Util.helper` calls `helper`; write `&Util.helper` for the function value. `&name` references a declared top-level function without captures. A bare `Enum.Variant` of an enum in the same file is that nullary variant, and `M.Enum.Variant` through an import alias is one too.

`a..b` and `a...b` have the lowest precedence and do not chain: `1..2..3` is `PARSE-UNEXPECTED-TOKEN` at the second operator, and `0...n + 1` is `0...(n + 1)`. A method on a range needs parentheses: `(1..5).to_a`. `1..5` lexes as two integers. A line that ends in `..` or `...` does not continue on the next line.

`and` and `or` short-circuit. Operators group from left to right, except that comparisons and equality do not chain: `a < b < c` is invalid. From high to low, the precedence is: named call, field, index and grouping; unary `-`, `not`, `!` and `try`; `*`, `/`, `%`; `+`, `-`; comparisons; equality; `and`; `or`; ranges. `not` binds tighter than comparisons, so to negate one, write `not (age >= 18)`.

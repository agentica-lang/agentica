## 5. Core EBNF grammar

This is a descriptive grammar. `{ X }` means zero or more repetitions, `[ X ]`
means optional, and `|` expresses alternatives. Terminals appear in quotes;
uppercase names are lexical tokens.

### File and declarations

```ebnf
program          = [ NL ], [ module_doc ], { declaration }, EOF ;
module_doc       = DOC, NL, NL ;
declaration      = import_decl
                 | [ DOC, NL ], ( constant_decl | function_decl | struct_decl | enum_decl | alias_decl
                 | "export", ( function_decl | struct_decl | enum_decl | alias_decl ) ) ;
constant_decl    = [ "export" ], CONST_NAME, [ ":", type ], "=", expression, NL ;
import_decl      = "import", ( TYPE_NAME | name_list ), "from", STRING, NL ;
name_list        = "{", import_name, { ",", import_name }, [ "," ], "}" ;
import_name      = ( NAME | TYPE_NAME ), [ "as", ( NAME | TYPE_NAME ) ] ;

function_decl    = "def", NAME, "(", [ parameters ], ")",
                   "->", type, NL, block, "end", NL ;
parameters       = parameter, { ",", parameter }, [ "," ] ;
parameter        = NAME, ":", type, [ "=", expression ] ;

struct_decl      = "struct", TYPE_NAME, NL,
                   { field_decl }, "end", NL ;
field_decl       = [ DOC, NL ], NAME, ":", type, NL ;

enum_decl        = "enum", TYPE_NAME, [ type_parameters ], NL,
                   variant_decl, { variant_decl }, "end", NL ;
alias_decl       = "type", TYPE_NAME, "=", type, NL ;
type_parameters  = "[", TYPE_NAME, { ",", TYPE_NAME }, "]" ;
variant_decl     = [ DOC, NL ], TYPE_NAME, [ "(", type, { ",", type }, ")" ], NL ;

qualified_type   = TYPE_NAME, [ ".", TYPE_NAME ] ;
type             = qualified_type, [ "[", type, { ",", type }, "]" ] ;
```

A parameter may end with a default value, `NAME: type = expression`. The parser
takes any expression after `=`, so that the checker can say why a default is not
allowed; the rules are in section 6, "Default parameter values". A block
parameter (`do |x|`) takes no default.

An import is one of two forms. `import Util from "util"` gives the file the
alias `Util`. `import {area, Square as Sq} from "shapes"` brings exported names
into the file, each with an optional new name after `as`, and the list may span
lines, may end with a comma, and may not be empty. `from` and `as` are not
reserved words: the parser reads them by their text at those two places, so a
parameter or a function called `from` or `as` still works, and `{as}` imports a
function called `as`. One line does one thing: `import Util, {area} from "util"`
is `PARSE-UNEXPECTED-TOKEN` at the comma. Writing the path first (the form of
earlier versions) is `PARSE-UNEXPECTED-TOKEN` at the string, with the help
`write import Alias from "path"`. What each form means is in section 5b.

A function, struct, enum or type alias declaration, exported or not, needs a
blank line before the next declaration; a line with only a comment counts, but a
doc line does not, because it belongs to the declaration after it: the blank
line goes before the doc block. Otherwise `PARSE-MISSING-BLANK-LINE` is reported
at the next declaration, or at the first line of its doc block. Imports may
follow each other directly, but an import after a declaration also needs the
blank line. A constant follows the imports, and another constant, with no blank
line, also when the next constant has a doc block or `export`; the blank line is
still needed between a constant and a `struct`, `enum`, type alias or `def`, and
before an import. Other text after a declaration's `end` is
`PARSE-TOP-LEVEL-STATEMENT`.

Declarations follow a fixed order in every file, the root program, imported
files and embedded `std/` modules alike: the module doc and the imports first,
then the constants, then `struct`, `enum` and type alias declarations (exported
or not, in any order among themselves), then `export def` functions, then
private `def` functions. A type alias uses `type Name = Type`; `type` is
contextual here and remains an ordinary name elsewhere. The order is a style
rule only: a function may still call a function, use a struct declared later or
read a constant in the same group. The first declaration that comes after a
declaration of a later group is `CHECK-DECL-ORDER`, reported at the start of
that declaration (at `export` or `import` when it has one), with help that says
where it goes. The module linker checks it for each file before linking, so a
file with a parse error reports `PARSE-` first and a file that imports another
reports its own order first.

A constant is `NAME = expression` or `NAME: Type = expression` at the top level,
with `export` in front to make it visible to importers. `NAME` is a `TYPE_NAME`
token whose text is `UPPER_SNAKE_CASE`: capital letters, digits and `_`,
starting with a capital letter, at least two characters. Any other name (`Limit
= 1`, `X = 1`) is `PARSE-CONSTANT-NAME` at the name, with the closest constant
name as help when there is one. The built-in all-capitals names (`IO`, `JSON`,
`TCP`, `TLS`) are reserved type names and cannot be constants. The type is
optional: `NAME = expression` takes the type of the expression, and `NAME: Type
= expression` checks it against `Type` and gives `[]`, `{}` and `Set.new([])`
the type they need, as for a local. The value is one expression that starts on
the line of the `=`; it may span lines inside brackets or a `do ... end` block.
What the expression may contain and how a constant is read are in section 6.

A doc block (a `DOC` token, section 4) documents what comes on the next line: a
`def`, `struct`, `enum`, type alias or constant declaration, with or without
`export`, a field inside a `struct`, or a variant inside an `enum`. The first
doc block of a file is the module doc when only blank lines and ordinary `#`
comment lines come before it and a blank line follows it; a `#` comment line
right after it does not count as that blank line. A file has at most one module
doc. Any other doc block is `PARSE-DETACHED-DOC`, reported at its first line: a
block followed by a blank line (other than the module doc), by a `#` comment
line, by an `import`, or by the end of the file, a block inside a function body,
and a block inside `(...)`, `[...]` or `{...}`. Docs are optional and have no
effect when the program runs.

```ruby
## Adds two numbers.
def add(a: Int, b: Int) -> Int
  return a + b
end
```

Struct, enum, type alias and function declarations appear only at the top level.
A type alias is transparent: `type Grid = List[List[Float]]` means exactly
`List[List[Float]]`, with no new runtime type or conversion. Aliases may name
builtin, struct, enum and function types, and other aliases; cycles are
`CHECK-TYPE-ALIAS-CYCLE`. The parser accepts type applications such as
`List[Int]`. The checker allows them only for supported builtins and declared
enums; only enums take type parameters, so generic functions, structs and
aliases are not supported yet.

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
match_arm        = pattern, [ "if", expression ], "->",
                   ( NL, block | simple_statement, NL, block ) ;
pattern          = "_" | literal | "-", INTEGER | "-", FLOAT
                 | variant_pattern ;
variant_pattern  = qualified_variant, [ "(", pattern_slots, ")" ]
                 | ( "ok" | "error" ), "(", pattern_slots, ")" ;
qualified_variant = TYPE_NAME, ".", TYPE_NAME, [ ".", TYPE_NAME ] ;
pattern_slots    = pattern_slot, { ",", pattern_slot } ;
pattern_slot     = NAME | "_" | literal | "-", INTEGER | "-", FLOAT
                 | variant_pattern ;
```

Assignments, `if`, `while` and `for` are statements, not expressions. `x += e`
(also `-=`, `*=`, `/=`, `%=`) means `x = x op e`, with the same checks as the
long form.

`break` leaves the innermost `while` or `for`; `next` skips to its next
iteration. Both are `CHECK-LOOP-CONTROL` outside a loop of the same function or
block: a block cannot break or skip its caller's loop. Inside a block, `return`
leaves the block. There are no statement modifiers (`break if x`), no
`continue`, and no assignment to fields or indexes.

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
                            | ".", "with", "(", named_arguments, ")"
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

Calls are to named functions, or to function values through `.call(...)`; there
are no user methods. Parentheses are required for every call. They may be
dropped only for builtin methods, and for module functions without arguments,
builtin or reached through an import alias: `s.length`, `IO.gets!`, `while
!IO.eof? do`, `Util.reset`. So `f = Util.helper` calls `helper`; write
`&Util.helper` for the function value. `&name` references a declared top-level
function without captures. A bare `Enum.Variant` of an enum in the same file is
that nullary variant, and `M.Enum.Variant` through an import alias is one too.

A struct update `value.with(name: expr, ...)` is the one postfix form with named
arguments, and it needs at least one. `with` is not a reserved word: it has this
meaning only after a `.` and before `(`, so `value.with` without parentheses
still reads a field named `with`, and `Alias.with(...)` (an import alias before
the dot) is a call of the module's function `with`. `user.with()` and a
positional value such as `user.with(31)` are `PARSE-UNEXPECTED-TOKEN`, with help
that shows the form: `value.with(age: 31)`. Like a call, the update is a link of
a chain (`a.with(x: 1).with(y: 2)`), and a `do` block cannot follow it.

`x |> f(a, b)` means `f(x, a, b)`: the left value becomes the first argument of
the call on the right. The right side is a call with parentheses, `name(args)`
or `Alias.name(args)` (a user function, an imported function or a builtin),
optionally preceded by `try`: `x |> try f(a)` is `try f(x, a)`. A trailing block
works: `xs |> each_pair() do |a, b| ... end`. Anything else on the right (a bare
name, a field, an index, a method chain such as `f(1).g`, a literal) is
`PARSE-PIPE-TARGET` at the right side; wrap the expression in parentheses and
use `.` on the result, as in `(x |> f()).unwrap!`. A builtin that has a method
form for the type of the left value is `CHECK-PIPE-METHOD` at the right side,
with the method form as help: `x |> String.trim()` gives `x.trim`. So `|>` is
for user functions and for builtins without a method form, and the two styles
mix: `s.trim |> try parse() |> try validate()`. `|>` binds lower than `+` and
`-` and higher than the comparisons, and groups from left to right: `a + 1 |>
f()` is `f(a + 1)`, `x |> f() == y` is `f(x) == y`, and `x |> f() |> g()` is
`g(f(x))`. `try` and unary operators bind tighter: `try x |> f()` is `f(try x)`.
The call keeps its normal order of evaluation (the left value first, then the
other arguments) and its normal diagnostics: the piped argument's span is the
left expression's span. A chain over several lines goes in parentheses, one step
per line.

`a..b` and `a...b` have the lowest precedence and do not chain: `1..2..3` is
`PARSE-UNEXPECTED-TOKEN` at the second operator, and `0...n + 1` is `0...(n +
1)`. A method on a range needs parentheses: `(1..5).to_a`. `1..5` lexes as two
integers. A line that ends in `..` or `...` does not continue on the next line.

`and` and `or` short-circuit. Operators group from left to right, except that
comparisons and equality do not chain: `a < b < c` is invalid. From high to low,
the precedence is: named call, field, index and grouping; unary `-`, `not`, `!`
and `try`; `*`, `/`, `%`; `+`, `-`; `|>`; comparisons; equality; `and`; `or`;
ranges. `not` binds tighter than comparisons, so to negate one, write `not (age
>= 18)`.

Nesting is limited to 1,000 levels (`PARSE-TOO-DEEP`, at the token that passes
the limit). Each statement, expression, prefix operator (`-`, `not`, `!`, `try`)
and type counts one level inside the one around it. So does each operator of a
chain (`a + b + c`, `x |> f() |> g()`) and each `.name`, `[index]` or `do` block
after a primary (`a.b.c`): what follows the k-th operator or suffix of a chain
(its right operand, its arguments, its block) starts k levels deeper than the
chain. Real programs stay far below it; it keeps the parser inside the VM call
limit of 10,000. The checker has its own limit on the depth of the tree: more
than 1,000 levels of expressions and statements, one level for each, is
`CHECK-TOO-DEEP` at the node that passes the limit. It also stops an alias
expansion after 1,000 type references with the same code, so repeated aliases
cannot grow exponentially. A chain of operators is as deep as it is long, and
the parser counts the right operand of the first operator of a chain as one more
level only, so a nested chain passes the parser and stops in the checker.

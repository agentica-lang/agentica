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
- The lexer emits one `NL` token for each LF or CRLF outside delimiters, including blank and comment lines. Inside a block (`do ... end`, also `if`, `while`, `for`, `def`) that is itself within `(...)`, `[...]` or `{...}`, newlines are emitted too, so a multi-line block can be an argument. The parser ignores extra `NL` tokens between declarations and statements.
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
def struct enum case do import export end if elsif else while for in return try
true false nil and or not
```

Future extensions will introduce more reserved words; they are not available.

A trailing `?` or `!` is part of a lowercase `NAME`, regardless of the next parenthesis or whitespace: `contains? (s, part)` is valid. `!` is not a suffix when followed by `=`, so `a!=b` still means `a != b`. By convention, `?` marks a predicate that returns `Bool`, and `!` marks the version that halts the run with an error instead of returning a `Result`. Variables, fields, and parameters cannot have the suffix.

The type and module names `Int`, `Float`, `Bool`, `String`, `Nil`, `Void`, `Process`, `List`, `Map`, `Result`, `Range`, `IO`, and `System` are reserved and cannot be redefined. `ok` and `error` remain NAME tokens, but cannot be declared as user functions, variables, parameters, loop variables, or fields (`CHECK-REDEFINED-NAME`).

### Literals

```ebnf
NAME       = LOWER_OR_UNDERSCORE, { LETTER | DIGIT | "_" }, [ "?" | "!" ] ;
TYPE_NAME  = UPPER, { LETTER | DIGIT | "_" } ;
INTEGER    = DIGIT, { DIGIT } ;
FLOAT      = DIGIT, { DIGIT }, ".", DIGIT, { DIGIT } ;
STRING     = '"', { STRING_CHAR | ESCAPE | INTERPOLATION }, '"' ;
ESCAPE     = "\\", ( '"' | "\\" | "#" | "n" | "r" | "t" ) ;
INTERPOLATION = "#{", expression, "}" ;
```

`LETTER` is `A`–`Z` or `a`–`z`; `DIGIT`, `0`–`9`; `LOWER_OR_UNDERSCORE`, `a`–`z` or `_`; `UPPER`, `A`–`Z`. `STRING_CHAR` is any Unicode character except double quotes, backslash, newlines, and a `#` followed by `{`. `NL` and `EOF` are tokens produced by the lexer.

The minus sign is an operator, not part of the literal. The core has no exponents, alternative bases, numeric separators, or multiline strings.

`"text #{expression} text"` interpolates: the result is a `String`. Each value is inserted as its `to_s` (see "Methods on builtin types"): a `String` as is, a `Json` as its JSON text, any other data value in its `IO.inspect` form (`7`, `2.5`, `true`, `nil`, `[1, 2]`, `Item(name: "a")`). A Void call is `CHECK-VOID-VALUE`; a function, task or resource handle has no `to_s` and is `CHECK-TYPE-MISMATCH`. The expression must end on the same line and cannot contain comments; strings, maps and nested interpolation may appear inside it. `\#` writes a literal `#`, so `"\#{x}"` is the text `#{x}`. A `#` not followed by `{` is plain text. `case` patterns and `import` paths take plain string literals only.


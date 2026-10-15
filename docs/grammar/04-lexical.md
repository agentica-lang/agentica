## 4. Lexical conventions

- The file is UTF-8; core identifiers use ASCII characters.
- A comment starts with `#` and ends at the end of the line. The newline after it is kept.
- A line whose first non-blank characters are `##` is a doc line (see "Doc comments" below), not an ordinary comment.
- Names of variables, functions and fields start with a lowercase letter or `_`. Type names start with an uppercase letter. Identifiers are case-sensitive.
- Spaces, tabs and indentation have no structural meaning. CRLF is read as LF.
- A newline separates statements, except inside `(...)`, `[...]` and `{...}`.
- The lexer emits one `NL` token for each newline outside those delimiters, including blank and comment lines. Inside a block that is itself within `(...)`, `[...]` or `{...}`, newlines are emitted too, so a multi-line block can be an argument. The parser ignores extra `NL` tokens between declarations and statements.
- If the file does not end with a newline, the lexer adds one before `EOF`.
- `;`, backslash continuation and implicit continuation after an operator are not supported. Wrap a long expression in parentheses. Inside lists and calls, use several lines and a trailing comma.

```ruby
total = (
  base +
  extra
)
```

Reserved words of the core, which cannot be used as identifiers:

```text
def struct enum case do import export end if elsif else while for in return try
true false nil and or not
```

`break` and `next` are not reserved words: they can name variables, and as statements they are loop control.

Reserved builtin names cannot be declared as functions, types, variables, import aliases or module names: `Int`, `Float`, `Bool`, `String`, `Nil`, `Void`, `List`, `Map`, `Set`, `Result`, `Range`, `Fn`, `Json`, `JSON`, `Task`, `Await`, `Channel`, `Process`, `ProcessOutput`, `IO`, `System`, `Time`, `Random`, `Test`, `TestCase`, `File`, `Dir`, `Path`, `FileHandle`, `FileInfo`, `TCP`, `TLS`, `HttpWire`, `LogRegistry`, `LogEvent`, `LogLevel`, `Socket`, `Listener`, `HttpClient`, `HttpServer`, `Header`, `HttpRequest`, `HttpResponse`, `HttpClientOptions` and `HttpServerOptions`. `HTTP` is not reserved: it is the usual alias of `std/http`. `ok` and `error` are names, but cannot be declared as functions, variables, parameters, loop variables or fields (`CHECK-REDEFINED-NAME`). The same holds for `puts`, `print`, `gets` and `gets!` as variables, parameters, loop variables and pattern bindings.

A trailing `?` or `!` belongs to a lowercase name, whatever follows it: `contains? (s, part)` is valid. `!` is not a suffix before `=`, so `a!=b` is `a != b`. By convention `?` marks a predicate that returns `Bool`, and `!` marks the form that halts the run with an error instead of returning a `Result`. Variables, fields and parameters cannot have the suffix.

The pipe operator `|>` is one token (the longest match next to `|` and `||`), so block parameters `do |x|` and `||` are unchanged. It does not continue a line: a chain over several lines goes in parentheses (see section 5).

### Doc comments

A **doc line** is a line whose first non-blank characters are `##`. Its text is the rest of the line after `##` and one optional space. `##` alone is an empty doc line, which separates paragraphs. Only the first two `#`s are the marker: `### Heading` is a doc line whose text is `# Heading`. A `##` after code on the same line (`x = 1 ## note`) is an ordinary comment, and `##` inside a string literal or an interpolation is text.

A **doc block** is one or more consecutive doc lines. A blank line or an ordinary `#` comment line ends the block. The lexer emits one `DOC` token for each block, with its lines joined by newlines as the text and the span of the whole block. The newline after the block is an `NL`, as after any other line. Inside `(...)`, `[...]` and `{...}`, where no `NL` is emitted, the `DOC` token is still emitted, and the parser rejects it (`PARSE-DETACHED-DOC`).

```ebnf
DOC_LINE   = { " " | TAB }, "##", [ " " ], { ANY_BUT_NEWLINE } ;
DOC        = DOC_LINE, { NL, DOC_LINE } ;
```

`TAB` is the tab character, and `ANY_BUT_NEWLINE` is any character except a line feed or carriage return.

The text is CommonMark. Section 5 says where a doc block may stand and what it documents.

### Literals

```ebnf
NAME       = LOWER_OR_UNDERSCORE, { LETTER | DIGIT | "_" }, [ "?" | "!" ] ;
TYPE_NAME  = UPPER, { LETTER | DIGIT | "_" } ;
INTEGER    = DIGIT, { [ "_" ], DIGIT } ;
FLOAT      = DIGIT, { [ "_" ], DIGIT }, ".", DIGIT, { [ "_" ], DIGIT } ;
STRING     = '"', { STRING_CHAR | ESCAPE | INTERPOLATION }, '"' ;
ESCAPE     = "\\", ( '"' | "\\" | "#" | "n" | "r" | "t" ) ;
INTERPOLATION = "#{", expression, "}" ;
```

`LETTER` is `A`–`Z` or `a`–`z`; `DIGIT` is `0`–`9`; `LOWER_OR_UNDERSCORE` is `a`–`z` or `_`; `UPPER` is `A`–`Z`. `STRING_CHAR` is any Unicode character except double quotes, backslash, newlines, and a `#` followed by `{`. `NL`, `DOC` and `EOF` are lexer tokens.

The minus sign is an operator, not part of a literal. The core has no exponents, other number bases or multiline strings.

A `_` may separate digits in `INTEGER` and in both parts of `FLOAT`: `1_000`, `1_000.000_5`. It is only visual: `1_000` is the same `Int` as `1000`, and the lexer drops the `_`s before it reads the value. `_` is allowed only between two digits. A trailing `_` (`1_`, `1_000_`, `1_a`), a double `__` (`1__0`) and a `_` next to the dot (`1_.5`, `1._5`) are `LEX-INVALID-NUMBER`, with the literal as written as the span: the run of digits and `_`, plus a `.` followed by a digit or a `_` and the run after it. A `.` followed by a `_` belongs to the number, so `1._5` is an error; a `.` followed by a letter or by another `.` ends the number (`1_000.times`, `1_000..2_000`). `_1` is still a NAME. The text form of a number has no separators: `puts(1_000)` prints `1000`, and `String.to_int` and JSON still reject `_`.

`"text #{expression} text"` interpolates; the result is a `String`. Each value is inserted as its `to_s` (see "Methods on builtin types"). The expression must end on the same line and cannot contain comments; strings, maps and nested interpolation may appear inside it. A Void call is `CHECK-VOID-VALUE`. A function, task or resource handle has no `to_s` and is `CHECK-TYPE-MISMATCH`. `\#` writes a literal `#`, so `"\#{x}"` is the text `#{x}`. `case` patterns and `import` paths take plain string literals only.

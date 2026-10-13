## 4. Lexical conventions

- The file is UTF-8; core identifiers use ASCII characters.
- A comment starts with `#` and ends at the end of the line. The newline after it is kept.
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

Reserved builtin names cannot be declared as functions, types, variables, import aliases or module names: `Int`, `Float`, `Bool`, `String`, `Nil`, `Void`, `List`, `Map`, `Result`, `Range`, `Fn`, `Json`, `JSON`, `Task`, `Process`, `ProcessOutput`, `IO`, `System`, `Time`, `Random`, `Test`, `TestCase`, `File`, `Dir`, `Path`, `FileHandle`, `FileInfo`, `TCP`, `TLS`, `HttpWire`, `Socket`, `Listener`, `HttpClient`, `HttpServer`, `Header`, `HttpRequest`, `HttpResponse`, `HttpClientOptions` and `HttpServerOptions`. `HTTP` is not reserved: it is the usual alias of `std/http`. `ok` and `error` are names, but cannot be declared as functions, variables, parameters, loop variables or fields (`CHECK-REDEFINED-NAME`). The same holds for `puts`, `print`, `gets` and `gets!` as variables, parameters, loop variables and pattern bindings.

A trailing `?` or `!` belongs to a lowercase name, whatever follows it: `contains? (s, part)` is valid. `!` is not a suffix before `=`, so `a!=b` is `a != b`. By convention `?` marks a predicate that returns `Bool`, and `!` marks the form that halts the run with an error instead of returning a `Result`. Variables, fields and parameters cannot have the suffix.

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

`LETTER` is `A`–`Z` or `a`–`z`; `DIGIT` is `0`–`9`; `LOWER_OR_UNDERSCORE` is `a`–`z` or `_`; `UPPER` is `A`–`Z`. `STRING_CHAR` is any Unicode character except double quotes, backslash, newlines, and a `#` followed by `{`. `NL` and `EOF` are lexer tokens.

The minus sign is an operator, not part of a literal. The core has no exponents, other number bases, numeric separators or multiline strings.

`"text #{expression} text"` interpolates; the result is a `String`. Each value is inserted as its `to_s` (see "Methods on builtin types"). The expression must end on the same line and cannot contain comments; strings, maps and nested interpolation may appear inside it. A Void call is `CHECK-VOID-VALUE`. A function, task or resource handle has no `to_s` and is `CHECK-TYPE-MISMATCH`. `\#` writes a literal `#`, so `"\#{x}"` is the text `#{x}`. `case` patterns and `import` paths take plain string literals only.

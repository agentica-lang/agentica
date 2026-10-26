## 4. Lexical conventions

- The file is UTF-8; core identifiers use ASCII characters. A source file has no
  size limit. Bytes that are not valid UTF-8 (a stray continuation byte, an
  overlong form, a surrogate, a code point above U+10FFFF, a sequence cut short,
  also at the end of the file) are `LEX-INVALID-UTF8`, in the file that has
  them, whether it is the root file or an imported one. The span is one
  character long and starts at the first byte of the first sequence that does
  not decode, at the line and column of the characters before it. The text is
  never repaired with replacement characters.
- A comment starts with `#` and ends at the end of the line. The newline after
  it is kept.
- A line whose first non-blank characters are `##` is a doc line (see "Doc
  comments" below), not an ordinary comment.
- Names of variables, functions and fields start with a lowercase letter or `_`.
  Type names start with an uppercase letter. Identifiers are case-sensitive.
- Spaces, tabs and indentation have no structural meaning. CRLF is read as LF.
- A newline separates statements, except inside `(...)`, `[...]` and `{...}`,
  and before a line that starts with `.name` (see below).
- The lexer emits one `NL` token for each newline outside those delimiters,
  including blank and comment lines. Inside a block that is itself within
  `(...)`, `[...]` or `{...}`, newlines are emitted too, so a multi-line block
  can be an argument. The parser ignores extra `NL` tokens between declarations
  and statements.
- If the file does not end with a newline, the lexer adds one before `EOF`.
- A line whose first token is a `.` followed by a lowercase name (`.map`,
  `.with(`; not `.Type` or a number) continues the expression of the line
  before: the lexer drops the `NL` that ends that line, so a method chain can
  span lines without parentheses. The line before must end in a token that can
  end an expression (a name, a literal, a closing bracket or `end`; not a type
  annotation such as `-> Void`), and it must not be the head of an `if`,
  `elsif`, `while`, `case` or `for`: a dot on the first line of a body never
  changes the condition. Comment-only lines (`#`) between the two lines are
  skipped, and a trailing comment on the line before is fine. A blank line ends
  the statement, and so does a `##` doc line. `..` and `...` at the start of a
  line do not continue (ranges stay as they are), and neither does `|>`. A
  keyword after the dot (`.end`) is rejected as it is on one line. A leading dot
  that continues nothing (the first line of a block or of an `if`, `while`,
  `case` or `for` body, after a blank line, after `do |x|` or after an
  operator) is `PARSE-UNEXPECTED-TOKEN`, at the dot, except after an operator,
  where it is at the line break.
- `;`, backslash continuation and implicit continuation after an operator are
  not supported. Wrap a long expression in parentheses. Inside lists and calls,
  use several lines and a trailing comma.

```ruby
total = (
  base +
  extra
)

lines = File.foreach("ledger.csv", 65536, TIMEOUT_MS)
  .drop(1)                                     # header
  .map do |line| parse(line) end
  .filter(&big_expense?)
```

Reserved words of the core, which cannot be used as identifiers:

```text
def struct enum case do import export end if elsif else while for in return try
true false nil and or not
```

`break` and `next` are not reserved words: they can name variables, and as
statements they are loop control. `with` is not reserved either: it means a
struct update only after a `.` and before `(` (§5), and it can still name
variables, functions and struct fields.

Reserved builtin names cannot be declared as functions, types, variables, import
aliases or module names: `Int`, `Float`, `Bool`, `String`, `Nil`, `Void`,
`List`, `Map`, `Set`, `Result`, `Range`, `Fn`, `Json`, `JSON`, `Task`, `Await`,
`Channel`, `Process`, `ProcessOutput`, `IO`, `System`, `Time`, `Random`, `Test`,
`TestCase`, `File`, `Dir`, `Path`, `FileHandle`, `FileInfo`, `TCP`, `TLS`,
`HttpWire`, `LogRegistry`, `LogEvent`, `LogLevel`, `Socket`, `Listener`,
`HttpClient`, `HttpServer`, `Header`, `HttpRequest`, `HttpResponse`,
`HttpClientOptions` and `HttpServerOptions`. `HTTP` is not reserved: it is the
usual alias of `std/http`. `ok` and `error` are names, but cannot be declared as
functions, variables, parameters, loop variables or fields
(`CHECK-REDEFINED-NAME`). The same holds for `puts`, `print`, `gets` and `gets!`
as variables, parameters, loop variables and pattern bindings.

A trailing `?` or `!` belongs to a lowercase name, whatever follows it:
`contains? (s, part)` is valid. `!` is not a suffix before `=`, so `a!=b` is `a
!= b`. By convention `?` marks a predicate that returns `Bool`, and `!` marks
the form that halts the run with an error instead of returning a `Result`.
Variables, fields and parameters cannot have the suffix.

The pipe operator `|>` is one token (the longest match next to `|` and `||`), so
block parameters `do |x|` and `||` are unchanged.

### Doc comments

A **doc line** is a line whose first non-blank characters are `##`. Its text is
the rest of the line after `##` and one optional space. `##` alone is an empty
doc line, which separates paragraphs. Only the first two `#`s are the marker:
`### Heading` is a doc line whose text is `# Heading`. A `##` after code on the
same line (`x = 1 ## note`) is an ordinary comment, and `##` inside a string
literal or an interpolation is text.

A **doc block** is one or more consecutive doc lines. A blank line or an
ordinary `#` comment line ends the block. The lexer emits one `DOC` token for
each block, with its lines joined by newlines as the text and the span of the
whole block. The newline after the block is an `NL`, as after any other line.
Inside `(...)`, `[...]` and `{...}`, where no `NL` is emitted, the `DOC` token
is still emitted, and the parser rejects it (`PARSE-DETACHED-DOC`).

```ebnf
DOC_LINE   = { " " | TAB }, "##", [ " " ], { ANY_BUT_NEWLINE } ;
DOC        = DOC_LINE, { NL, DOC_LINE } ;
```

`TAB` is the tab character, and `ANY_BUT_NEWLINE` is any character except a line
feed or carriage return.

The text is CommonMark. Section 5 says where a doc block may stand and what it
documents.

### Literals

```ebnf
NAME       = LOWER_OR_UNDERSCORE, { LETTER | DIGIT | "_" }, [ "?" | "!" ] ;
TYPE_NAME  = UPPER, { LETTER | DIGIT | "_" } ;
INTEGER    = DIGIT, { [ "_" ], DIGIT } ;
FLOAT      = DIGIT, { [ "_" ], DIGIT }, [ ".", DIGIT, { [ "_" ], DIGIT } ], EXPONENT
           | DIGIT, { [ "_" ], DIGIT }, ".", DIGIT, { [ "_" ], DIGIT } ;
EXPONENT   = ( "e" | "E" ), [ "+" | "-" ], DIGIT, { [ "_" ], DIGIT } ;
STRING     = '"', { STRING_CHAR | ESCAPE | INTERPOLATION }, '"' ;
ESCAPE     = "\\", ( '"' | "\\" | "#" | "n" | "r" | "t" ) ;
INTERPOLATION = "#{", expression, "}" ;
```

`LETTER` is `A`–`Z` or `a`–`z`; `DIGIT` is `0`–`9`; `LOWER_OR_UNDERSCORE` is
`a`–`z` or `_`; `UPPER` is `A`–`Z`. `STRING_CHAR` is any Unicode character
except double quotes, backslash, newlines, and a `#` followed by `{`. `NL`,
`DOC` and `EOF` are lexer tokens.

The minus sign is an operator, not part of a literal. The core has no other
number bases. An exponent follows the digits or the fraction, as in Ruby:
`1.0e300`, `1.5e-3`, `2.0E+10` and `1e5` are Floats, and `Float#to_s` writes
`1e+300`, which reads back. The `e` needs a digit before it and a digit after
the optional sign, so `1.e5` is the call `1.e5` and `1e` is the Int `1` next to
the name `e`. An exponent too large gives infinity (`1e999` is `+inf.0`). A
string literal cannot span lines; text of two or more lines is a heredoc
(below).

A `_` may separate digits in `INTEGER` and in both parts of `FLOAT`: `1_000`,
`1_000.000_5`, `1e1_0`. It is only visual: `1_000` is the same `Int` as `1000`,
and the lexer drops the `_`s before it reads the value. `_` is allowed only
between two digits. A trailing `_` (`1_`, `1_000_`, `1_a`), a double `__`
(`1__0`) and a `_` next to the dot or the `e` (`1_.5`, `1._5`, `1_e5`) are
`LEX-INVALID-NUMBER`, with the literal as written as the span: the run of
digits and `_`, plus a `.` followed by a digit or a `_` and the run after it,
plus an exponent. A `.` followed by a `_` belongs to the number, so
`1._5` is an error; a `.` followed by a letter or by another `.` ends the number
(`1_000.times`, `1_000..2_000`). `_1` is still a NAME. The text form of a number
has no separators: `puts(1_000)` prints `1000`, and `String.to_int` and JSON
still reject `_`.

`"text #{expression} text"` interpolates; the result is a `String`. Each value
is inserted as its `to_s` (see "Methods on builtin types"). The expression must
end on the same line and cannot contain comments; strings, maps and nested
interpolation may appear inside it. A Void call is `CHECK-VOID-VALUE`. A
function, task or resource handle has no `to_s` and is `CHECK-TYPE-MISMATCH`.
`\#` writes a literal `#`, so `"\#{x}"` is the text `#{x}`. `case` patterns and
`import` paths take plain string literals only, so a heredoc there is
`PARSE-UNEXPECTED-TOKEN`.

### Heredocs

A heredoc is a string of several lines, in the squiggly form of Ruby: `<<~NAME`,
then the text on the lines below, then a line that holds only `NAME`. The common
indentation of the text is removed.

```ebnf
HEREDOC      = "<<~", HEREDOC_NAME ;
HEREDOC_NAME = UPPER, { UPPER | DIGIT | "_" } ;
```

```agentica
def help_text(name: String) -> String
  text = <<~TEXT
    Usage: #{name} [options]

      --verbose   print more
    Exit code 0 on success.
  TEXT
  return text
end
```

For `name = "tool"` the value is `"Usage: tool [options]\n\n  --verbose   print
more\nExit code 0 on success.\n"`.

The lexer removes the smallest number of leading spaces among the body lines
that are not blank from every line. A line of only spaces becomes an empty line.
Each body line ends with `\n`, the last one too. The indentation is removed from
the source text before escapes and interpolation, so an interpolated value is
never re-indented.

The text is read like a string literal: the escapes are the same (`\n`, `\r`,
`\t`, `\"`, `\\`, `\#`, and a bad one is `LEX-INVALID-ESCAPE`), `#{...}`
interpolates and must end on its line, and a `"` needs no escape.

The rest of the line that holds `<<~NAME` is lexed as usual, so `puts(<<~TEXT)`
and `<<~TEXT.length` work, and the body starts on the next line. Two heredocs on
one line take their bodies one after the other, in order. Inside parentheses the
call goes on after the end line: `f(<<~A,` with the next argument on the line
after the end line. The body lines and the end line give no `NL` token; the line
of the opener gives its `NL` where it would give one without a heredoc.

The end line has only optional spaces and the name; it may be the last line of
the file, with no newline after it. A tab in the leading whitespace of a body
line or of the end line is `LEX-HEREDOC-INDENT`, at the tab, because the width
of a tab would make the removed indentation unclear. A file that ends before the
end line is `LEX-UNTERMINATED-HEREDOC`, at `<<~NAME`.

A heredoc is the form for text of two or more lines: a heredoc with one body
line, or none, is `LEX-HEREDOC-ONE-LINE`, at `<<~NAME`, with a help that shows
the string literal (`"text\n"`). A heredoc is never required: `"a\nb"` stays
valid.

Only the squiggly form exists. `<<~text`, `<<~'NAME'`, `<<NAME` and `<<-NAME`
are `LEX-UNEXPECTED-CHAR`, at the `<<` and the `~` or `-` of the opener, with a
help that shows `<<~NAME`. Every other `<<`, such as `xs << x`, is two `<`
tokens, which the parser rejects (`PARSE-UNEXPECTED-TOKEN`, with a help that
shows `xs = xs.push(x)`). A heredoc inside the `#{...}` of another string or
heredoc cannot end on its line and is `LEX-UNTERMINATED-STRING`.

The lexer gives a heredoc the tokens of a string literal (`string`, or
`interp-start`, the tokens of each expression, `interp-middle` and
`interp-end`), and every one of those string pieces has the span of `<<~NAME`,
so the nodes built from them stay on the opener line. The tokens inside `#{...}`
keep their line and column in the body, and a diagnostic about them prints that
line. A span inside a heredoc can therefore lie after the span of the expression
that holds it.

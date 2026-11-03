---
title: Option parser (std)
weight: 7
description: The std/option_parser module, which reads the command line of a program into typed values, with defaults, choices, errors and a help text.
---

`std/option_parser` is written in Agentica: `import OP from "std/option_parser"` and `import {Arg, Opt, Kind} from "std/option_parser"`. It has the shape of Python's `argparse` and the names of Ruby's `OptionParser`. It uses only structs, enums and `Optional`: no Json. You describe the program with `Arg` (a positional argument) and `Opt` (an option), `parse` checks the words, and typed getters read each value into your own struct.

```ruby
OP.new(program: String, description: String = "", args: List[Arg] = [], opts: List[Opt] = []) -> Parser
OP.parse(parser: Parser, args: List[String]) -> Result[Parsed]
OP.string(parsed: Parsed, name: String) -> String
OP.int(parsed: Parsed, name: String) -> Int
OP.float(parsed: Parsed, name: String) -> Float
OP.flag(parsed: Parsed, name: String) -> Bool
OP.optional_string(parsed: Parsed, name: String) -> Optional[String]
OP.optional_int(parsed: Parsed, name: String) -> Optional[Int]
OP.optional_float(parsed: Parsed, name: String) -> Optional[Float]
OP.run!(result: Result[T]) -> T
OP.usage(parser: Parser) -> String
OP.help?(message: String) -> Bool
```

```agentica {mode="check"}
import OP from "std/option_parser"
import {Arg, Opt, Kind as K} from "std/option_parser"

struct Options
  file: String
  port: Int
  verbose: Bool
  user: Optional[String]
end

def load() -> Result[Options]
  parser = OP.new("tool", "Serves a file over HTTP", [
    Arg(name: "file", help: "file to serve"),
  ], [
    Opt(name: "port", short: "p", kind: K.Int, default: "8080", help: "port"),
    Opt(name: "verbose", short: "v", kind: K.Flag, help: "more output"),
    Opt(name: "user", kind: K.String, help: "user name"),
  ])
  p = try OP.parse(parser, System.args())
  return ok(Options(
    file: OP.string(p, "file"),
    port: OP.int(p, "port"),
    verbose: OP.flag(p, "verbose"),
    user: OP.optional_string(p, "user"),
  ))
end

def main() -> Void
  options = OP.run!(load())
  puts("serving #{options.file} on :#{options.port}")
end
```

This is the whole program of a tool. `parse` is given `System.args()`, and `OP.run!` is where the program ends when the command line is wrong or asks for help.

## Arg and Opt

Both are structs with defaults, so a call names only the fields it needs. The two lists of `new` hold the arguments, in the order of the command line, and the options.

```ruby
Arg(name: String, help: String = "", kind: Kind = Kind.String, choices: List[String] = [], metavar: String = "")
Opt(name: String, short: String = "", kind: Kind = Kind.String, default: String = "", choices: List[String] = [],
    help: String = "", metavar: String = "")
```

`Kind` is `Int`, `Float`, `String` or `Flag`. A `Flag` takes no value: it is false unless given, and it has no default or choices. An argument cannot be a `Flag`, and every argument is required. `short` is one character. `default` is a String that is converted by `kind`, as the command line is (`default: "8080"` for an `Int`); an empty `default` means the option has none. `choices` lists the allowed texts, compared as text before the conversion. `metavar` is the name of the value in the help (`--port PORT`; `<file>` for an argument).

## The command line

- `--port 3000`, `--port=3000`, `-p 3000` and `-p3000` give a value to an option. A value is the next word whatever it holds, so `--offset -1` works.
- `-v` and `--verbose` set a flag, and short flags may be joined: `-vq`. The last letter of a joined group may take a value (`-vp3000`).
- `--` ends the options: every later word is an argument, as is a lone `-`.
- An option given twice keeps its last value.
- `--help` and `-h` ask for the help; the names `help` and `h` are reserved.

## Getters

`string`, `int`, `float` and `flag` return the plain value of an argument, of a flag, and of an option that has a default. `optional_string`, `optional_int` and `optional_float` return an `Optional`: `none` when the option was not given and has no default.

```agentica
import OP from "std/option_parser"
import {Arg, Opt, Kind as K} from "std/option_parser"

def main() -> Void
  parser = OP.new("tool", "", [Arg(name: "file")], [
    Opt(name: "port", short: "p", kind: K.Int, default: "8080"),
    Opt(name: "ratio", kind: K.Float),
    Opt(name: "verbose", short: "v", kind: K.Flag),
  ])
  p = OP.parse(parser, ["-v", "--port=3000", "--", "-notes.txt"]).unwrap!
  puts(OP.string(p, "file"))
  puts(OP.int(p, "port"))
  puts(OP.flag(p, "verbose"))
  puts(OP.optional_float(p, "ratio"))
  q = OP.parse(parser, ["a.txt"]).unwrap!
  puts(OP.int(q, "port"))
  puts(OP.flag(q, "verbose"))
end
```

```output
-notes.txt
3000
true
none
8080
false
```

A getter called with a name that was not declared, with the getter of another kind, or on an option that may be absent (`OP.string` where `optional_string` is needed) is a bug of the program, not a mistake of its user. It halts with `RUNTIME-UNWRAP-ERROR`, whose message names the option and whose stack names the line of the call. It is not an `Optional` or a `Result`, so the getters stay plain.

## Errors

`parse` returns an `error` for a mistake of the command line. The text is ready to print: `tool: ` and a message that names the option or the argument, then a line `Try 'tool --help' for more information`. The messages are:

- `unknown option --bogus` (or `-x`)
- `option --port needs a value`
- `option --verbose does not take a value`
- `invalid value for --port: 'abc' is not an Int` (or `a Float`)
- `invalid value for --user: 'cy' is not one of ana, bob`
- `missing argument <file>`
- `unexpected argument 'g'`

A mistake in the specification itself, such as a duplicate name, a short name that is not one character, or a default that does not convert, is an `error` of `parse` too (`tool: invalid specification: invalid default for --port: 'x' is not an Int`), without the hint.

```agentica
import OP from "std/option_parser"
import {Opt, Kind as K} from "std/option_parser"

def main() -> Void
  parser = OP.new("tool", "", [], [Opt(name: "port", short: "p", kind: K.Int)])
  puts(OP.parse(parser, ["--port", "abc"]).message)
  puts(OP.parse(parser, ["--bogus"]).message)
end
```

```output
tool: invalid value for --port: 'abc' is not an Int
Try 'tool --help' for more information
tool: unknown option --bogus
Try 'tool --help' for more information
```

## Help and run!

`--help` or `-h` makes `parse` return an `error` for which `OP.help?(message)` is true; the text of the help is `OP.usage(parser)`. It lists the usage line, the description, and one row for each argument and option, with its short and long names, the metavar, the help, `(default: X)` and `(choices: a, b)`.

```agentica
import OP from "std/option_parser"
import {Arg, Opt, Kind as K} from "std/option_parser"

def main() -> Void
  parser = OP.new("tool", "Serves a file over HTTP", [Arg(name: "file", help: "file to serve")], [
    Opt(name: "port", short: "p", kind: K.Int, default: "8080", help: "port"),
    Opt(name: "verbose", short: "v", kind: K.Flag, help: "more output"),
    Opt(name: "user", kind: K.String, choices: ["ana", "bob"], help: "user name"),
  ])
  result = OP.parse(parser, ["--help"])
  puts(OP.help?(result.message))
  puts(OP.usage(parser))
end
```

```output
true
Usage: tool [options] <file>

Serves a file over HTTP

Arguments:
  <file>           file to serve

Options:
  -p, --port PORT  port (default: 8080)
  -v, --verbose    more output
      --user USER  user name (choices: ana, bob)
  -h, --help       show this help
```

`OP.run!(result)` is the one function of the module that ends the program, and it is the usual last step. It returns the value of an `ok`. For the help it prints `OP.usage` to standard output and exits with 0; for any other `error` it prints the message to standard error and exits with 2. The name ends in `!` as the halting functions do, because it does not return when the result is an error. A program that wants another behavior reads `parse` itself and calls `System.exit`.

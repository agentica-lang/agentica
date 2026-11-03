# Option parser (`std/option_parser`)

`import OP from "std/option_parser"` and `import {Arg, Opt, Kind} from
"std/option_parser"`. Command-line options in the style of `argparse`, with
Ruby names. Written in Agentica; no Json.

```text
OP.new(program: String, description: String = "", args: List[Arg] = [], opts: List[Opt] = []) -> Parser
OP.parse(parser: Parser, args: List[String]) -> Result[Parsed]
OP.string / int / float / flag (parsed: Parsed, name: String) -> String / Int / Float / Bool
OP.optional_string / optional_int / optional_float (parsed: Parsed, name: String) -> Optional[T]
OP.run!(result: Result[T]) -> T
OP.usage(parser: Parser) -> String
OP.help?(message: String) -> Bool
Arg(name, help = "", kind = Kind.String, choices = [], metavar = "")
Opt(name, short = "", kind = Kind.String, default = "", choices = [], help = "", metavar = "")
Kind: Int, Float, String, Flag
```

```ruby
parser = OP.new("tool", "Serves a file", [Arg(name: "file")], [
  Opt(name: "port", short: "p", kind: Kind.Int, default: "8080"),
  Opt(name: "verbose", short: "v", kind: Kind.Flag),
  Opt(name: "user"),
])
p = try OP.parse(parser, System.args())   # in a Result function
Options(file: OP.string(p, "file"), port: OP.int(p, "port"),
        verbose: OP.flag(p, "verbose"), user: OP.optional_string(p, "user"))
```

- Arguments and options are two lists (a list holds one type). Arguments are
  required, in order. `default` is a String converted by `kind`; `""` means
  none. A Flag has no default or choices. `choices` compare as text.
- Words: `--port 3000`, `--port=3000`, `-p 3000`, `-p3000`, joined short flags
  `-vq`, `--` ends the options. A value is the next word, even `-1`.
- Plain getters (`string`, `int`, `float`, `flag`) are for arguments, flags and
  options with a default; `optional_*` for the rest (`none` when not given). A
  getter with an undeclared name, the wrong kind, or a plain getter on a value
  that may be absent halts with `RUNTIME-UNWRAP-ERROR` (a bug of the program).
- Every `parse` error is `"tool: message"` plus the line `Try 'tool --help' for
  more information`, and names the option (`unknown option --x`, `option --port
  needs a value`, `invalid value for --port: 'x' is not an Int`, `... is not one
  of a, b`, `missing argument <file>`, `unexpected argument 'g'`). A wrong
  specification (duplicate name, bad default) is an error of `parse` too.
- `--help` or `-h`: `parse` returns an error for which `OP.help?` is true; the
  text is `OP.usage(parser)`. `OP.run!(load())` prints the help and exits 0, or
  prints any other error to stderr and exits 2, or returns the value; call it
  in `main`.

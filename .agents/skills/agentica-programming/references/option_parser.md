# Option parser (`std/option_parser`)

`import OP from "std/option_parser"` and `import {Arg, Opt, Kind} from
"std/option_parser"`. Command-line options in the style of `argparse`, with
Ruby names. Written in Agentica; no Json.

```text
OP.new(program: String, description: String = "", args: List[Arg] = [], opts: List[Opt] = [], rest: String = "") -> Parser
OP.parse(parser: Parser, args: List[String]) -> Result[Parsed]
OP.string / int / float / flag (parsed: Parsed, name: String) -> String / Int / Float / Bool
OP.optional_string / optional_int / optional_float (parsed: Parsed, name: String) -> Optional[T]
OP.rest / after_dashes (parsed: Parsed) -> List[String]
OP.run!(result: Result[T]) -> T
OP.usage(parser: Parser) -> String
OP.help?(message: String) -> Bool
OP.message(error_text: String) -> String
Arg(name, help = "", kind = Kind.String, choices = [], metavar = "", min = none, max = none)
Opt(name, short = "", kind = Kind.String, default = "", choices = [], help = "", metavar = "", min = none, max = none)
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
- `min: some(1), max: some(65535)` limit an Int option or argument (and its
  default); a value outside is `invalid value for --port: '0' is below the
  minimum 1` (`does not fit an Int` for a number too big). On another kind,
  or with `min` above `max`, they are a wrong specification.
- A word past the arguments is `unexpected argument`, unless `new` gets
  `rest`, its fifth argument (positional), such as `"FILE"`, shown as
  `[FILE...]` in the usage line. Then `OP.rest(p)` gives those words, after
  `--` included, and `OP.after_dashes(p)` the last of them, those after `--`
  (`FILE... -- FLAGS`).
- On/off: no Bool kind; use `Opt(name: "stats", choices: ["on", "off"],
  default: "off")` and `OP.string(p, "stats") == "on"`. A Flag takes no value.
- Words: `--port 3000`, `--port=3000`, `-p 3000`, `-p3000`, joined short flags
  `-vq`, `--` ends the options. As in argparse, the next word is a value only if
  it does not start with `-`, or is `-` or a negative number; `--name=--x` gives
  the literal.
- Plain getters (`string`, `int`, `float`, `flag`) are for arguments, flags and
  options with a default; `optional_*` for the rest (`none` when not given). A
  getter with an undeclared name, the wrong kind, or a plain getter on a value
  that may be absent halts with `RUNTIME-UNWRAP-ERROR` (a bug of the program).
- Every `parse` error is `"tool: message"` plus a `Try 'tool --help'` line, and
  names the option. A wrong specification (duplicate name, bad default, an `Arg`
  of kind `Flag`, a short name that is a digit, `-` or `=`) is an error of
  `parse` too.
- `--help` or `-h`: `parse` returns an error for which `OP.help?` is true; the
  text is `OP.usage(parser)` (set `metavar` for the value name). Print an error
  you handle yourself with `OP.message(error)`. `OP.run!(load())` prints the
  help and exits 0, or prints any other error to stderr and exits 2, or returns
  the value; call it in `main`.

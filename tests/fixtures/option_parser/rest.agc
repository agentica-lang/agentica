## Test program of tests/test_std_option_parser.py: a source argument, then the rest of the positional words, split
## at `--` as `check FILE... -- FLAGS` splits them. It prints what it got on one line, or lets OP.run! print the help
## or the error and exit.

import OP from "std/option_parser"
import {Arg, Opt, Kind as K} from "std/option_parser"

def main() -> Void
  parser = OP.new(
    "check",
    "Checks C files",
    [Arg(name: "src", help: "source folder")],
    [
      Opt(name: "verbose", short: "v", kind: K.Flag, help: "more output"),
      Opt(name: "out", short: "o", help: "report"),
    ],
    "FILE",
  )

  p = OP.run!(OP.parse(parser, System.args()))
  rest = OP.rest(p)
  flags = OP.after_dashes(p)
  files = rest.take(rest.size - flags.size)
  out = OP.optional_string(p, "out").unwrap_or("none")
  puts("src=#{OP.string(p, "src")} files=#{files.join(",")} flags=#{flags.join(",")}")
  puts("v=#{OP.flag(p, "verbose")} out=#{out}")
end

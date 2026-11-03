## Test program of tests/test_std_option_parser.py: the example of the std/option_parser page. It prints the options it
## got on one line, or lets OP.run! print the help or the error and exit.

import OP from "std/option_parser"
import {Arg, Opt, Kind as K} from "std/option_parser"

struct Options
  file: String
  port: Int
  verbose: Bool
  quiet: Bool
  user: Optional[String]
end

def load() -> Result[Options]
  parser = OP.new(
    "tool",
    "Serves a file over HTTP",
    [Arg(name: "file", help: "file to serve")],
    [
      Opt(name: "port", short: "p", kind: K.Int, default: "8080", help: "port"),
      Opt(name: "verbose", short: "v", kind: K.Flag, help: "more output"),
      Opt(name: "quiet", short: "q", kind: K.Flag, help: "less output"),
      Opt(name: "user", short: "u", kind: K.String, help: "user name"),
    ],
  )
  p = try OP.parse(parser, System.args())
  return ok(
    Options(
      file: OP.string(p, "file"),
      port: OP.int(p, "port"),
      verbose: OP.flag(p, "verbose"),
      quiet: OP.flag(p, "quiet"),
      user: OP.optional_string(p, "user"),
    ),
  )
end

def main() -> Void
  options = OP.run!(load())
  user = options.user.unwrap_or("none")
  puts("file=#{options.file} port=#{options.port} verbose=#{options.verbose} quiet=#{options.quiet} user=#{user}")
end

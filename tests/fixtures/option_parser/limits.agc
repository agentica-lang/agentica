## Test program of tests/test_std_option_parser.py: Int and Float limits, the default value names and the on/off
## option. It prints the options it got on one line, or lets OP.run! print the help or the error and exit.

import OP from "std/option_parser"
import {Opt, Kind as K} from "std/option_parser"

struct Options
  port: Int
  threads: Int
  ctx: Int
  stats: Bool
  dir: String
end

def load() -> Result[Options]
  parser = OP.new(
    "serve",
    "Serves a model",
    [],
    [
      Opt(name: "port", short: "p", kind: K.Int, default: "8080", min: some(0), max: some(65535), help: "port"),
      Opt(name: "threads", kind: K.Int, default: "1", min: some(1), help: "worker threads (at least one)"),
      Opt(name: "ctx", kind: K.Int, default: "0", help: "context size"),
      Opt(name: "temp", kind: K.Float, default: "0.8", min_float: some(0.0), max_float: some(2.0), help: "temperature"),
      Opt(name: "stats", choices: ["on", "off"], default: "off", help: "print statistics"),
      Opt(name: "dir", metavar: "DIR", help: "model folder"),
    ],
  )
  p = try OP.parse(parser, System.args())
  return ok(
    Options(
      port: OP.int(p, "port"),
      threads: OP.int(p, "threads"),
      ctx: OP.int(p, "ctx"),
      stats: OP.string(p, "stats") == "on",
      dir: OP.optional_string(p, "dir").unwrap_or("none"),
    ),
  )
end

def main() -> Void
  options = OP.run!(load())
  puts("port=#{options.port} threads=#{options.threads} ctx=#{options.ctx} stats=#{options.stats} dir=#{options.dir}")
end

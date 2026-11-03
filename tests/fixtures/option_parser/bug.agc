## Test program of tests/test_std_option_parser.py: reads a value the wrong way, as the first argument says.

import OP from "std/option_parser"
import {Opt, Kind as K} from "std/option_parser"

def main() -> Void
  parser = OP.new("tool", "", [], [Opt(name: "port", kind: K.Int, default: "80"), Opt(name: "user")])
  p = OP.parse(parser, []).unwrap!
  mode = System.args()[0]
  if mode == "undeclared"
    puts(OP.int(p, "prot"))
  elsif mode == "kind"
    puts(OP.string(p, "port"))
  elsif mode == "absent"
    puts(OP.string(p, "user"))
  else
    puts(OP.int(p, "port"))
  end
end

import Driver from "bdd_driver"
import Opts from "bdd_options"
import Report from "bdd_report"

# `agentica-vm --allow-run -- bdd.agcb DRIVER_OPTIONS -- ARGUMENTS...` is `agentica test`: it runs the tests and prints
# the report. The exit code is that of the report (0, 1 or 2). bdd_options.agc says what the arguments are;
# src/main.rkt starts this program until the command line itself is ported (docs/future/35-self-hosting.md, step 8).
def main() -> Void
  case Opts.parse(System.args())
    Opts.Parsed.Broken(message) ->
      IO.warn("the BDD driver was started wrongly: #{message}")
      System.exit(2)
    Opts.Parsed.Usage(message, options) -> finish(Report.usage(message, options))
    Opts.Parsed.Ready(options) -> finish(Driver.run(options))
  end
end

def finish(ending: Report.Ending) -> Void
  print(ending.text)
  IO.flush()
  System.exit(ending.code)
end

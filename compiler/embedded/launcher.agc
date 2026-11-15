import Hit from "../app/cli_hit"
import Inputs from "../app/front_end_inputs"
import Host from "../io/host"

private

# The launcher of the binary (app/cli_hit.agc): it gets the arguments of the front end (app/front_end_inputs.agc) and
# starts a cached program, or returns so that the front end runs.
def main() -> Void
  case Inputs.read(System.args(), Host.workspace_with(&std_source))
    Inputs.Read.Ready(settings, words) -> Hit.run(settings, words)
    Inputs.Read.Broken(_) -> return
  end
end

def std_source(name: String) -> Result[String] = FrontEnd.std_source(name)

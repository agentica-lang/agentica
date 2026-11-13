import Shout from "util/shout"
import Tools from "pkg/tools/bang"

def hello(name: String) -> String
  return Shout.shout("hello #{name}") + Tools.bang()
end

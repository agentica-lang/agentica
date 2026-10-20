import Shout from "util/shout"
import Tools from "pkg/tools/bang"

export def hello(name: String) -> String
  return Shout.shout("hello #{name}") + Tools.bang()
end

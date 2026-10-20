import Shout from "util/shout"
import Tools from "gitlab.com/team/tools/bang"

export def hello(name: String) -> String
  return Shout.shout("hello #{name}") + Tools.bang()
end

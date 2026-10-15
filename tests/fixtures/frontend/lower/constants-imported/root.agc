import Limits from "limits"
import {TOP as LIMIT, NAMES} from "limits"

LOCAL = [LIMIT, 1]

def main() -> Void
  puts("#{LIMIT} #{Limits.top()} #{NAMES} #{LOCAL}")
end

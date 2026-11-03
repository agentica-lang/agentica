import Lib from "lib/default_constants"
import {LIMIT as CAP} from "lib/default_constants"

# A default may name a constant of its own file, of an imported alias or an imported name, and the same constant can be
# a default of a parameter and of a field. START is a constant built from a struct whose field defaults name constants
# of another file.
PORT = 8080
START = Server()

struct Server
  port: Int = PORT
  cap: Int = CAP
  label: String = Lib.LABEL
end

def listen(port: Int = PORT, cap: Int = Lib.LIMIT, extra: Int = CAP) -> String
  return "#{port} #{cap} #{extra}"
end

def main() -> Void
  puts(listen())
  puts(listen(1))
  puts(listen(1, 2, 3))
  puts(Server())
  puts(Server(port: 9))
  puts(START)
  puts(Lib.describe())
  puts(Lib.describe(1))
  puts(Lib.Options())
  puts(Lib.size_of())
  puts(Lib.size_of(Lib.Options(size: 2)))
end

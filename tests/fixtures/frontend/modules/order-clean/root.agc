## Module doc.

import Lib from "lib"
import Queue from "std/queue"

enum Kind
  A
end

struct Pair
  n: Int
end

def api() -> Void
  Lib.go()
  helper()
end

private

struct Box
  n: Int
end

enum Hidden
  B
end

def helper() -> Void
  _ = Queue.new()
end

def main() -> Void
end

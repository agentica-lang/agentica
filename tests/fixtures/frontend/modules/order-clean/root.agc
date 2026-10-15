## Module doc.

import Lib from "lib"
import Queue from "std/queue"

export enum Kind
  A
end

struct Box
  n: Int
end

export struct Pair
  n: Int
end

enum Hidden
  B
end

export def api() -> Void
  Lib.go()
  helper()
end

def helper() -> Void
end

def main() -> Void
end


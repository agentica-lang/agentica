import Lib from "lib"

struct Local
  n: Int
end

def main() -> Void
  _a = Lib.make().with(n: 5)
  _b = Local(n: 1).with(n: Lib.make().n)
  _c = Header(name: "a", value: "b").with(value: "c")
end


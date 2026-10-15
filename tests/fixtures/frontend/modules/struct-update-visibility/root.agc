import "lib" as Lib

struct Local
  n: Int
end

def main() -> Void
  a = Lib.make().with(n: 5)
  b = Local(n: 1).with(n: Lib.make().n)
  c = Header(name: "a", value: "b").with(value: "c")
end


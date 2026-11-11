import Lib from "lib"

struct Local
  n: Int
end

def main() -> Void
  _a = Lib.make().with(n: 5)
  _b = Local(n: 1).with(n: Lib.make().n)
  _c = ProcessOutput(stdout: "a", stderr: "b", truncated: false).with(stderr: "c")
end


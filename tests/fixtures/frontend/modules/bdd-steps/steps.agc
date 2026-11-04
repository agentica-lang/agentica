import BDD from "std/bdd"
import Assertions from "assertions"

export def count() -> Int
  return 1
end

def main() -> Void
  BDD.run([BDD.step("it works", &Assertions.verify)])
end

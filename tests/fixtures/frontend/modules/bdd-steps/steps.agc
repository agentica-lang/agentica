import BDD from "std/bdd"
import Assertions from "assertions"

def count() -> Int
  return 1
end

private

def main() -> Void
  BDD.run([BDD.step("it works", &Assertions.verify)])
end

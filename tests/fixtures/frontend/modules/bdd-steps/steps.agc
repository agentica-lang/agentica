import BDD from "std/bdd"
import Assertions from "assertions"

def main() -> Void
  BDD.run([BDD.step("it works", &Assertions.verify)])
end


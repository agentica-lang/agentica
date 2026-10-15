import "std/bdd" as BDD
import "assertions" as Assertions

def main() -> Void
  BDD.run([BDD.step("it works", &Assertions.verify)])
end


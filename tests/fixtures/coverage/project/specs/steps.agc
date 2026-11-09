import BDD from "std/bdd"
import Shapes from "../src/shapes"

def triangle(ctx: BDD.Context, args: List[String]) -> BDD.Context
  area = Shapes.area("triangle", args[0].to_i!)
  return BDD.assert(ctx, area == args[1].to_i!, "wrong area #{area}")
end

def main() -> Void
  BDD.run([BDD.step("the triangle of side {int} has area {int}", &triangle)])
end

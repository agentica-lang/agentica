import {Point} from "lib"

def main() -> Void
  case Point(x: 1, y: 2)
    Point.Red -> puts("red")
  end
end

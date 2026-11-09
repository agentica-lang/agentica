import Shapes from "../src/shapes"

def test_square_again() -> Result[Void]
  return Test.eq(Shapes.area("square", 1), 1)
end

import Shapes from "../src/shapes"

def test_square() -> Result[Void]
  return Test.eq(Shapes.area("square", 3), 9)
end

def test_wrong() -> Result[Void]
  return Test.eq(Shapes.area("square", 2), 5)
end

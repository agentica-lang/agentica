import Lib from "lib"
def main() -> Void
  b = Lib.make(" hi ")
  IO.inspect(b.label.strip.upcase.size)
end


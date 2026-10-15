import "lib" as Lib
def main() -> Void
  b = Lib.make(" hi ")
  IO.inspect(b.label.strip.upcase.size)
end


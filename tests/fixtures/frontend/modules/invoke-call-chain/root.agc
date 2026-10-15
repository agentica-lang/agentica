import "lib" as Lib
def main() -> Void
  f = Lib.make()
  puts(f.call(2).to_s)
end


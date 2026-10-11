import "lib/a/m.agc" as A
import "lib/b/m.agc" as B

def main() -> Void
  puts(A.go([1, 2]))
  puts(B.go([1, 2]))
  puts(B.go(A.go([3])))
end

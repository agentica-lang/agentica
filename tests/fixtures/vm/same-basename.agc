import A from "lib/a/m"
import B from "lib/b/m"

def main() -> Void
  puts(A.go([1, 2]))
  puts(B.go([1, 2]))
  puts(B.go(A.go([3])))
end

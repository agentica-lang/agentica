def main() -> Void
  r: Result[Int] = error("unique failed", kind: "Db Constraint", code: 19)
  puts(r)
end

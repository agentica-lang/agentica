import Demo from "duckdb"

def main() -> Void
  args = System.args()
  if List.size(args) != 1
    IO.warn("usage: main.agc OUTPUT_DIR")
    System.exit(2)
  end
  result = Demo.run_demo(args[0])
  if !result.ok?()
    IO.warn(result.message())
    System.exit(1)
  end
end

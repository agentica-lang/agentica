import S from "shapes"

enum Command
  Show
  Add(Int)
end

def main() -> Void
  c = Command.Show
  case c
    Command.Show -> puts("show")
    Command.Add(n) -> puts(n.to_s)
  end
  s = S.Shape.Dot
  case s
    S.Shape.Dot -> puts("dot")
    _ -> puts("other")
  end
end


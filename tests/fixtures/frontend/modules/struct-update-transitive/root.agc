import Mid from "mid"

def main() -> Void
  m = Mid.make()
  n = m.b.with(n: 3)
  o = m.with(b: m.b)
end


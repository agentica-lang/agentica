import Base from "base"

struct Mid
  b: Base.Base
end

def make() -> Mid
  return Mid(b: Base.Base(n: 1)).with(b: Base.Base(n: 2))
end

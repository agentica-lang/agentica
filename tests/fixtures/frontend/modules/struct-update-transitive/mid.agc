import Base from "base"

export struct Mid
  b: Base.Base
end

export def make() -> Mid
  return Mid(b: Base.Base(n: 1)).with(b: Base.Base(n: 2))
end


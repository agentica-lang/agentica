export struct Pub
  n: Int
end

struct Priv
  n: Int
end

export def make() -> Pub
  return Pub(n: 1).with(n: 2)
end

def inner(p: Priv) -> Priv
  return p.with(n: 3)
end


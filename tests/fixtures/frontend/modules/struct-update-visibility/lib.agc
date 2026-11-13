struct Pub
  n: Int
end

def make() -> Pub
  return Pub(n: 1).with(n: 2)
end

private

struct Priv
  n: Int
end

def inner(p: Priv) -> Priv
  return p.with(n: 3)
end

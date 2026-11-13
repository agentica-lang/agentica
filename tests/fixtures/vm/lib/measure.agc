struct Rect
  w: Int
  h: Int
end

enum Fit
  Tight
  Loose(Int)
end

def describe(r: Rect) -> String
  return "#{r.w}x#{r.h}"
end

def area(r: Rect) -> Int
  return r.w * r.h
end

def fit(r: Rect, room: Int) -> Fit
  if area(r) == room
    return Fit.Tight
  end
  return Fit.Loose(room - area(r))
end

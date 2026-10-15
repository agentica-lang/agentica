export struct Rect
  w: Int
  h: Int
end

export enum Fit
  Tight
  Loose(Int)
end

export def describe(r: Rect) -> String
  return "#{r.w}x#{r.h}"
end

export def area(r: Rect) -> Int
  return r.w * r.h
end

export def fit(r: Rect, room: Int) -> Fit
  if area(r) == room
    return Fit.Tight
  end
  return Fit.Loose(room - area(r))
end

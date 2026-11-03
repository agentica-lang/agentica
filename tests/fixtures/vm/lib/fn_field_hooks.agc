# A struct with Fn fields, called from another file as hooks.add(1, 2) (fn-field-call.agc).
export struct Hooks
  add: Fn[Int, Int, Int]
  each: Fn[List[Int], Fn[Int, Void], Void]
end

export def plus(a: Int, b: Int) -> Int
  return a + b
end

export def walk(items: List[Int], f: Fn[Int, Void]) -> Void
  for item in items
    f.call(item)
  end
end

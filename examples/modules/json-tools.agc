export struct AddArgs
  left: Int
  right: Int
end

export def add(args: AddArgs) -> Int
  return args.left + args.right
end

export def double(value: Int) -> Int
  return value * 2
end

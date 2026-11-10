export struct AddArgs
  left: Int
  right: Int
end

export def add(args: AddArgs) -> Int = args.left + args.right

export def double(value: Int) -> Int = value * 2

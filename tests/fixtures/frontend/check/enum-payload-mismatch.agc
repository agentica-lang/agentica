enum Box[T]
  Full(T)
end

enum Other[T]
  Item(T)
end

enum Wrap[T]
  Holder(Box[T])
end

def main() -> Void
  w = Wrap.Holder(Other.Item(1))
end

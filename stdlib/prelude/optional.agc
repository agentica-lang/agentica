## The Optional methods of the compiler prelude (see list.agc). A is the item type and B the type a callback gives.
## Each function is O(1) and calls its callback at most once.

def unwrap_or(value: Optional[A], default: A) -> A
  case value
    some(item) -> item
    none -> default
  end
end

# Argument 0 of the call is the receiver: the error is reported there.
def unwrap(value: Optional[A]) -> A
  case value
    some(item) -> return item
    none -> __fail_arg("RUNTIME-UNWRAP-NONE", 0, "unwrap! on none")
  end
  # Never reached, since __fail_arg halts; it gives the A that every path must return.
  never: Result[A] = error("unwrap! on none")
  never.unwrap!
end

def map(value: Optional[A], f: Fn[A, B]) -> Optional[B]
  case value
    some(item) -> some(f.call(item))
    none -> none
  end
end

def is_some(value: Optional[A]) -> Bool
  case value
    some(_) -> true
    none -> false
  end
end

def is_none(value: Optional[A]) -> Bool
  case value
    some(_) -> false
    none -> true
  end
end

def to_result(value: Optional[A], message: String) -> Result[A]
  case value
    some(item) -> ok(item)
    none -> error(message)
  end
end

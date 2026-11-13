## The Range methods of the compiler prelude (see list.agc): the Enumerable methods of List, each with the result of
## `.to_a.<method>`, without building the list of the range first. B is the type a callback gives, K a key that is an
## Int or a String.
##
## Cost: each function is O(n) in the steps of the VM, n the values it visits, and calls its callback once for each of
## them, in order; min and max are O(1).

private

def map(range: Range, block: Fn[Int, B]) -> List[B]
  found: List[B] = []
  for item in range
    found = found.push(block.call(item))
  end
  found
end

def select(range: Range, block: Fn[Int, Bool]) -> List[Int]
  found: List[Int] = []
  for item in range
    if block.call(item)
      found = found.push(item)
    end
  end
  found
end

def flat_map(range: Range, block: Fn[Int, List[B]]) -> List[B]
  found: List[B] = []
  for item in range
    for part in block.call(item)
      found = found.push(part)
    end
  end
  found
end

def reduce(range: Range, initial: B, block: Fn[B, Int, B]) -> B
  total = initial
  for item in range
    total = block.call(total, item)
  end
  total
end

def sum(range: Range) -> Int
  total = 0
  for item in range
    total += item
  end
  total
end

def min(range: Range) -> Optional[Int]
  case range.first
    ok(value) -> some(value)
    error(_) -> none
  end
end

def max(range: Range) -> Optional[Int]
  case range.last
    ok(value) -> some(value)
    error(_) -> none
  end
end

# min_by and max_by: the first value wins a tie, so a later key must be strictly better. A NaN key never wins, unless
# every key is NaN, and then the first value stays. Strings compare by String.compare, the order of sort.
def min_by_int(range: Range, key: Fn[Int, Int]) -> Optional[Int]
  best: Optional[Int] = none
  seen = false
  best_key = 0
  for item in range
    candidate_key = key.call(item)
    if !seen or candidate_key < best_key
      best = some(item)
      best_key = candidate_key
      seen = true
    end
  end
  best
end

def min_by_float(range: Range, key: Fn[Int, Float]) -> Optional[Int]
  best: Optional[Int] = none
  seen = false
  best_key = 0.0
  for item in range
    candidate_key = key.call(item)
    if !seen or (candidate_key == candidate_key and (best_key != best_key or candidate_key < best_key))
      best = some(item)
      best_key = candidate_key
      seen = true
    end
  end
  best
end

def min_by_string(range: Range, key: Fn[Int, String]) -> Optional[Int]
  best: Optional[Int] = none
  seen = false
  best_key = ""
  for item in range
    candidate_key = key.call(item)
    if !seen or String.compare(candidate_key, best_key) < 0
      best = some(item)
      best_key = candidate_key
      seen = true
    end
  end
  best
end

def max_by_int(range: Range, key: Fn[Int, Int]) -> Optional[Int]
  best: Optional[Int] = none
  seen = false
  best_key = 0
  for item in range
    candidate_key = key.call(item)
    if !seen or candidate_key > best_key
      best = some(item)
      best_key = candidate_key
      seen = true
    end
  end
  best
end

def max_by_float(range: Range, key: Fn[Int, Float]) -> Optional[Int]
  best: Optional[Int] = none
  seen = false
  best_key = 0.0
  for item in range
    candidate_key = key.call(item)
    if !seen or (candidate_key == candidate_key and (best_key != best_key or candidate_key > best_key))
      best = some(item)
      best_key = candidate_key
      seen = true
    end
  end
  best
end

def max_by_string(range: Range, key: Fn[Int, String]) -> Optional[Int]
  best: Optional[Int] = none
  seen = false
  best_key = ""
  for item in range
    candidate_key = key.call(item)
    if !seen or String.compare(candidate_key, best_key) > 0
      best = some(item)
      best_key = candidate_key
      seen = true
    end
  end
  best
end

def find(range: Range, block: Fn[Int, Bool]) -> Result[Int]
  for item in range
    return ok(item) if block.call(item)
  end
  error("not found")
end

def find_index(range: Range, block: Fn[Int, Bool]) -> Optional[Int]
  index = 0
  for item in range
    return some(index) if block.call(item)
    index += 1
  end
  none
end

def any(range: Range, block: Fn[Int, Bool]) -> Bool
  for item in range
    return true if block.call(item)
  end
  false
end

def all(range: Range, block: Fn[Int, Bool]) -> Bool
  for item in range
    return false if !block.call(item)
  end
  true
end

def each_with_index(range: Range, block: Fn[Int, Int, Void]) -> Void
  index = 0
  for item in range
    block.call(item, index)
    index += 1
  end
end

# Argument 1 of the call is size (argument 0 is the range): the error is reported there.
def each_slice(range: Range, size: Int) -> List[List[Int]]
  if size < 1
    __fail_arg("RUNTIME-INVALID-COUNT", 1, "each_slice needs a size of at least 1, found #{size}")
  end
  slices: List[List[Int]] = []
  current: List[Int] = []
  for item in range
    current = current.push(item)
    if current.size == size
      slices = slices.push(current)
      current = []
    end
  end
  if current.size > 0
    slices = slices.push(current)
  end
  slices
end

def partition(range: Range, block: Fn[Int, Bool]) -> List[List[Int]]
  accepted: List[Int] = []
  rejected: List[Int] = []
  for item in range
    if block.call(item)
      accepted = accepted.push(item)
    else
      rejected = rejected.push(item)
    end
  end
  [accepted, rejected]
end

# The groups keep the order of first appearance.
def group_by(range: Range, key: Fn[Int, K]) -> Map[K, List[Int]]
  groups: Map[K, List[Int]] = {}
  for item in range
    name = key.call(item)
    groups = groups.put(name, groups.get(name, []).push(item))
  end
  groups
end

def take_while(range: Range, block: Fn[Int, Bool]) -> List[Int]
  found: List[Int] = []
  for item in range
    break if !block.call(item)
    found = found.push(item)
  end
  found
end

def drop_while(range: Range, block: Fn[Int, Bool]) -> List[Int]
  found: List[Int] = []
  dropping = true
  for item in range
    if dropping and !block.call(item)
      dropping = false
    end
    if !dropping
      found = found.push(item)
    end
  end
  found
end

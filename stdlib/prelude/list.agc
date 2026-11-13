## The List methods of the compiler prelude (docs/vm/03-ir-and-bytecode.md §4.7). Not a module: no program
## imports it. The checker reads a call of xs.find do |x| ... end, picks the function here that the catalog row names,
## and the compiler adds it to the program (check/prelude_files.agc). A is the element type, B the type a callback
## gives, K a key that is an Int or a String; the checker has checked the call, so these names stand for the real
## types. A runtime error of a function here is reported at the call of the program, not in this file.
##
## Cost: each function is O(n) in the steps of the VM and calls its callback once for each element, from the first to
## the last. Nothing here calls concat, take, drop, reverse, sort, sort_by, Map.keys or Map.values inside a loop or a
## callback (tests/test_stdlib_prelude.py reads this file for them), so no function is quadratic.

private

def find(list: List[A], block: Fn[A, Bool]) -> Result[A]
  for item in list
    return ok(item) if block.call(item)
  end
  error("not found")
end

def find_index(list: List[A], block: Fn[A, Bool]) -> Optional[Int]
  index = 0
  for item in list
    return some(index) if block.call(item)
    index += 1
  end
  none
end

def each_with_index(list: List[A], block: Fn[A, Int, Void]) -> Void
  index = 0
  for item in list
    block.call(item, index)
    index += 1
  end
end

def flat_map(list: List[A], block: Fn[A, List[B]]) -> List[B]
  found: List[B] = []
  for item in list
    for part in block.call(item)
      found = found.push(part)
    end
  end
  found
end

def partition(list: List[A], block: Fn[A, Bool]) -> List[List[A]]
  accepted: List[A] = []
  rejected: List[A] = []
  for item in list
    if block.call(item)
      accepted = accepted.push(item)
    else
      rejected = rejected.push(item)
    end
  end
  [accepted, rejected]
end

# One scan for the length of the prefix, then one take: block is not called after the first false.
def take_while(list: List[A], block: Fn[A, Bool]) -> List[A]
  count = 0
  for item in list
    break if !block.call(item)
    count += 1
  end
  list.take(count)
end

def drop_while(list: List[A], block: Fn[A, Bool]) -> List[A]
  count = 0
  for item in list
    break if !block.call(item)
    count += 1
  end
  list.drop(count)
end

# Argument 1 of the call is size (argument 0 is the list): the error is reported there.
def each_slice(list: List[A], size: Int) -> List[List[A]]
  if size < 1
    __fail_arg("RUNTIME-INVALID-COUNT", 1, "each_slice needs a size of at least 1, found #{size}")
  end
  slices: List[List[A]] = []
  current: List[A] = []
  for item in list
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

# The groups and their elements keep the order of first appearance.
def group_by(list: List[A], key: Fn[A, K]) -> Map[K, List[A]]
  groups: Map[K, List[A]] = {}
  for item in list
    name = key.call(item)
    groups = groups.put(name, groups.get(name, []).push(item))
  end
  groups
end

def tally(list: List[K]) -> Map[K, Int]
  counts: Map[K, Int] = {}
  for item in list
    counts = counts.put(item, counts.get(item, 0) + 1)
  end
  counts
end

def uniq(list: List[K]) -> List[K]
  seen: Set[K] = Set.new([])
  found: List[K] = []
  for item in list
    if !seen.include?(item)
      seen = seen.add(item)
      found = found.push(item)
    end
  end
  found
end

# The call site checked that the items have equality (the row limits T by it), so == is allowed on the type variable
# here. A Float follows IEEE 754, so a NaN is never a member, not even of a list that holds it.
def include(list: List[A], value: A) -> Bool
  for item in list
    return true if item == value
  end
  false
end

# The same loop for the types whose == is a single instruction: a call of Value.equal for each item costs about three
# times more.
def include_int(list: List[Int], value: Int) -> Bool
  for item in list
    return true if item == value
  end
  false
end

def include_float(list: List[Float], value: Float) -> Bool
  for item in list
    return true if item == value
  end
  false
end

def include_string(list: List[String], value: String) -> Bool
  for item in list
    return true if item == value
  end
  false
end

def index(list: List[A], value: A) -> Optional[Int]
  at = 0
  for item in list
    return some(at) if item == value
    at += 1
  end
  none
end

# The faster loops of include_int and its kin, for index.
def index_int(list: List[Int], value: Int) -> Optional[Int]
  at = 0
  for item in list
    return some(at) if item == value
    at += 1
  end
  none
end

def index_float(list: List[Float], value: Float) -> Optional[Int]
  at = 0
  for item in list
    return some(at) if item == value
    at += 1
  end
  none
end

def index_string(list: List[String], value: String) -> Optional[Int]
  at = 0
  for item in list
    return some(at) if item == value
    at += 1
  end
  none
end

def sum_int(list: List[Int]) -> Int
  total = 0
  for item in list
    total += item
  end
  total
end

def sum_float(list: List[Float]) -> Float
  total = 0.0
  for item in list
    total += item
  end
  total
end

# min and max: the first element wins a tie, so a later item must be strictly better. A NaN never wins, unless every
# item is NaN, and then the first stays, as in min_by. Strings compare by String.compare, the order of sort.
def min_int(list: List[Int]) -> Optional[Int]
  return none if list.size == 0
  best = list[0]
  for item in list
    if item < best
      best = item
    end
  end
  some(best)
end

def min_float(list: List[Float]) -> Optional[Float]
  return none if list.size == 0
  best = list[0]
  for item in list
    if item == item and (best != best or item < best)
      best = item
    end
  end
  some(best)
end

def min_string(list: List[String]) -> Optional[String]
  return none if list.size == 0
  best = list[0]
  for item in list
    if String.compare(item, best) < 0
      best = item
    end
  end
  some(best)
end

def max_int(list: List[Int]) -> Optional[Int]
  return none if list.size == 0
  best = list[0]
  for item in list
    if item > best
      best = item
    end
  end
  some(best)
end

def max_float(list: List[Float]) -> Optional[Float]
  return none if list.size == 0
  best = list[0]
  for item in list
    if item == item and (best != best or item > best)
      best = item
    end
  end
  some(best)
end

def max_string(list: List[String]) -> Optional[String]
  return none if list.size == 0
  best = list[0]
  for item in list
    if String.compare(item, best) > 0
      best = item
    end
  end
  some(best)
end

# min_by and max_by: the first element wins a tie, so a later key must be strictly better. A NaN key never wins, unless
# every key is NaN, and then the first element stays (candidate == candidate is false for NaN). Strings compare by
# String.compare, the order of sort.
def min_by_int(list: List[A], key: Fn[A, Int]) -> Optional[A]
  return none if list.size == 0
  best = list[0]
  best_key = key.call(best)
  index = 1
  while index < list.size
    candidate = list[index]
    candidate_key = key.call(candidate)
    if candidate_key < best_key
      best = candidate
      best_key = candidate_key
    end
    index += 1
  end
  some(best)
end

def min_by_float(list: List[A], key: Fn[A, Float]) -> Optional[A]
  return none if list.size == 0
  best = list[0]
  best_key = key.call(best)
  index = 1
  while index < list.size
    candidate = list[index]
    candidate_key = key.call(candidate)
    if candidate_key == candidate_key and (best_key != best_key or candidate_key < best_key)
      best = candidate
      best_key = candidate_key
    end
    index += 1
  end
  some(best)
end

def min_by_string(list: List[A], key: Fn[A, String]) -> Optional[A]
  return none if list.size == 0
  best = list[0]
  best_key = key.call(best)
  index = 1
  while index < list.size
    candidate = list[index]
    candidate_key = key.call(candidate)
    if String.compare(candidate_key, best_key) < 0
      best = candidate
      best_key = candidate_key
    end
    index += 1
  end
  some(best)
end

def max_by_int(list: List[A], key: Fn[A, Int]) -> Optional[A]
  return none if list.size == 0
  best = list[0]
  best_key = key.call(best)
  index = 1
  while index < list.size
    candidate = list[index]
    candidate_key = key.call(candidate)
    if candidate_key > best_key
      best = candidate
      best_key = candidate_key
    end
    index += 1
  end
  some(best)
end

def max_by_float(list: List[A], key: Fn[A, Float]) -> Optional[A]
  return none if list.size == 0
  best = list[0]
  best_key = key.call(best)
  index = 1
  while index < list.size
    candidate = list[index]
    candidate_key = key.call(candidate)
    if candidate_key == candidate_key and (best_key != best_key or candidate_key > best_key)
      best = candidate
      best_key = candidate_key
    end
    index += 1
  end
  some(best)
end

def max_by_string(list: List[A], key: Fn[A, String]) -> Optional[A]
  return none if list.size == 0
  best = list[0]
  best_key = key.call(best)
  index = 1
  while index < list.size
    candidate = list[index]
    candidate_key = key.call(candidate)
    if String.compare(candidate_key, best_key) > 0
      best = candidate
      best_key = candidate_key
    end
    index += 1
  end
  some(best)
end

def empty(list: List[A]) -> Bool = list.size == 0

# An empty list fails on the index, exactly like list[0].
def first(list: List[A]) -> A = list[0]

# On an empty list the index is -1, which is out of range the same way.
def last(list: List[A]) -> A = list[list.size - 1]

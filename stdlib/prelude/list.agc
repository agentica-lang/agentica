## The List methods of the compiler prelude (docs/future/25-ruby-typed-idioms.md 25.6). Not a module: no program
## imports it. The checker reads a call of xs.find do |x| ... end, picks the function here that the catalog row names,
## and the compiler adds it to the program (check/prelude_files.agc). A is the element type, B the type a callback
## gives, K a key that is an Int or a String; the checker has checked the call, so these names stand for the real
## types. A runtime error of a function here is reported at the call of the program, not in this file.
##
## Cost: each function is O(n) in the steps of the VM and calls its callback once for each element, from the first to
## the last. Nothing here calls concat, take, drop, reverse, sort, sort_by, Map.keys, Map.values or Map.delete inside a
## loop or a callback (tests/test_stdlib_prelude.py reads this file for them), so no function is quadratic.

def find(list: List[A], f: Fn[A, Bool]) -> Result[A]
  for item in list
    if f.call(item)
      return ok(item)
    end
  end
  return error("not found")
end

def each_with_index(list: List[A], f: Fn[A, Int, Void]) -> Void
  index = 0
  for item in list
    f.call(item, index)
    index += 1
  end
end

def flat_map(list: List[A], f: Fn[A, List[B]]) -> List[B]
  found: List[B] = []
  for item in list
    for part in f.call(item)
      found = found.push(part)
    end
  end
  return found
end

def partition(list: List[A], f: Fn[A, Bool]) -> List[List[A]]
  accepted: List[A] = []
  rejected: List[A] = []
  for item in list
    if f.call(item)
      accepted = accepted.push(item)
    else
      rejected = rejected.push(item)
    end
  end
  return [accepted, rejected]
end

# One scan for the length of the prefix, then one take: f is not called after the first false.
def take_while(list: List[A], f: Fn[A, Bool]) -> List[A]
  count = 0
  for item in list
    if !f.call(item)
      break
    end
    count += 1
  end
  return list.take(count)
end

def drop_while(list: List[A], f: Fn[A, Bool]) -> List[A]
  count = 0
  for item in list
    if !f.call(item)
      break
    end
    count += 1
  end
  return list.drop(count)
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
  return slices
end

# The groups and their elements keep the order of first appearance.
def group_by(list: List[A], key: Fn[A, K]) -> Map[K, List[A]]
  groups: Map[K, List[A]] = {}
  for item in list
    name = key.call(item)
    groups = groups.put(name, groups.get(name, []).push(item))
  end
  return groups
end

def tally(list: List[K]) -> Map[K, Int]
  counts: Map[K, Int] = {}
  for item in list
    counts = counts.put(item, counts.get(item, 0) + 1)
  end
  return counts
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
  return found
end

def sum_int(list: List[Int]) -> Int
  total = 0
  for item in list
    total += item
  end
  return total
end

def sum_float(list: List[Float]) -> Float
  total = 0.0
  for item in list
    total += item
  end
  return total
end

# min_by and max_by: the first element wins a tie, so a later key must be strictly better. A NaN key never wins, unless
# every key is NaN, and then the first element stays (candidate == candidate is false for NaN). Strings compare by
# String.compare, the order of sort.
def min_by_int(list: List[A], key: Fn[A, Int]) -> Result[A]
  if list.size == 0
    return error("the list is empty")
  end
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
  return ok(best)
end

def min_by_float(list: List[A], key: Fn[A, Float]) -> Result[A]
  if list.size == 0
    return error("the list is empty")
  end
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
  return ok(best)
end

def min_by_string(list: List[A], key: Fn[A, String]) -> Result[A]
  if list.size == 0
    return error("the list is empty")
  end
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
  return ok(best)
end

def max_by_int(list: List[A], key: Fn[A, Int]) -> Result[A]
  if list.size == 0
    return error("the list is empty")
  end
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
  return ok(best)
end

def max_by_float(list: List[A], key: Fn[A, Float]) -> Result[A]
  if list.size == 0
    return error("the list is empty")
  end
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
  return ok(best)
end

def max_by_string(list: List[A], key: Fn[A, String]) -> Result[A]
  if list.size == 0
    return error("the list is empty")
  end
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
  return ok(best)
end

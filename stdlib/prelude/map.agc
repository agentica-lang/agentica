## The Map methods of the compiler prelude (see list.agc). K is the key type and V the value type. Both functions walk
## the keys in insertion order, taken once before the loop, and call their callback once for each entry.

def each(map: Map[K, V], f: Fn[K, V, Void]) -> Void
  keys = map.keys
  for key in keys
    f.call(key, map[key])
  end
end

def filter(map: Map[K, V], f: Fn[K, V, Bool]) -> Map[K, V]
  keys = map.keys
  kept: Map[K, V] = {}
  for key in keys
    value = map[key]
    if f.call(key, value)
      kept = kept.put(key, value)
    end
  end
  return kept
end

def empty(map: Map[K, V]) -> Bool
  return map.size == 0
end

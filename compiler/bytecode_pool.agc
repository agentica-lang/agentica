## A table of entries the writer interns while it walks the program: the constants, the struct updates, the builtins
## and the spans. An entry is found by a text key, and the table keeps the bytes of its entries in the order they were
## added, which is the order of the section in the file.

import Bytes from "bytecode_bytes"

## The entries added so far. index maps a key to the number of its first item. count is the number of items: an entry
## is one item, except a run of spans, which is one item for each span.
export struct Pool
  index: Map[String, Int]
  chunks: List[List[Int]]
  count: Int
end

## A pool and the number of an item of it.
export struct Interned
  pool: Pool
  id: Int
end

## A pool with no entry.
export def empty() -> Pool
  return Pool(index: {}, chunks: Bytes.start(), count: 0)
end

## The pool with a new entry for the key: its bytes, and how many items it adds. The first item of the entry is
## numbered pool.count of the pool before.
export def add(pool: Pool, key: String, bytes: List[Int], items: Int) -> Pool
  return Pool(index: pool.index.put(key, pool.count), chunks: Bytes.add(pool.chunks, bytes), count: pool.count + items)
end

## The item of an entry with one item, added when the key is new: its number, and the pool that holds it.
export def intern(pool: Pool, key: String, bytes: List[Int]) -> Interned
  if pool.index.has_key?(key)
    return Interned(pool: pool, id: pool.index[key])
  end
  return Interned(pool: add(pool, key, bytes, 1), id: pool.count)
end

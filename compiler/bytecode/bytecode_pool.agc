## A table of entries the writer interns while it walks the program: the constants, the struct updates, the builtins
## and the spans. An entry is found by a text key, and the table keeps the bytes of its entries in the order they were
## added, which is the order of the section in the file.

import Wire from "bytecode_bytes"

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
  return Pool(index: {}, chunks: Wire.start(), count: 0)
end

## The pool with a new entry for the key: its bytes, and how many items it adds. The first item of the entry is
## numbered pool.count of the pool before.
export def add(pool: Pool, key: String, bytes: List[Int], items: Int) -> Pool
  return Pool(index: pool.index.put(key, pool.count), chunks: Wire.add(pool.chunks, bytes), count: pool.count + items)
end

## The number of the first item of the entry for the key, or an error when the pool has no such entry. Callers build
## the bytes of an entry only after this fails, so a key that is already there costs no bytes.
export def find(pool: Pool, key: String) -> Result[Int]
  return pool.index.get(key)
end

## The item of an entry with one item, added when the key is new: its number, and the pool that holds it.
export def intern(pool: Pool, key: String, bytes: List[Int]) -> Interned
  found = find(pool, key)
  if found.ok?
    return Interned(pool: pool, id: found.unwrap!)
  end

  return Interned(pool: add(pool, key, bytes, 1), id: pool.count)
end

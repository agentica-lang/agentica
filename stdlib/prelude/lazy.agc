## The Lazy methods of the compiler prelude (docs/grammar/06b-builtins.md, `Lazy[T]`). Not a module: no
## program imports it. A Lazy is an immutable recipe: a source (a list, a range, Lazy.produce, File.foreach,
## File.chunks or ch.lazy) and the steps added after it. The functions here only give the generic signatures; the VM
## (vm/lazy.c) builds the recipe and runs it. A step returns a new Lazy and runs nothing. A terminal (to_a, first,
## each, reduce, find, write_lines, write_bytes) pulls one item at a time from the source through every step, so no
## step builds a list of all the items, and an endless source ends as soon as a take, take_while, first or find has
## what it needs. Two terminals on the same Lazy run the source twice; a channel cannot be read twice, so a second
## terminal on ch.lazy goes on with the values the first did not take. A failed `try` in any block of a Lazy method
## ends the pipeline: the terminal returns its error (the checker marks those `try`s and the lowering emits try-step
## for them).
##
## A is the item type and B the type a callback gives. The Int after the Lazy in __lazy_test, __lazy_count,
## __lazy_group and __lazy_zlib picks the step; vm/lazy.c reads the same numbers. The defaults of File.chunks, the
## zlib steps and write_bytes are in their catalog rows: a call always passes every argument here.
##
## Cost: each item pulled from the source costs one step, and each callback a step plus its body, as in Range.each.
## A terminal can be switched out between items, so --max-steps, the turns of other tasks and a cancel reach it.

private

def from_list(list: List[A]) -> Lazy[A] = __lazy_list(list)

def from_range(range: Range) -> Lazy[Int] = __lazy_range(range)

def produce(seed: A, block: Fn[A, A]) -> Lazy[A] = __lazy_produce(seed, block)

# File.foreach. Argument 1 of the call is buffer_bytes: a size outside 1024..16777216 is reported there. The file opens
# only in a terminal, which closes it before it returns.
def from_file(path: String, buffer_bytes: Int, timeout_ms: Int) -> Lazy[String]
  __lazy_file(path, buffer_bytes, timeout_ms)
end

# File.chunks. Argument 1 of the call is size: a size outside 1..16777216 is reported there. The file opens only in a
# terminal, which closes it before it returns.
def from_chunks(path: String, size: Int, timeout_ms: Int) -> Lazy[Bytes] = __lazy_chunks(path, size, timeout_ms)

# ch.lazy. Argument 1 of the call is timeout_ms: a negative timeout is reported there.
def from_channel(channel: Channel[A], timeout_ms: Int) -> Lazy[A] = __lazy_channel(channel, timeout_ms)

def map(lazy: Lazy[A], block: Fn[A, B]) -> Lazy[B] = __lazy_map(lazy, block)

def filter(lazy: Lazy[A], block: Fn[A, Bool]) -> Lazy[A] = __lazy_test(lazy, 0, block)

def take_while(lazy: Lazy[A], block: Fn[A, Bool]) -> Lazy[A] = __lazy_test(lazy, 1, block)

def drop_while(lazy: Lazy[A], block: Fn[A, Bool]) -> Lazy[A] = __lazy_test(lazy, 2, block)

# Argument 1 of the call is count: a negative count is reported there.
def take(lazy: Lazy[A], count: Int) -> Lazy[A] = __lazy_count(lazy, 0, count)

def drop(lazy: Lazy[A], count: Int) -> Lazy[A] = __lazy_count(lazy, 1, count)

# Argument 1 of the call is size: a size below 1 is reported there.
def each_slice(lazy: Lazy[A], size: Int) -> Lazy[List[A]] = __lazy_group(lazy, 0, size)

def each_cons(lazy: Lazy[A], size: Int) -> Lazy[List[A]] = __lazy_group(lazy, 1, size)

def with_index(lazy: Lazy[A], block: Fn[A, Int, B]) -> Lazy[B] = __lazy_with_index(lazy, block)

def flat_map(lazy: Lazy[A], block: Fn[A, List[B]]) -> Lazy[B] = __lazy_flat_map(lazy, block)

def chunk_while(lazy: Lazy[A], block: Fn[A, A, Bool]) -> Lazy[List[A]] = __lazy_chunk_while(lazy, block)

# The zlib steps: __lazy_zlib(lazy, kind, level, max_bytes) with kind 0 deflate, 1 raw deflate, 2 gzip, 3 inflate,
# 4 raw inflate, 5 gunzip. A bad level or max_bytes is the error of the terminal, as in Zlib.deflate.
def deflate(lazy: Lazy[Bytes], level: Int, raw: Bool) -> Lazy[Bytes]
  return __lazy_zlib(lazy, 1, level, 0) if raw

  __lazy_zlib(lazy, 0, level, 0)
end

def gzip(lazy: Lazy[Bytes], level: Int) -> Lazy[Bytes] = __lazy_zlib(lazy, 2, level, 0)

def inflate(lazy: Lazy[Bytes], raw: Bool, max_bytes: Int) -> Lazy[Bytes]
  return __lazy_zlib(lazy, 4, 0, max_bytes) if raw

  __lazy_zlib(lazy, 3, 0, max_bytes)
end

def gunzip(lazy: Lazy[Bytes], max_bytes: Int) -> Lazy[Bytes] = __lazy_zlib(lazy, 5, 0, max_bytes)

def to_a(lazy: Lazy[A]) -> Result[List[A]] = __lazy_to_a(lazy)

# first(n) is take(n) then to_a: the source stops after the n-th item.
def first(lazy: Lazy[A], count: Int) -> Result[List[A]] = __lazy_to_a(__lazy_count(lazy, 0, count))

def each(lazy: Lazy[A], block: Fn[A, Result[Void]]) -> Result[Void] = __lazy_each(lazy, block)

def reduce(lazy: Lazy[A], initial: B, block: Fn[B, A, B]) -> Result[B] = __lazy_reduce(lazy, initial, block)

def find(lazy: Lazy[A], block: Fn[A, Bool]) -> Result[A] = __lazy_find(lazy, block)

# write_lines. The path and timeout are checked when the terminal starts, as for File.foreach: a bad one is its error.
def write_lines(lazy: Lazy[String], path: String, timeout_ms: Int) -> Result[Void]
  __lazy_write_lines(lazy, path, timeout_ms)
end

# write_bytes. As for write_lines, the path and timeout are checked when the terminal starts.
def write_bytes(lazy: Lazy[Bytes], path: String, timeout_ms: Int) -> Result[Int]
  __lazy_write_bytes(lazy, path, timeout_ms)
end

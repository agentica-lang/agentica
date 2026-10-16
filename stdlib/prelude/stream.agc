## The Stream methods of the compiler prelude. These wrappers keep the public
## signatures generic; the VM runs the source and transformation steps in
## `vm/lazy_stream.c`.

def each(stream: Stream[T], f: Fn[T, Result[Void]]) -> Result[Void]
  return __stream_each(stream, f)
end

def map(stream: Stream[A], f: Fn[A, B]) -> Stream[B]
  return __stream_map(stream, f)
end

def iterate(seed: T, next: Fn[T, T]) -> Stream[T]
  return __stream_iterate(seed, next)
end

def reduce(stream: Stream[T], initial: A, f: Fn[A, T, A]) -> Result[A]
  return __stream_reduce(stream, initial, f)
end

def filter(stream: Stream[T], f: Fn[T, Bool]) -> Stream[T]
  return __stream_filter(stream, f)
end

def take(stream: Stream[T], count: Int) -> Stream[T]
  return __stream_take(stream, count)
end

def take_while(stream: Stream[T], f: Fn[T, Bool]) -> Stream[T]
  return __stream_take_while(stream, f)
end

def to_list(stream: Stream[T], max: Int) -> Result[List[T]]
  return __stream_to_list(stream, max)
end

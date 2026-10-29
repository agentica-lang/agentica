## The Bytes methods of the compiler prelude (see list.agc).

def each(bytes: Bytes, f: Fn[Int, Void]) -> Void
  for byte in bytes
    f.call(byte)
  end
end

def empty(bytes: Bytes) -> Bool
  return bytes.length == 0
end

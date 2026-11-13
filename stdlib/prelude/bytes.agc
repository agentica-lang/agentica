## The Bytes methods of the compiler prelude (see list.agc).

def each(bytes: Bytes, block: Fn[Int, Void]) -> Void
  for byte in bytes
    block.call(byte)
  end
end

def empty(bytes: Bytes) -> Bool = bytes.length == 0

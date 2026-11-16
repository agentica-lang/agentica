# Bytes.build writes every kind of value into one Bytes; a later build does not change an earlier result, a build
# inside a build has its own buffer, and a builder used by another task fails that task.
struct Point
  x: Int
  y: Float
end

def reply(items: List[Bytes]) -> Bytes
  Bytes.build do |out|
    out.write("*", items.size, "\r\n")
    items.each do |item|
      out.write("$", item.size, "\r\n", item, "\r\n")
    end
  end
end

def text(data: Bytes) -> String = String.from_bytes(data).unwrap!

def main() -> Void
  first = reply(["GET".bytes, "".bytes, "ñ".bytes])
  second = reply(["x".bytes])
  puts(first.to_a)
  puts(second.to_a)
  mixed = Bytes.build do |out|
    out.write(-42, " ", 1.5, " ", true, " ", nil, " ")
    out.write([1, 2], " ", Point(x: 1, y: 2.0), " ", some(3), " ", "ab".bytes)
  end
  puts(text(mixed))
  empty = Bytes.build do |_out|
    nil
  end
  puts(empty == "".bytes)
  outer = Bytes.build do |out|
    out.write("<")
    inner = Bytes.build do |nested|
      nested.write("inner")
    end
    out.write(inner, ">")
  end
  puts(text(outer))
  long = Bytes.build do |out|
    300.times do |k|
      out.write(k % 10)
    end
  end
  puts("#{long.length} #{long.take(12).to_a}")
  shared = Bytes.build do |out|
    task = Task.spawn do
      out.write("x")
      ok(1)
    end
    result: Result[Int] = Task.await(task)
    puts(result.message)
    out.write("kept")
  end
  puts(text(shared))
end

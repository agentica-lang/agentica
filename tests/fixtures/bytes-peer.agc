# Reads one case a line on stdin and prints one answer a line; tests/test_vm_bytes.py compares the answers with
# Python's bytes. A line is comma-separated: the operation, then its arguments. A Bytes argument is hex text (empty for
# no bytes) and the other arguments are Ints. The answer is hex for a Bytes, and the Int or Bool as text.
#
#   plus,A,B           A + B
#   concat,A,B,C       Bytes.concat([A, B, C])
#   slice,A,start,len  A.slice(start, len)
#   take,A,n           A.take(n)
#   drop,A,n           A.drop(n)
#   equal,A,B          "A == B" then "A != B"
#   at,A,i             A.at(i), and A[i]
#   items,A,B,C,D      how many distinct values the Set of the four and the Map of the four keys hold
#   from_list,N,N,...  Bytes.from_list of the Ints: the hex, or "error"
#   to_a,A             the bytes as Ints
#   text,N,M,A         "$#{N}\r\n#{M}:#{text}".bytes and "#{N}".bytes, with text the UTF-8 String of A
#   parts,A,...,I      Bytes.concat of a literal of [A], [A, B], [A..H] and [A..I], A + B + C, A + ... + I, and
#                      Bytes.concat of a List that is not a literal, space-separated
#   build,N,T,A,...    Bytes.build of the RESP array of the Bytes A..., each written with N (an Int) and T (a String)
#                      before it: "*count\r\n", then "$size\r\n" A "\r\nN T\r\n" for each
def bytes_of(hex: String) -> Bytes
  return OpenSSL.Digest.hexdecode(hex).unwrap!
end

def hex_of(data: Bytes) -> String
  return OpenSSL.Digest.hexencode(data)
end

def answer(fields: List[String]) -> String
  op = fields[0]
  if op == "plus"
    return hex_of(bytes_of(fields[1]) + bytes_of(fields[2]))
  elsif op == "concat"
    return hex_of(Bytes.concat([bytes_of(fields[1]), bytes_of(fields[2]), bytes_of(fields[3])]))
  elsif op == "slice"
    return hex_of(bytes_of(fields[1]).slice(fields[2].to_i!, fields[3].to_i!))
  elsif op == "take"
    return hex_of(bytes_of(fields[1]).take(fields[2].to_i!))
  elsif op == "drop"
    return hex_of(bytes_of(fields[1]).drop(fields[2].to_i!))
  elsif op == "equal"
    left = bytes_of(fields[1])
    right = bytes_of(fields[2])
    return "#{left == right} #{left != right}"
  elsif op == "at"
    data = bytes_of(fields[1])
    index = fields[2].to_i!
    return "#{data.at(index)} #{data[index]}"
  elsif op == "items"
    keys = [bytes_of(fields[1]), bytes_of(fields[2]), bytes_of(fields[3]), bytes_of(fields[4])]
    table: Map[Bytes, Int] = {}
    for key in keys
      table = table.put(key, 1)
    end

    return "#{Set.new(keys).size} #{table.size}"
  elsif op == "text"
    first = fields[1].to_i!
    second = fields[2].to_i!
    text = String.from_bytes(bytes_of(fields[3])).unwrap!
    return "#{hex_of("$#{first}\r\n#{second}:#{text}".bytes)} #{hex_of("#{first}".bytes)}"
  elsif op == "parts"
    p = fields.drop(1).map do |field: String| bytes_of(field) end
    made = [
      Bytes.concat([p[0]]),
      Bytes.concat([p[0], p[1]]),
      Bytes.concat([p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]]),
      Bytes.concat([p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8]]),
      p[0] + p[1] + p[2],
      p[0] + p[1] + p[2] + p[3] + p[4] + p[5] + p[6] + p[7] + p[8],
      Bytes.concat(p),
    ]
    return made.map { |data: Bytes| hex_of(data) }.join(" ")
  elsif op == "build"
    number = fields[1].to_i!
    text = String.from_bytes(bytes_of(fields[2])).unwrap!
    items = fields.drop(3).map do |field: String| bytes_of(field) end
    made = Bytes.build do |out|
      out.write("*", items.size, "\r\n")
      for item in items
        out.write("$", item.size, "\r\n", item, "\r\n")
        out.write(number, " ", text, "\r\n")
      end
    end
    return hex_of(made)
  elsif op == "from_list"
    numbers = fields.drop(1).map do |text: String| text.to_i! end
    made = Bytes.from_list(numbers)
    if made.ok?
      return hex_of(made.unwrap!)
    end

    return "error"
  end

  return bytes_of(fields[1]).to_a.map { |byte: Int| byte.to_s }.join(" ")
end

def main() -> Void
  for line in IO.read().split("\n")
    if line.length > 0
      puts(answer(line.split(",")))
    end
  end
end

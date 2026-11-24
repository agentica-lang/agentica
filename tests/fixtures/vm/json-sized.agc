# The narrow integer types in JSON.schema (minimum and maximum per type), JSON.encode, a field default, a List target
# of JSON.decode, and as Map keys and Set elements.
struct Pixel
  r: UInt8
  g: UInt8 = 7
  depth: Int16
  id: Int32
  tiny: Int8
  port: JSON.Field[UInt16]
  count: Optional[UInt32]
end

def main() -> Void
  puts(JSON.schema(Pixel))
  text = "{\"r\": 255, \"depth\": -32768, \"id\": 2147483647, \"tiny\": -128, \"count\": 4294967295}"
  pixel = JSON.decode(text, Pixel)
  puts(pixel)
  puts(JSON.encode(pixel.unwrap!))
  puts(JSON.decode("[0, 255]", List[UInt8]))
  puts(JSON.decode("{\"a\": 65536}", Map[String, UInt16]))

  seen: Map[UInt8, String] = {255: "max", 0: "min"}
  seen = seen.put(7, "seven")
  puts(seen)
  puts(seen[255])
  puts(seen.get(1, "none"))
  ids: Set[Int32] = Set.new([-2147483648, 1, 1])
  puts(ids.include?(-2147483648))
  puts(ids.add(2).size)
  bytes: List[UInt8] = [3, 1, 3]
  puts(bytes.tally)
  puts(bytes.uniq)
end

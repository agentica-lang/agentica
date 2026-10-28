struct Reading
  label: String
  value: Float
end

def read_as[T](codec: JSON.Codec[T], text: String) -> Result[T]
  return codec.decode(text)
end

def write_as[T](codec: JSON.Codec[T], value: T) -> String
  return codec.encode(value)
end

def main() -> Void
  codec = JSON.codec(Reading)
  reading = read_as(codec, "{\"label\":\"t\",\"value\":1.5}").unwrap!
  puts(write_as(codec, reading))
  tree = codec.from(reading)
  puts(codec.decode(tree).unwrap!.label)
end

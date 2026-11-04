# JSON for enums: the tagged-object form {"tag": "Variant", "values": [...]} for encode, from, decode, schema and a
# codec, the paths of its errors, generic and recursive enums, and the round trip (encode, then decode, gives the value).
enum Shape
  Circle(Float)
  Rect(Float, Float)
  Label(String, Optional[Int])
  Group(List[Shape])
  Empty
end

struct Drawing
  name: String
  main: Shape
  shapes: List[Shape]
  by_name: Map[String, Shape]
  spare: Optional[Shape]
end

enum Maybe[T]
  Just(T)
  Nothing
end

enum Wide
  V00
  V01
  V02
  V03
  V04
  V05
  V06
  V07
  V08
  V09
  V10
  V11
  V12
  V13
  V14
  V15
  V16
  V17
  V18
  V19
  V20
  V21
end

def to_json[T](value: T) -> String
  return JSON.encode(value)
end

def body_as[T](codec: JSON.Codec[T], text: String) -> Result[T]
  return codec.decode(text)
end

def round_trip(shape: Shape) -> Void
  text = JSON.encode(shape)
  puts("#{text} #{JSON.decode(JSON.parse(text).unwrap!, Shape).unwrap! == shape}")
end

def main() -> Void
  shapes = [
    Shape.Circle(2.0),
    Shape.Rect(1.5, -3.0),
    Shape.Label("a\"b", some(7)),
    Shape.Label("none", none),
    Shape.Group([Shape.Empty, Shape.Group([])]),
    Shape.Empty,
  ]
  for shape in shapes
    round_trip(shape)
  end

  drawing = Drawing(
    name: "d",
    main: Shape.Empty,
    shapes: [Shape.Circle(1.0), Shape.Group([Shape.Circle(2.0)])],
    by_name: {"b": Shape.Rect(1.0, 2.0)},
    spare: some(Shape.Empty),
  )
  text = JSON.encode(drawing)
  puts(text)
  puts(JSON.decode(text, Drawing).unwrap! == drawing)
  puts(JSON.from(drawing))

  found: Maybe[List[Int]] = Maybe.Just([1, 2])
  nothing: Maybe[Int] = Maybe.Nothing
  puts(to_json(found))
  puts(to_json(nothing))
  puts(JSON.from(found))

  puts(JSON.decode("{\"tag\":\"Empty\"}", Shape))
  puts(JSON.decode("{\"tag\":\"Empty\",\"values\":[],\"extra\":1}", Shape))
  puts(JSON.decode("{\"values\":[1.0],\"tag\":\"Circle\"}", Shape))
  puts(body_as(JSON.codec(Shape), "{\"tag\":\"Circle\",\"values\":[3]}"))
  puts(JSON.codec(Shape).encode(Shape.Rect(1.0, 2.0)))

  puts(JSON.decode("[]", Shape))
  puts(JSON.decode("{}", Shape))
  puts(JSON.decode("{\"tag\":1}", Shape))
  puts(JSON.decode("{\"tag\":\"Square\"}", Shape))
  puts(JSON.decode("{\"tag\":\"Circle\"}", Shape))
  puts(JSON.decode("{\"tag\":\"Circle\",\"values\":3}", Shape))
  puts(JSON.decode("{\"tag\":\"Circle\",\"values\":[]}", Shape))
  puts(JSON.decode("{\"tag\":\"Empty\",\"values\":[1]}", Shape))
  puts(JSON.decode("{\"tag\":\"Rect\",\"values\":[1.0,\"x\"]}", Shape))
  puts(JSON.decode("{\"tag\":\"Label\",\"values\":[\"a\",\"b\"]}", Shape))
  puts(JSON.decode("{\"tag\":\"Group\",\"values\":[[{\"tag\":\"Empty\"},{\"tag\":\"Nope\"}]]}", Shape))
  puts(JSON.decode("{\"name\":\"d\",\"main\":{\"tag\":\"Empty\"},\"shapes\":[],\"by_name\":{\"k\":{\"tag\":\"Circle\"}}}", Drawing))
  puts(JSON.decode("{\"name\":\"d\",\"main\":{\"tag\":\"Empty\"},\"shapes\":[{\"tag\":\"Rect\",\"values\":[1,true]}],\"by_name\":{}}", Drawing))
  puts(JSON.decode("{\"name\":\"d\",\"main\":{\"tag\":\"Empty\"},\"shapes\":[],\"by_name\":{},\"spare\":5}", Drawing))

  puts(JSON.decode("{\"tag\":\"Nope\"}", Wide))

  puts(JSON.schema(Shape))
  puts(JSON.schema(Drawing).get("$defs").unwrap!.get("Shape").unwrap!.get("oneOf").unwrap!.list.unwrap!.size)
  puts(JSON.schema(Drawing).get("properties").unwrap!.get("spare").unwrap!)
end

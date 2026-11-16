# JSON.decode and a codec give a field's default for a missing key: of each kind of default, a constant's value, in a
# nested struct, a generic struct instance and an enum payload. null stays an error, and JSON.schema leaves the field
# out of "required".
LIMIT = 10

enum Mode
  Fast
  Slow
end

struct Settings
  mode: Mode = Mode.Slow
  limit: Int = LIMIT
  low: Int = -9223372036854775808
  ratio: Float = -0.25
  verbose: Bool = true
  name: String = "default"
  tags: List[String] = []
  sizes: Map[String, Int] = {}
end

struct Box[T]
  value: T
  label: String = "box"
end

struct Health
  ok: Bool
  wire: String = ""
  settings: Settings
end

enum Event
  Changed(Settings)
  Gone
end

def main() -> Void
  puts(JSON.decode("{\"ok\": true, \"settings\": {}}", Health))
  puts(
    JSON.decode(
      "{\"ok\": true, \"wire\": \"w\", \"settings\": {\"mode\": {\"tag\": \"Fast\"}, \"limit\": 2}}",
      Health,
    ),
  )

  puts(JSON.decode("{\"ok\": true, \"wire\": null, \"settings\": {}}", Health))
  puts(JSON.decode("{\"settings\": {}}", Health))
  puts(JSON.decode("{\"value\": 3}", Box[Int]))
  puts(JSON.decode("[{\"value\": \"a\"}, {\"value\": \"b\", \"label\": \"c\"}]", List[Box[String]]))
  puts(JSON.decode("{\"tag\": \"Changed\", \"values\": [{\"verbose\": false}]}", Event))
  puts(Settings.codec.decode("{\"name\": \"x\"}"))
  health = Health(ok: false, wire: "z", settings: Settings(tags: ["t"], sizes: {"a": 1}))
  puts(JSON.decode(JSON.encode(health), Health).unwrap! == health)
  puts(JSON.encode(JSON.schema(Health)))
end

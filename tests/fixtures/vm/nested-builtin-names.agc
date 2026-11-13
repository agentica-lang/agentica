# The builtin families (#1182) print with the names a program writes: JSON.Field.Value(3), TLS.ClientOptions(...),
# Process.Output(...), <JSON.Value>, <TCP.Listener>. A string keeps the old names as they are.
struct Patch
  age: JSON.Field[Int]
end

def main() -> Void
  value: JSON.Value = JSON.parse("[1, 2]").unwrap!
  puts(value)
  puts([value].inspect)
  puts(Patch(age: JSON.Field.Value(3)))
  puts(Patch(age: JSON.Field.Null).inspect)
  puts(TLS.ClientOptions(alpn: ["h2"]))
  puts(Process.Output(stdout: "a", stderr: "", truncated: false))
  listener: TCP.Listener = TCP.listen("127.0.0.1", 0).unwrap!
  IO.inspect(listener)
  TCP.close_listener(listener)
  steps = System.Profile.measure("steps") do System.Profile.steps() end
  puts(steps > 0)
  puts("Json JsonField FileInfo FileHandle ProcessOutput Socket Listener TlsContext TestCase Profile.steps")
end

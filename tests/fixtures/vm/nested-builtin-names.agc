# A nested builtin name (#1182) is the old builtin: the linker turns JSON.Field.Value into JsonField.Value and
# System.Profile.steps into Profile.steps, so a value of either name is one type.
struct Patch
  age: JSON.Field[Int]
end

def label(f: JSON.Field[Int]) -> String
  return case f
    JSON.Field.Absent -> "keep"
    JSON.Field.Null -> "clear"
    JSON.Field.Value(n) -> "set #{n}"
  end
end

def main() -> Void
  value: JSON.Value = JSON.parse("[1, 2]").unwrap!
  old: Json = value
  puts(old)
  puts(label(Patch(age: JSON.Field.Value(3)).age))
  puts(label(JSON.Field.Null))
  options: TlsClientOptions = TLS.ClientOptions(alpn: ["h2"])
  puts(options.alpn)
  first = System.Profile.steps()
  inside = System.Profile.measure("steps") do System.Profile.steps() end
  piped = "pipe" |> System.Profile.measure() do 4 end
  puts(inside > first and piped == 4)
end

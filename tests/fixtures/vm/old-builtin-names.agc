# JsonField, FileInfo and ProcessOutput, the old names of JSON.Field, File.Info and Process.Output, are user types
# next to the builtin ones: a user JsonField keeps the JSON form of a plain enum, JSON.Field keeps its own.
import Old from "lib/old_builtin_names"

enum JsonField
  Absent
  Null
  Value(Int)
end

struct Box
  mine: JsonField
  theirs: Old.JsonField
  real: JSON.Field[Int]
end

def main() -> Void
  box = Box(mine: JsonField.Value(2), theirs: Old.JsonField.Null, real: JSON.Field.Absent)
  puts(box)
  puts(JSON.encode(box))
  puts(JSON.encode(Box(mine: JsonField.Absent, theirs: Old.JsonField.Value(1), real: JSON.Field.Null)))
  text = "{\"mine\": {\"tag\": \"Null\", \"values\": []}, \"theirs\": {\"tag\": \"Absent\", \"values\": []}, \"real\": 7}"
  puts(JSON.decode(text, Box).unwrap!)
  info = File.stat(".").unwrap!
  puts(Old.FileInfo(kind: info.kind, size_bytes: 1, modified_seconds: 2, mode: 3, user_id: 4, group_id: 5))
  puts(Old.ProcessOutput(stdout: "a", stderr: "b", truncated: false))
  puts(Process.Output(stdout: "a", stderr: "b", truncated: false))
end

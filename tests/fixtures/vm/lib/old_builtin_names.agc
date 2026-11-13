# The old names of File.Info and Process.Output, free since #1491, as a module's own types.

struct FileInfo
  kind: String
  size_bytes: Int
  modified_seconds: Int
  mode: Int
  user_id: Int
  group_id: Int
end

struct ProcessOutput
  stdout: String
  stderr: String
  truncated: Bool
end

enum JsonField
  Absent
  Null
  Value(Int)
end

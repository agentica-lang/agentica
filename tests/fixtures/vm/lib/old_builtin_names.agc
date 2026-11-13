# The old names of File.Info and Process.Output, free since #1491, as a module's own types.

export struct FileInfo
  kind: String
  size_bytes: Int
  modified_seconds: Int
  mode: Int
  user_id: Int
  group_id: Int
end

export struct ProcessOutput
  stdout: String
  stderr: String
  truncated: Bool
end

export enum JsonField
  Absent
  Null
  Value(Int)
end

## Test driver of tests/test_std_archive.py and tests/test_std_archive_zip.py: reads one JSON case per line of stdin,
## runs one extraction of std/archive and prints one line `<label> ok <counts>` or `<label> error <message>`.

import Archive from "std/archive"

struct Limits
  timeout_ms: Int
  max_output_bytes: Int
end

# `kind` is "zip", "tar" or "defaults" (the default Options). With no `options` the call leaves the argument to its
# default.
struct Case
  label: String
  kind: String
  src: String
  members: List[String]
  dest: String
  options: Optional[Limits]
end

def flat(text: String) -> String = text.split("\n").join(" | ")

def extract(c: Case) -> Result[List[Int]]
  case c.options
    some(limits) ->
      options = Archive.Options(timeout_ms: limits.timeout_ms, max_output_bytes: limits.max_output_bytes)
      return Archive.extract_zip(c.src, c.members, c.dest, options) if c.kind == "zip"
      Archive.extract_tar(c.src, c.members, c.dest, options)
    none ->
      return Archive.extract_zip(c.src, c.members, c.dest) if c.kind == "zip"
      Archive.extract_tar(c.src, c.members, c.dest)
  end
end

def run_case(c: Case) -> String
  if c.kind == "defaults"
    o = Archive.Options()
    return "#{c.label} #{o.timeout_ms} #{o.max_output_bytes}"
  end
  case extract(c)
    ok(counts) -> "#{c.label} ok #{counts}"
    error(message) -> "#{c.label} error #{flat(message)}"
  end
end

def main() -> Void
  while true
    line = IO.gets()
    return if !line.ok?
    case JSON.decode(line.unwrap!, Case)
      ok(c) -> puts(run_case(c))
      error(message) -> puts("bad case: #{message}")
    end
  end
end

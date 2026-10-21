import Analysis from "std/analysis"

# Runs the commands of its arguments in order, on one session, and prints each answer as `agentica --json` prints it.
# The session is opened with the files of the leading `buffer` commands in its workspace:
#   buffer PATH TEXTFILE   puts the text of TEXTFILE in the workspace as the buffer of PATH
#   update PATH TEXTFILE   puts the text of TEXTFILE in the buffer of PATH
#   close PATH             takes the buffer out
#   check PATH             `{"ok":true}` on stdout, or the diagnostic on stderr
#   diagnostic TEXTFILE    the diagnostic that Analysis.diagnostic reads from the JSON in TEXTFILE, written back
#   roundtrip PATH         `true` on stdout when the diagnostic of PATH, written as JSON and read back, is the same
#   refresh PATH           Analysis.refresh; prints nothing
#   stats                  `roots=R checks=C parsed=P kept=K top=T live=L`: the files of the cache, what refreshes did
#   write PATH TEXTFILE    puts the text of TEXTFILE in the file PATH of the disk (an edit that is not a buffer)
#   remove PATH            deletes the file PATH of the disk
#   compare PATH [L C]...  the last command: `same N` when the check of PATH and the type-at of each LINE COL are equal
#                          in the session and in a session opened from the same buffers with no cache (N of them
#                          answers, not errors), else `different` and the two
#   check-all PATH...      the last command: one line on stdout for each PATH, from `check` run in tasks, four at once
#   outline PATH           the JSON on stdout, or the diagnostic on stderr
#   type-at PATH LINE COL  the same
# An error is printed after Analysis.diagnostic read it and Analysis.diagnostic_json wrote it back, so the output of a
# failure also proves that the pair is the identity.
def main() -> Void
  words = System.args()
  files = Analysis.workspace()
  at = 0
  while at < words.size and words[at] == "buffer"
    files = files.with(buffers: files.buffers.put(words[at + 1], File.read_text(words[at + 2], 10000).unwrap!))
    at += 3
  end
  session = Analysis.open(files)
  buffers = files.buffers
  while at < words.size
    word = words[at]
    if word == "update"
      text = File.read_text(words[at + 2], 10000).unwrap!
      session = Analysis.update(session, words[at + 1], text)
      buffers = buffers.put(words[at + 1], text)
      at += 3
    elsif word == "close"
      session = Analysis.close(session, words[at + 1])
      buffers = buffers.delete(words[at + 1])
      at += 2
    elsif word == "refresh"
      session = Analysis.refresh(session, words[at + 1])
      at += 2
    elsif word == "stats"
      puts(stats(session))
      at += 1
    elsif word == "write"
      File.write_text(words[at + 1], File.read_text(words[at + 2], 10000).unwrap!, 10000).unwrap!
      at += 3
    elsif word == "remove"
      Path.remove(words[at + 1], 10000).unwrap!
      at += 2
    elsif word == "compare"
      numbers = words.drop(at + 2).map do |number: String| number.to_i! end
      puts(compare(session, buffers, words[at + 1], numbers))
      at = words.size
    elsif word == "check"
      checked = Analysis.check(session, words[at + 1])
      if checked.passed
        puts("{\"ok\":true}")
      else
        IO.warn(JSON.encode(Analysis.diagnostic_json(checked.diagnostics[0])))
      end
      at += 2
    elsif word == "diagnostic"
      read = Analysis.diagnostic(File.read_text(words[at + 1], 10000).unwrap!)
      puts(JSON.encode(Analysis.diagnostic_json(read.unwrap!)))
      at += 2
    elsif word == "roundtrip"
      checked = Analysis.check(session, words[at + 1])
      found = checked.diagnostics[0]
      back = Analysis.diagnostic(JSON.encode(Analysis.diagnostic_json(found))).unwrap!
      puts(same(found, back))
      at += 2
    elsif word == "check-all"
      show_all(session, words.drop(at + 1))
      at = words.size
    elsif word == "outline"
      show(outlined(session, words[at + 1]))
      at += 2
    else
      line = words[at + 2].to_i!
      column = words[at + 3].to_i!
      show(typed(session, words[at + 1], line, column))
      at += 4
    end
  end
end

# The cache of the session: how many roots it holds, how many programs the refreshes linked and checked, how many files
# they parsed, how many parsed files it keeps, the first id above them all and the ids that they hold.
def stats(session: Analysis.Session) -> String
  cache = session.internal.cache
  live = 0
  for file in cache.parses.kept.values
    live += file.program.id + 1 - file.first_id
  end
  return (
    "roots=#{cache.roots.size} checks=#{cache.checks} parsed=#{cache.parsed} kept=#{cache.parses.kept.size} " +
    "top=#{cache.parses.top} live=#{live}"
  )
end

# `same N` when `session` and a session over the same buffers and no cache answer the check of `path` and the type-at
# of each (line, column) pair of `numbers` with the same text, and N of the type-at answers are not errors; else
# `different` and the two answers.
def compare(session: Analysis.Session, buffers: Map[String, String], path: String, numbers: List[Int]) -> String
  twin = Analysis.open(Analysis.workspace().with(buffers: buffers))
  ours = answers(session, path, numbers)
  theirs = answers(twin, path, numbers)
  if ours.join("\n") == theirs.join("\n")
    found = ours.filter do |line: String| line.contains?("\"command\":\"type-at\"") end
    return "same #{found.size}"
  end
  return "different\n#{ours.join("\n")}\n#{theirs.join("\n")}"
end

def answers(session: Analysis.Session, path: String, numbers: List[Int]) -> List[String]
  checked = Analysis.check(session, path)
  lines = [JSON.encode(checked.diagnostics.map do |found: Analysis.Diagnostic| Analysis.diagnostic_json(found) end)]
  for at in 0...(numbers.size / 2)
    lines = lines.push(show_text(typed(session, path, numbers[at * 2], numbers[at * 2 + 1])))
  end
  return lines
end

def show_text(answer: Result[Json]) -> String
  if answer.ok?
    return JSON.encode(answer.unwrap!)
  end
  return answer.message
end

# Structs and lists have no ==, so the fields are compared one by one, as JSON text.
def same(a: Analysis.Diagnostic, b: Analysis.Diagnostic) -> Bool
  if a.labels.size != b.labels.size
    return false
  end
  for at in 0...a.labels.size
    if a.labels[at].text != b.labels[at].text or !same_region(a.labels[at].range, b.labels[at].range)
      return false
    end
  end
  texts = [a.code, a.message, a.file, a.key_path, a.help, a.expected, a.actual, a.callee, a.function]
  others = [b.code, b.message, b.file, b.key_path, b.help, b.expected, b.actual, b.callee, b.function]
  return JSON.encode(texts) == JSON.encode(others) and same_region(a.range, b.range)
end

def same_region(a: Analysis.Region, b: Analysis.Region) -> Bool
  places = [a.start.line, a.start.column, a.stop.line, a.stop.column]
  others = [b.start.line, b.start.column, b.stop.line, b.stop.column]
  return JSON.encode(places) == JSON.encode(others)
end

def show(answer: Result[Json]) -> Void
  if answer.ok?
    puts(JSON.encode(answer.unwrap!))
    return
  end
  IO.warn(JSON.encode(Analysis.diagnostic_json(Analysis.diagnostic(answer.message).unwrap!)))
end

def outlined(session: Analysis.Session, path: String) -> Result[Json]
  found = try Analysis.outline(session, path)
  return ok(Analysis.outline_json(found))
end

def typed(session: Analysis.Session, path: String, line: Int, column: Int) -> Result[Json]
  found = try Analysis.type_at(session, path, line, column)
  return ok(Analysis.type_at_json(found))
end

# Questions of one session, asked from tasks that may run at once: the lines come back in the order of the paths.
def show_all(session: Analysis.Session, paths: List[String]) -> Void
  lines = Task.map(paths, 4, 60000) do |path: String|
    checked = Analysis.check(session, path)
    line = "{\"ok\":true}"
    if !checked.passed
      line = JSON.encode(Analysis.diagnostic_json(checked.diagnostics[0]))
    end
    ok(line)
  end
  for line in lines
    puts(line.unwrap!)
  end
end

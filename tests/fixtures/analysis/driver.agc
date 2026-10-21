import Analysis from "std/analysis"

# Runs the commands of its arguments in order, on one session, and prints each answer as `agentica --json` prints it.
# The session is opened with the files of the leading `buffer` commands in its workspace:
#   buffer PATH TEXTFILE   puts the text of TEXTFILE in the workspace as the buffer of PATH
#   update PATH TEXTFILE   puts the text of TEXTFILE in the buffer of PATH
#   close PATH             takes the buffer out
#   check PATH             `{"ok":true}` on stdout, or the diagnostic on stderr
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
  while at < words.size
    word = words[at]
    if word == "update"
      session = Analysis.update(session, words[at + 1], File.read_text(words[at + 2], 10000).unwrap!)
      at += 3
    elsif word == "close"
      session = Analysis.close(session, words[at + 1])
      at += 2
    elsif word == "check"
      checked = Analysis.check(session, words[at + 1])
      if checked.passed
        puts("{\"ok\":true}")
      else
        IO.warn(JSON.encode(Analysis.diagnostic_json(checked.diagnostics[0])))
      end
      at += 2
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

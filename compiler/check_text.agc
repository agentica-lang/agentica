## The text form of a check, for tests. See check.agc.

import Failure from "check_failure"
import State from "check_state"
import Checker from "checker"
import Diag from "diagnostic"
import Env from "link_env"
import LinkText from "link_text"
import Linker from "linker"
import Text from "text"
import T from "types"

## The text form of checking the file at path: the linked program of link_text with the type of each checked expression added at the end of its line (and, when the program has constants, a last line `constant-order ["A","B"]` with the linked names in initialization order) (` type=Int`, the types written by Types.debug_text) and, for a method call or a field access that names a builtin, ` resolved=` and what it became; or the ERROR line of the first failure. A failure of the checker has the notes of the diagnostic that are present, ` expected="..." actual="..." callee="..." signature="..." labels=[SPAN "text", ...]`, then ` file="path"`. tests/frontend-check-common.rkt prints the same text from the Racket checker.
export def check_text(path: String, settings: Env.Settings) -> String
  case Linker.link_file(path, settings)
    Linker.Linking.Failed(failure) -> return LinkText.failure_text(LinkText.root_dir_of(path), failure)
    Linker.Linking.Done(linked) -> return checked_text(linked, settings)
  end
end

def checked_text(linked: Linker.Linked, settings: Env.Settings) -> String
  case Checker.check(linked, settings.catalog)
    Checker.Checking.Done(checked) -> return LinkText.program_lines(linked, notes_of(checked)).concat(order_lines(checked)).join("\n")
    Checker.Checking.Failed(problem) -> return problem_text(linked.root_dir, problem)
  end
end

# The order the constants are initialized in, after the program, when there are constants.
def order_lines(checked: Checker.Checked) -> List[String]
  if checked.constants.size == 0
    return []
  end
  names = checked.constants.map do |name: String| Text.quote(name) end
  return ["constant-order [" + names.join(",") + "]"]
end

# The text added to the lines, by node id: the type, then the resolution.
def notes_of(checked: Checker.Checked) -> Map[Int, String]
  notes: Map[Int, String] = {}
  index = 0
  while index < checked.types.size
    if !T.unknown?(checked.types[index])
      notes = notes.put(index, " type=" + T.debug_text(checked.types[index]))
    end
    index += 1
  end
  for id in checked.resolved.keys
    before = notes.get(id)
    text = ""
    if before.ok?
      text = before.unwrap!
    end
    notes = notes.put(id, text + " resolved=" + resolved_text(checked.resolved[id]))
  end
  return notes
end

def resolved_text(resolved: State.Resolved) -> String
  case resolved
    State.Resolved.Self(type) -> return "self(" + T.debug_text(type) + ")"
    State.Resolved.Text(type) -> return "text(" + T.debug_text(type) + ")"
    State.Resolved.Inspect(type) -> return "inspect(" + T.debug_text(type) + ")"
    State.Resolved.Call(name, type) -> return "call(" + Text.quote(name) + ", " + T.debug_text(type) + ")"
  end
end

def problem_text(root_dir: String, problem: Failure.Problem) -> String
  line = Text.diagnostic_line(Diag.Diagnostic(code: problem.code, message: problem.message, span: problem.span, help: problem.help))
  line = line + note(" expected=", problem.expected) + note(" actual=", problem.actual) + note(" callee=", problem.callee) + note(" signature=", problem.signature)
  if problem.labels.size > 0
    labels = problem.labels.map do |label: Failure.Label| Text.span_text(label.span) + " " + Text.quote(label.text) end
    line = line + " labels=[" + labels.join(", ") + "]"
  end
  return line + " file=" + Text.quote(LinkText.display(root_dir, problem.file))
end

def note(label: String, text: String) -> String
  if text == ""
    return ""
  end
  return label + Text.quote(text)
end

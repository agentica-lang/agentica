## Matches step text against step patterns for `agentica test`.
##
## A pattern is plain text with `{string}` and `{int}` placeholders.

import Gherkin from "gherkin"
import Report from "std/test/report"

enum Capture
  IntCapture
  StringCapture
end

struct Slot
  capture: Capture
  literal: List[String]
end

## A compiled step pattern. `compile` builds them.
export struct Pattern
  text: String
  head: List[String]
  slots: List[Slot]
end

## The pattern a step matched: its index in the list and the values it captured.
export struct Resolved
  index: Int
  captures: List[String]
end

## Compiles the step patterns `texts`. Checks them in order and returns a failure at `where` for the first duplicate
## (`RUNTIME-BDD-DUPLICATE`) or bad pattern (`RUNTIME-BDD-PATTERN`).
export def compile(texts: List[String], where: Report.Span) -> Gherkin.Outcome[List[Pattern]]
  compiled = texts.map do |text| compile_one(text) end
  seen: Map[String, Bool] = {}
  for i in 0...texts.size
    text = texts[i]
    if seen.has_key?(text)
      return failed("RUNTIME-BDD-DUPLICATE", "duplicate step pattern", text, where)
    end
    if not compiled[i].ok?
      return failed("RUNTIME-BDD-PATTERN", compiled[i].message, text, where)
    end
    seen = seen.put(text, true)
  end
  return Gherkin.Outcome.Done(compiled.map do |pattern| pattern.unwrap! end)
end

## Finds the one pattern that matches the text of `step`. Fails with `CHECK-BDD-UNDEFINED` when none does and
## `CHECK-BDD-AMBIGUOUS` when several do.
export def resolve(patterns: List[Pattern], step: Gherkin.Step) -> Gherkin.Outcome[Resolved]
  found = patterns.map do |pattern| captures(pattern, step.text) end
  hits = 0
  first = 0
  for i in 0...found.size
    if found[i].ok?
      if hits == 0
        first = i
      end
      hits += 1
    end
  end
  if hits == 0
    return Gherkin.Outcome.Failed(
      Gherkin.Diagnostic(code: "CHECK-BDD-UNDEFINED", message: "no step definition matches", span: step.span),
    )
  end
  if hits > 1
    return Gherkin.Outcome.Failed(
      Gherkin.Diagnostic(code: "CHECK-BDD-AMBIGUOUS", message: "multiple step definitions match", span: step.span),
    )
  end
  return Gherkin.Outcome.Done(Resolved(index: first, captures: found[first].unwrap!))
end

## Matches `text` against `pattern`. Returns the captured values as strings, or an error when the text does not match.
export def captures(pattern: Pattern, text: String) -> Result[List[String]]
  chars = text.split("")
  if not literal_at?(chars, 0, pattern.head)
    return error("no match")
  end
  return walk(pattern.slots, 0, chars, pattern.head.size, [])
end

def failed(code: String, reason: String, text: String, where: Report.Span) -> Gherkin.Outcome[List[Pattern]]
  return Gherkin.Outcome.Failed(Gherkin.Diagnostic(code: code, message: "#{reason}: #{text}", span: where))
end

# Each "{" opens a placeholder only when the next brace is a "}".
def compile_one(text: String) -> Result[Pattern]
  parts = text.split("{")
  tails = parts.drop(1)
  for tail in tails
    close = tail.index_of("}")
    if close.ok? and not placeholder?(tail.slice(0, close.unwrap!))
      return error("only {string} and {int} are supported")
    end
  end
  if parts[0].include?("}")
    return error("unmatched pattern braces")
  end
  for tail in tails
    close = tail.index_of("}")
    if not close.ok? or after(tail, close.unwrap!).include?("}")
      return error("unmatched pattern braces")
    end
  end
  slots = tails.map do |tail|
    close = tail.index_of("}").unwrap!
    capture = Capture.StringCapture
    if tail.slice(0, close) == "int"
      capture = Capture.IntCapture
    end
    Slot(capture: capture, literal: after(tail, close).split(""))
  end
  return ok(Pattern(text: text, head: parts[0].split(""), slots: slots))
end

def placeholder?(kind: String) -> Bool
  return kind == "string" or kind == "int"
end

def after(text: String, close: Int) -> String
  return text.slice(close + 1, text.length - close - 1)
end

def literal_at?(chars: List[String], at: Int, literal: List[String]) -> Bool
  if at + literal.size > chars.size
    return false
  end
  for i in 0...literal.size
    if chars[at + i] != literal[i]
      return false
    end
  end
  return true
end

# Tries the captures from the regular expression's order: {int} from its longest to its shortest.
def walk(slots: List[Slot], k: Int, chars: List[String], at: Int, found: List[String]) -> Result[List[String]]
  if k == slots.size
    if at == chars.size
      return ok(found)
    end
    return error("no match")
  end
  slot = slots[k]
  case slot.capture
    Capture.StringCapture ->
      stop = quoted_end(chars, at)
      if stop > at and literal_at?(chars, stop, slot.literal)
        return walk(slots, k + 1, chars, stop + slot.literal.size, found.push(unquote(chars, at, stop)))
      end
    Capture.IntCapture ->
      start = at
      if at < chars.size and chars[at] == "-"
        start = at + 1
      end
      stop = start
      while stop < chars.size and "0123456789".include?(chars[stop])
        stop += 1
      end
      while stop > start
        if literal_at?(chars, stop, slot.literal)
          value = chars.take(stop).drop(at).join("")
          result = walk(slots, k + 1, chars, stop + slot.literal.size, found.push(value))
          if result.ok?
            return result
          end
        end
        stop -= 1
      end
  end
  return error("no match")
end

# The index after the closing quote, or `at` when there is no quoted string there.
def quoted_end(chars: List[String], at: Int) -> Int
  if at >= chars.size or (chars[at] != "\"" and chars[at] != "'")
    return at
  end
  quote = chars[at]
  i = at + 1
  while i < chars.size
    if chars[i] == quote
      return i + 1
    end
    if chars[i] == "\\"
      i += 1
    end
    i += 1
  end
  return at
end

# Splitting on escaped backslashes first leaves each other backslash just before the character it escapes.
def unquote(chars: List[String], at: Int, stop: Int) -> String
  content = chars.take(stop - 1).drop(at + 1).join("")
  if not content.include?("\\")
    return content
  end
  return content.split("\\\\").map do |part| part.replace("\\", "") end.join("\\")
end

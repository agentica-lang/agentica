## Matches step text against step patterns for `agentica test`.
##
## A pattern is plain text with `{string}` and `{int}` placeholders.

import Gherkin from "gherkin"
import Report from "std/test/report"

## A compiled step pattern. `compile` builds them.
struct Pattern
  text: String
  head: List[String]
  slots: List[Slot]
end

## The pattern a step matched: its index in the list and the values it captured.
struct Resolved
  index: Int
  captures: List[String]
end

## Compiles the step patterns `texts`. Checks them in order and returns a failure at `where` for the first duplicate
## (`RUNTIME-BDD-DUPLICATE`) or bad pattern (`RUNTIME-BDD-PATTERN`).
def compile(texts: List[String], where: Report.Span) -> Gherkin.Outcome[List[Pattern]]
  compiled = texts.map do |text| compile_one(text) end
  seen: Map[String, Bool] = {}
  for i in 0...texts.size
    text = texts[i]
    return failed("RUNTIME-BDD-DUPLICATE", "duplicate step pattern", text, where) if seen.has_key?(text)
    return failed("RUNTIME-BDD-PATTERN", compiled[i].message, text, where) if not compiled[i].ok?
    seen = seen.put(text, true)
  end
  Gherkin.Outcome.Done(compiled.map do |pattern| pattern.unwrap! end)
end

## Finds the one pattern that matches the text of `step`. Fails with `CHECK-BDD-UNDEFINED` when none does and
## `CHECK-BDD-AMBIGUOUS` when several do.
def resolve(patterns: List[Pattern], step: Gherkin.Step) -> Gherkin.Outcome[Resolved]
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
      Gherkin.Diagnostic(code: "CHECK-BDD-UNDEFINED", message: undefined_message(step.text), span: step.span),
    )
  end
  if hits > 1
    return Gherkin.Outcome.Failed(
      Gherkin.Diagnostic(code: "CHECK-BDD-AMBIGUOUS", message: "multiple step definitions match", span: step.span),
    )
  end
  Gherkin.Outcome.Done(Resolved(index: first, captures: found[first].unwrap!))
end

## Matches `text` against `pattern`. Returns the captured values as strings, or an error when the text does not match.
def captures(pattern: Pattern, text: String) -> Result[List[String]]
  chars = text.split("")
  return error("no match") if not literal_at?(chars, 0, pattern.head)
  walk(pattern.slots, 0, chars, pattern.head.size, [])
end

private

enum Capture
  IntCapture
  StringCapture
end

struct Slot
  capture: Capture
  literal: List[String]
end

# An outline leaves a `<name>` that is not an Examples column as written, so a misspelled column ends here: the text
# says so when the step still holds a `<...>`.
def undefined_message(text: String) -> String
  open = text.index_of("<")
  if open.some? and text.slice(open.unwrap!, text.length - open.unwrap!).include?(">")
    return "no step definition matches; if `<...>` is an Examples column, the table has no column of that name"
  end
  "no step definition matches"
end

def failed(code: String, reason: String, text: String, where: Report.Span) -> Gherkin.Outcome[List[Pattern]]
  Gherkin.Outcome.Failed(Gherkin.Diagnostic(code: code, message: "#{reason}: #{text}", span: where))
end

# Each "{" opens a placeholder only when the next brace is a "}".
def compile_one(text: String) -> Result[Pattern]
  parts = text.split("{")
  tails = parts.drop(1)
  for tail in tails
    close = tail.index_of("}")
    if close.some? and not placeholder?(tail.slice(0, close.unwrap!))
      return error("only {string} and {int} are supported", kind: "argument")
    end
  end
  return error("unmatched pattern braces", kind: "argument") if parts[0].include?("}")
  for tail in tails
    close = tail.index_of("}")
    if close.none? or after(tail, close.unwrap!).include?("}")
      return error("unmatched pattern braces", kind: "argument")
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

  ok(Pattern(text: text, head: parts[0].split(""), slots: slots))
end

def placeholder?(kind: String) -> Bool = kind == "string" or kind == "int"

def after(text: String, close: Int) -> String = text.slice(close + 1, text.length - close - 1)

def literal_at?(chars: List[String], at: Int, literal: List[String]) -> Bool
  return false if at + literal.size > chars.size
  for i in 0...literal.size
    return false if chars[at + i] != literal[i]
  end
  true
end

# Tries the captures from the regular expression's order: {int} from its longest to its shortest.
def walk(slots: List[Slot], k: Int, chars: List[String], at: Int, found: List[String]) -> Result[List[String]]
  if k == slots.size
    return ok(found) if at == chars.size
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
          return result if result.ok?
        end
        stop -= 1
      end
  end
  error("no match")
end

# The index after the closing quote, or `at` when there is no quoted string there.
def quoted_end(chars: List[String], at: Int) -> Int
  return at if at >= chars.size or (chars[at] != "\"" and chars[at] != "'")
  quote = chars[at]
  i = at + 1
  while i < chars.size
    return i + 1 if chars[i] == quote
    if chars[i] == "\\"
      i += 1
    end
    i += 1
  end
  at
end

# Splitting on escaped backslashes first leaves each other backslash just before the character it escapes.
def unquote(chars: List[String], at: Int, stop: Int) -> String
  content = chars.take(stop - 1).drop(at + 1).join("")
  return content if not content.include?("\\")
  parts = content.split("\\\\").map do |part| part.replace("\\", "") end
  parts.join("\\")
end

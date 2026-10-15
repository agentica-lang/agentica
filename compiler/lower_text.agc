## The text form of lowering, for tests. See lower.agc.

import Builtins from "builtins"
import CheckText from "check_text"
import Checker from "checker"
import Diag from "diagnostic"
import Ir from "ir"
import Env from "link_env"
import LinkText from "link_text"
import Linker from "linker"
import Lowering from "lowering"
import Source from "source"
import Text from "text"
import Types from "types"

## The text form of lowering the file at path: the IR as lines, or the ERROR line of the first failure of the linker,
## the checker or the lowering.
##
## `program SPAN entry=N globals=N`, then `source N "path" chars=N` for each file (the path relative to the folder of
## the root file), `struct sN "Name" ["field",...]` with ` types=[...]` when JSON can build it, `enum "Name"
## vN="Variant"/SIZE ...`, and each function as `fnN "name" params=P captures=C slots=S [entry] @ SPAN` followed by its
## instructions: a label as `  LN:` and an instruction as `    op ARGS @ SPAN ...`. A span is
## FILE:LINE:COLUMN-LINE:COLUMN, with the index of its source. A register is `rN`, a function `fnN`, a struct `sN`, a
## variant `vN`, a global `gN`, a label `LN`; a `const` shows its value as `void`, `nil`, `true`, `false`, `int:N`,
## `float:bits:N` or a quoted string. tests/frontend-lower-common.rkt prints the same text from the Racket lowering.
export def lower_text(path: String, settings: Env.Settings) -> String
  return lower_text_after(path, settings, 0)
end

## The same, with the lowering started `frames` VM calls deeper than it would be. A test uses it to show how much of
## the call depth limit the lowering of a deep tree leaves free.
export def lower_text_after(path: String, settings: Env.Settings, frames: Int) -> String
  case Linker.link_file(path, settings)
    Linker.Linking.Failed(failure) -> return LinkText.failure_text(LinkText.root_dir_of(path), failure)
    Linker.Linking.Done(linked) -> return linked_text(linked, settings, frames)
  end
end

def linked_text(linked: Linker.Linked, settings: Env.Settings, frames: Int) -> String
  case Checker.check(linked, settings.catalog)
    Checker.Checking.Failed(problem) -> return CheckText.problem_text(linked.root_dir, problem)
    Checker.Checking.Done(checked) ->
      return lowered_text(linked, lower_deeper(linked, checked, settings.catalog, frames))
  end
end

# Lowers after `frames` calls that wait for it, which are not tail calls.
def lower_deeper(
  linked: Linker.Linked, checked: Checker.Checked, catalog: Builtins.Catalog, frames: Int
) -> Lowering.Lowered
  if frames == 0
    return Lowering.lower(linked, checked, catalog)
  end
  done = lower_deeper(linked, checked, catalog, frames - 1)
  return done
end

def lowered_text(linked: Linker.Linked, lowered: Lowering.Lowered) -> String
  case lowered
    Lowering.Lowered.Failed(problem) ->
      shown = Diag.Diagnostic(code: problem.code, message: problem.message, span: problem.span, help: problem.help)
      line = Text.diagnostic_line(shown)
      return line + " file=" + Text.quote(LinkText.display(linked.root_dir, problem.file))
    Lowering.Lowered.Done(program) -> return program_lines(linked.root_dir, program).join("\n")
  end
end

def program_lines(root_dir: String, program: Ir.Program) -> List[String]
  head = "program " + span_text(0, program.span) + " entry=" + program.entry.to_s
  lines: List[String] = [head + " globals=" + program.globals.to_s]
  index = 0
  for source in program.sources
    shown = Text.quote(LinkText.display(root_dir, source.file))
    lines = lines.push("source " + index.to_s + " " + shown + " chars=" + source.text.length.to_s)
    index += 1
  end
  index = 0
  for entry in program.structs
    lines = lines.push(struct_line(index, entry))
    index += 1
  end
  id = 0
  for entry in program.enums
    names = ""
    for variant in entry.variants
      names = names + " v" + id.to_s + "=" + Text.quote(variant.name) + "/" + variant.size.to_s
      id += 1
    end
    lines = lines.push("enum " + Text.quote(entry.name) + names)
  end
  index = 0
  for function in program.functions
    lines = function_lines(lines, index, function, index == program.entry)
    index += 1
  end
  return lines
end

def struct_line(index: Int, entry: Ir.StructDef) -> String
  fields = entry.fields.map do |field: String| Text.quote(field) end.join(",")
  line = "struct s" + index.to_s + " " + Text.quote(entry.name) + " [" + fields + "]"
  if entry.decodable
    types = entry.types.map do |type: Types.Type| Types.debug_text(type) end.join(", ")
    line = line + " types=[" + types + "]"
  end
  return line
end

def function_lines(out: List[String], index: Int, function: Ir.Function, entry: Bool) -> List[String]
  head = "fn" + index.to_s + " " + Text.quote(function.name) + " params=" + function.params.to_s
  head = head + " captures=" + function.captures.to_s + " slots=" + function.slots.to_s
  if entry
    head = head + " entry"
  end
  lines = out.push(head + " @ " + span_text(function.file, function.span))
  for instr in function.body
    if instr.op == "label"
      lines = lines.push("  L" + instr.args[0].to_s + ":")
    else
      lines = lines.push(instr_line(instr))
    end
  end
  return lines
end

def instr_line(instr: Ir.Instr) -> String
  text = "    " + instr.op
  shown = instr.args.size
  if instr.op == "struct-with"
    shown = 4
  end
  at = 0
  while at < shown
    text = text + " " + arg_text(instr, at)
    at += 1
  end
  if instr.op == "const"
    text = text + " " + imm_text(instr.imm)
  end
  spans = instr.spans.map do |span: Source.Span| span_text(instr.file, span) end
  return text + " @ " + spans.join(" ")
end

# One argument of an instruction, by the op: labels, functions, structs, variants and globals have their own prefix.
def arg_text(instr: Ir.Instr, at: Int) -> String
  op = instr.op
  value = instr.args[at]
  if instr.op == "call-builtin"
    if at == 0
      return "r" + value.to_s + " " + Text.quote(instr.name)
    end
    return value.to_s
  end
  if (op == "jump" and at == 0) or ((op == "jump-if-false" or op == "jump-if-true") and at == 1)
    return "L" + value.to_s
  elsif (op == "call" or op == "tail-call" or op == "closure") and at == 1
    return "fn" + value.to_s
  elsif (op == "global" or op == "global-set") and at == 1
    return "g" + value.to_s
  elsif (op == "enum" or op == "is-variant") and at == 2
    return "v" + value.to_s
  elsif (op == "struct" or op == "struct-with") and at == 2
    return "s" + value.to_s
  elsif op == "struct-with" and at == 3
    return "[" + instr.args.drop(3).map do |position: Int| position.to_s end.join(" ") + "]"
  elsif (op == "field" or op == "payload" or op == "list" or op == "map") and at == 2
    return value.to_s
  elsif op == "call-value" and at == 1
    return value.to_s
  elsif op == "range" and at == 2
    if value == 1
      return "..."
    end
    return ".."
  end
  return "r" + value.to_s
end

def imm_text(imm: Ir.Imm) -> String
  case imm
    Ir.Imm.Void -> return "void"
    Ir.Imm.Nil -> return "nil"
    Ir.Imm.Bool(flag) -> return flag.to_s
    Ir.Imm.Int(number) -> return "int:" + number.to_s
    Ir.Imm.Float(number) -> return "float:bits:" + Float.to_bits(number).to_s
    Ir.Imm.Text(text) -> return Text.quote(text)
  end
end

def span_text(file: Int, span: Source.Span) -> String
  return "#{file}:#{span.start.line}:#{span.start.column}-#{span.stop.line}:#{span.stop.column}"
end

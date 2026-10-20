import Writer from "../../../../compiler/bytecode/bytecode_writer"
import Ir from "../../../../compiler/lower/ir"
import Source from "../../../../compiler/syntax/source"
import Types from "../../../../compiler/check/types"

# Writes lowered programs that no source file lowers to, to reach the limits of the format and the BYTECODE-INTERNAL
# paths of compiler/bytecode/bytecode_writer.agc. tests/frontend-bytecode-test.rkt builds the same programs for the Racket
# writer and compares what each prints, one line for each name in SCENARIOS.
#
# Every program has two files, so that a limit can name the span of a function in the second file (the writer reports
# that file with the problem); the span of the program is in the first.

# The scenarios that take under a second. Run with the argument `slow`, the program runs SLOW_SCENARIOS instead: those
# that write about a million bytes, or build 65,535 structs, and so belong to the slow tier of the test.
SCENARIOS = [
  "globals-ok", "globals-over", "structs-over", "variants-over", "fields-over", "payload-over", "registers-ok",
  "registers-over", "types-deep-ok", "types-deep-over", "steps-merged", "labels", "unknown-op", "missing-label",
  "operand-range", "operand-wide", "operand-count", "operand-short",
]

SLOW_SCENARIOS = ["structs-ok", "types-over", "updates-ok", "updates-over"]

# `--version=V` names the Agentica version of the header; the writer takes it as an input, and the output leaves it
# out (see header_size), so any version gives the same lines.
def main() -> Void
  names = SCENARIOS
  version = ""
  for argument in System.args()
    if argument == "slow"
      names = SLOW_SCENARIOS
    elsif argument.starts_with?("--version=")
      version = argument.slice(10, argument.length - 10)
    end
  end
  for name in names
    puts("#{name} #{describe(scenario(name), version)}")
  end
end

# What writing a program gives, in one line: the size and a checksum of the bytes, or the code and place of the
# problem (and the message of a BYTECODE-LIMIT, which is fixed).
def describe(program: Ir.Program, version: String) -> String
  case Writer.write(program, version)
    Writer.Written.Done(bytes) ->
      body = bytes.drop(header_size(bytes))
      return "ok #{body.size} #{checksum(body)}"
    Writer.Written.Failed(problem) ->
      line = "ERROR #{problem.code} #{place(problem.span)} file=#{problem.file}"
      if problem.code == "BYTECODE-LIMIT"
        return "#{line} #{problem.message}"
      end
      return line
  end
end

def place(span: Source.Span) -> String
  return "#{span.start.line}:#{span.start.column}-#{span.stop.line}:#{span.stop.column}"
end

# The header ends with the Agentica version (magic, format version, then the length of the version and its bytes), so
# the size and the checksum above leave it out: a release does not change them.
def header_size(bytes: List[Int]) -> Int
  return 12 + bytes[8] + bytes[9] * 256 + bytes[10] * 65536 + bytes[11] * 16777216
end

def checksum(bytes: List[Int]) -> Int
  total = 0
  for byte in bytes
    total = (total * 31 + byte) % 1000000007
  end
  return total
end

def span(line: Int) -> Source.Span
  return Source.Span(
    start: Source.Position(offset: 0, line: line, column: 1),
    stop: Source.Position(offset: 0, line: line, column: 5),
  )
end

def instr(op: String, args: List[Int], file: Int, line: Int) -> Ir.Instr
  return Ir.instr(op, args, file, [span(line)])
end

def function(name: String, slots: Int, body: List[Ir.Instr]) -> Ir.Function
  return Ir.Function(name: name, params: 0, captures: 0, slots: slots, body: body, file: 1, span: span(30))
end

def plain(name: String, fields: List[String]) -> Ir.StructDef
  return Ir.StructDef(name: name, fields: fields, decodable: false, types: [])
end

def decodable(name: String, types: List[Types.Type]) -> Ir.StructDef
  return Ir.StructDef(name: name, fields: ["f"], decodable: true, types: types)
end

def program(
  structs: List[Ir.StructDef], enums: List[Ir.EnumDef], functions: List[Ir.Function], globals: Int
) -> Ir.Program
  return Ir.Program(
    sources: [
      Ir.SourceFile(file: "a.agc", name: "a.agc", text: "one\n"),
      Ir.SourceFile(file: "b.agc", name: "b.agc", text: "é\n"),
    ],
    structs: structs,
    enums: enums,
    functions: functions,
    entry: 0,
    globals: globals,
    span: span(1),
  )
end

def with_functions(functions: List[Ir.Function]) -> Ir.Program
  return program([], [], functions, 0)
end

def with_body(slots: Int, body: List[Ir.Instr]) -> Ir.Program
  return with_functions([function("f", slots, body)])
end

def structs_named(count: Int) -> List[Ir.StructDef]
  found: List[Ir.StructDef] = []
  for index in 0...count
    found = found.push(plain("S#{index}", []))
  end
  return found
end

def deep(levels: Int) -> Types.Type
  type = Types.Type.Int
  for level in 0...levels
    type = Types.Type.List(type)
  end
  return type
end

def updates(count: Int) -> List[Ir.Instr]
  body: List[Ir.Instr] = []
  for index in 0...count
    body = body.push(instr("struct-with", [0, 1, index, 0], 1, 31))
  end
  return body.push(instr("return", [0], 1, 32))
end

def scenario(name: String) -> Ir.Program
  if name == "globals-ok"
    return program([], [], [], 65535)
  elsif name == "globals-over"
    return program([], [], [], 65536)
  elsif name == "structs-ok"
    return program(structs_named(65535), [], [], 0)
  elsif name == "structs-over"
    return program(structs_named(65536), [], [], 0)
  elsif name == "variants-over"
    variants: List[Ir.VariantDef] = []
    for index in 0...65536
      variants = variants.push(Ir.VariantDef(name: "V#{index}", size: 0))
    end
    return program([], [Ir.EnumDef(name: "E", variants: variants)], [], 0)
  elsif name == "fields-over"
    fields = List.repeat("x", 65536)
    return program([plain("Big", fields)], [], [], 0)
  elsif name == "payload-over"
    return program([], [Ir.EnumDef(name: "E", variants: [Ir.VariantDef(name: "V", size: 65536)])], [], 0)
  elsif name == "registers-ok"
    return with_body(65535, [instr("return", [0], 1, 31)])
  elsif name == "registers-over"
    return with_body(65536, [instr("return", [0], 1, 31)])
  elsif name == "types-over"
    # The struct types S0 to S65533 and J, and the four scalar types, are 65,539 entries of the type table.
    found = structs_named(65534)
    types: List[Types.Type] = [Types.Type.Int, Types.Type.Float, Types.Type.Bool, Types.Type.String]
    for index in 0...65534
      types = types.push(Types.Type.Struct("S#{index}"))
    end
    return program(found.push(decodable("J", types.push(Types.Type.Struct("J")))), [], [], 0)
  elsif name == "types-deep-ok"
    return program([decodable("J", [deep(1024)])], [], [], 0)
  elsif name == "types-deep-over"
    return program([decodable("J", [deep(1025)])], [], [], 0)
  elsif name == "updates-ok"
    return with_body(2, updates(65535))
  elsif name == "updates-over"
    return with_body(2, updates(65536))
  elsif name == "steps-merged"
    body: List[Ir.Instr] = [Ir.label(7, 1)]
    for index in 0...65537
      body = body.push(instr("step", [], 1, 31 + index % 3))
    end
    body = body.push(Ir.label(8, 1))
    body = body.push(instr("step", [], 1, 40))
    body = body.push(instr("jump", [7], 1, 41))
    body = body.push(instr("jump-if-false", [0, 8], 1, 41))
    return with_body(2, body.push(instr("return", [0], 1, 42)))
  elsif name == "labels"
    body: List[Ir.Instr] = [instr("step", [], 1, 31), instr("jump", [3], 1, 32), Ir.label(2, 1)]
    body = body.concat([Ir.label(3, 1), instr("jump-if-true", [1, 2], 0, 33), instr("return", [1], 1, 34)])
    return with_body(2, body)
  elsif name == "unknown-op"
    return with_body(2, [instr("teleport", [0, 0, 0], 1, 31)])
  elsif name == "missing-label"
    return with_body(2, [instr("jump", [9], 1, 31)])
  elsif name == "operand-range"
    return with_body(2, [instr("move", [0, 70000], 1, 31)])
  elsif name == "operand-wide"
    return with_body(2, [instr("call", [0, 4294967296], 1, 31)])
  elsif name == "operand-short"
    return with_body(2, [instr("move", [0], 1, 31)])
  end
  return with_body(2, [instr("add-i", [0, 1], 1, 31), instr("list", [0, 1, 2, 3, 4], 1, 32)])
end

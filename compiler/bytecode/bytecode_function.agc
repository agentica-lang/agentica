## Encodes one function of the program: the instructions as four u16 words, a
## label as the number of the instruction after it, runs of `step` merged, and the constants, struct updates, builtins
## and spans the instructions name interned in the tables.
##
## A function body is flat, so this is a loop over the instructions and uses no recursion.

import Ir from "../lower/ir"
import Wire from "bytecode_bytes"
import Failure from "bytecode_failure"
import Pool from "bytecode_pool"
import Spans from "bytecode_spans"
import {MAX_U16, NEEDS, OPCODES, PAIR_OPS, SINGLE_OPS, WIDE_OPS} from "bytecode_tables"

## What the writer has interned so far: the entries of the constant, struct update, builtin and span sections.
export struct Tables
  constants: Pool.Pool
  updates: Pool.Pool
  builtins: Pool.Pool
  spans: Pool.Pool
end

## The bytes of a function in the file (its header, its code and the span of each instruction, as three chunks) and
## the tables after it.
export struct Encoded
  tables: Tables
  parts: Wire.Chunks
end

# The operands an instruction is written with, and the tables after naming what it needs. The instruction is written
# as the opcode and three u16 operands, or, when generic, as the operands it has.
struct Operands
  tables: Tables
  a: Int
  b: Int
  c: Int
  generic: Bool
end

## Encodes a function. It fails with BYTECODE-LIMIT when the function has more than 65,535 registers or the program
## more than 65,535 distinct struct updates.
export def encode(program: Ir.Program, tables: Tables, function: Ir.Function) -> Result[Encoded]
  if function.slots > MAX_U16
    return error(Failure.limit(program, function.file, "registers in one function", function.span))
  end

  body = function.body
  labels = label_pcs(body)
  # The constant, update and builtin pools travel in state. The span pool is a local of its own: operands never read
  # state.spans, so it is stored back once, after the loop.
  state = tables
  span_pool = tables.spans
  code: List[Int] = []
  refs: List[Int] = []
  count = 0
  at = 0
  while at < body.size
    instr = body[at]
    op = instr.op
    if op == "label"
      at += 1
      next
    end

    run = 1
    if op == "step"
      run = step_run_end(body, at) - at
    end

    found = try operands(program, function, labels, state, instr, run)
    state = found.tables
    words = try instr_words(program, instr, found)
    code = code.concat(words)
    interned = Spans.intern_run(span_pool, body, at, run)
    span_pool = interned.pool
    refs = refs.concat(Wire.u32(interned.id))
    count += 1
    at += run
  end

  # The span of the function comes after those of its instructions.
  own = Spans.intern_one(span_pool, function.file, function.span)
  head = Wire.string(function.name).concat(Wire.u32(function.params)).concat(Wire.u32(function.captures))
  head = head.concat(Wire.u32(function.slots)).concat(Wire.u32(own.id))
  head = head.concat(Wire.u32(prelude_flag(program, function))).concat(Wire.u32(count))
  parts = Wire.add(Wire.add(Wire.add(Wire.start(), head), code), refs)
  return ok(Encoded(tables: state.with(spans: own.pool), parts: parts))
end

# 1 for a function lowered from a file of the prelude, else 0: the VM reports an error in it at the user's call.
def prelude_flag(program: Ir.Program, function: Ir.Function) -> Int
  if Ir.prelude_file?(program, function.file)
    return 1
  end

  return 0
end

# The operands of one instruction, which is a written run of `run` instructions when it is a `step`. The tables gain
# the entry the instruction names, if it has one. The first case that matches wins, so const and the jumps come
# before WIDE_OPS, as in the chain this replaced.
def operands(
  program: Ir.Program, function: Ir.Function, labels: Map[Int, Int], tables: Tables, instr: Ir.Instr, run: Int
) -> Result[Operands]
  op = instr.op
  args = instr.args
  if !OPCODES.has_key?(op)
    return error(Failure.internal(program, "unknown opcode #{op}"))
  end

  if NEEDS.has_key?(op) and args.size < NEEDS[op]
    return error(Failure.internal(program, "#{op} needs at least #{NEEDS[op]} operands and has #{args.size}"))
  end

  if op == "const"
    return const_operands(program, tables, instr)
  elsif op == "struct-with"
    return update_operands(program, tables, args)
  elsif op == "call-builtin"
    return builtin_operands(program, tables, instr)
  elsif op == "jump" or op == "jump-if-false" or op == "jump-if-true"
    return jump_operands(program, function, labels, tables, instr)
  elsif WIDE_OPS.include?(op)
    return wide_operands(program, tables, op, args[0], args[1])
  elsif op == "step"
    return ok(plain(tables, run, 0, 0))
  elsif PAIR_OPS.include?(op)
    return ok(plain(tables, args[0], args[1], 0))
  elsif SINGLE_OPS.include?(op)
    return ok(plain(tables, args[0], 0, 0))
  elsif args.size == 3
    return ok(plain(tables, args[0], args[1], args[2]))
  end

  # Any other number of operands is written as given: the loader rejects it.
  return ok(Operands(tables: tables, a: 0, b: 0, c: 0, generic: true))
end

def plain(tables: Tables, a: Int, b: Int, c: Int) -> Operands
  return Operands(tables: tables, a: a, b: b, c: c, generic: false)
end

# A wide operand is a 32-bit index that the VM reads from the last two, low half first.
def wide_operands(program: Ir.Program, tables: Tables, op: String, a: Int, index: Int) -> Result[Operands]
  if index < 0
    return error(Failure.internal(program, "a negative index in #{op}"))
  end

  return ok(plain(tables, a, index % 65_536, index / 65_536))
end

# const: the register, and the index of its constant, which is added to the table when it is new.
def const_operands(program: Ir.Program, tables: Tables, instr: Ir.Instr) -> Result[Operands]
  key = constant_key(instr.imm)
  found = Pool.find(tables.constants, key)
  if found.ok?
    return wide_operands(program, tables, instr.op, instr.args[0], found.unwrap!)
  end

  added = Pool.add(tables.constants, key, constant_bytes(instr.imm), 1)
  return wide_operands(program, tables.with(constants: added), instr.op, instr.args[0], tables.constants.count)
end

# struct-with: the two registers, and the number of its update (the struct and the positions it sets), which is added
# to the table when it is new. The VM reads that number as a u16, so the table holds at most 65,535 updates.
def update_operands(program: Ir.Program, tables: Tables, args: List[Int]) -> Result[Operands]
  positions = args.drop(3)
  fields = positions.map do |position: Int| position.to_s end.join(",")
  key = "#{args[2]}:#{fields}"
  found = Pool.find(tables.updates, key)
  if found.ok?
    return ok(plain(tables, args[0], args[1], found.unwrap!))
  end

  updates = tables.updates
  if updates.count >= MAX_U16
    return error(Failure.limit(program, 0, "struct updates", program.span))
  end

  entry = Wire.u32(args[2]).concat(Wire.u32(positions.size))
  for position in positions
    entry = entry.concat(Wire.u32(position))
  end

  return ok(plain(tables.with(updates: Pool.add(updates, key, entry, 1)), args[0], args[1], updates.count))
end

# call-builtin: the register, and the index of its builtin (the name and the argument count), which is added to the
# table when it is new.
def builtin_operands(program: Ir.Program, tables: Tables, instr: Ir.Instr) -> Result[Operands]
  args = instr.args
  key = "#{args[1]}:#{instr.name}"
  found = Pool.find(tables.builtins, key)
  if found.ok?
    return wide_operands(program, tables, instr.op, args[0], found.unwrap!)
  end

  bytes = Wire.string(instr.name).concat(Wire.u32(args[1]))
  added = Pool.add(tables.builtins, key, bytes, 1)
  return wide_operands(program, tables.with(builtins: added), instr.op, args[0], tables.builtins.count)
end

# jump, jump-if-false and jump-if-true: the register of the test, if there is one, and the number of the instruction
# the label stands before.
def jump_operands(
  program: Ir.Program, function: Ir.Function, labels: Map[Int, Int], tables: Tables, instr: Ir.Instr
) -> Result[Operands]
  args = instr.args
  register = 0
  label = args[0]
  if instr.op != "jump"
    register = args[0]
    label = args[1]
  end

  if !labels.has_key?(label)
    return error(Failure.internal(program, "the function #{function.name} jumps to a missing label"))
  end

  return wide_operands(program, tables, instr.op, register, labels[label])
end

# The instruction as bytes: the opcode, a zero, and the operands as u16.
def instr_words(program: Ir.Program, instr: Ir.Instr, found: Operands) -> Result[List[Int]]
  op = instr.op
  if found.generic
    # The operands as given, without padding.
    words = [OPCODES[op], 0]
    for arg in instr.args
      if arg < 0 or arg > MAX_U16
        return error(Failure.internal(program, "an operand of #{op} does not fit in 16 bits"))
      end

      words = words.concat(Wire.u16(arg))
    end

    return ok(words)
  end

  a = found.a
  b = found.b
  c = found.c
  if a < 0 or a > MAX_U16 or b < 0 or b > MAX_U16 or c < 0 or c > MAX_U16
    return error(Failure.internal(program, "an operand of #{op} does not fit in 16 bits"))
  end

  return ok([OPCODES[op], 0, a % 256, a / 256, b % 256, b / 256, c % 256, c / 256])
end

# The place after the run of `step` instructions that starts at `at`. A run is cut at 65,535, the most one instruction
# counts.
def step_run_end(body: List[Ir.Instr], at: Int) -> Int
  stop = at
  while stop < body.size and stop - at < MAX_U16 and body[stop].op == "step"
    stop += 1
  end

  return stop
end

# The number of the instruction each label stands before, counting a run of steps as one instruction.
def label_pcs(body: List[Ir.Instr]) -> Map[Int, Int]
  labels: Map[Int, Int] = {}
  pc = 0
  at = 0
  while at < body.size
    op = body[at].op
    if op == "label"
      labels = labels.put(body[at].args[0], pc)
      at += 1
    else
      pc += 1
      if op == "step"
        at = step_run_end(body, at)
      else
        at += 1
      end
    end
  end

  return labels
end

# The text that stands for a constant in the table: two constants are one entry when this is the same. The tag keeps
# an Int, a Float (by its bits, so 0.0 and -0.0 differ), a Bool and a String apart.
def constant_key(imm: Ir.Imm) -> String
  case imm
    Ir.Imm.Void -> return "v"
    Ir.Imm.Nil -> return "n"
    Ir.Imm.Bool(flag) -> return "b#{flag}"
    Ir.Imm.Int(number) -> return "i#{number}"
    Ir.Imm.Float(number) -> return "f#{Float.to_bits(number)}"
    Ir.Imm.Text(text) -> return "s#{text}"
  end
end

# A constant in the file: a tag (0 void, 1 nil, 2 false, 3 true, 4 Int, 5 Float, 6 String) and its value.
def constant_bytes(imm: Ir.Imm) -> List[Int]
  case imm
    Ir.Imm.Void -> return [0]
    Ir.Imm.Nil -> return [1]
    Ir.Imm.Bool(flag) -> return flag_bytes(flag)
    Ir.Imm.Int(number) -> return [4].concat(Wire.i64(number))
    Ir.Imm.Float(number) -> return [5].concat(Wire.f64(number))
    Ir.Imm.Text(text) -> return [6].concat(Wire.string(text))
  end
end

def flag_bytes(flag: Bool) -> List[Int]
  if flag
    return [3]
  end

  return [2]
end

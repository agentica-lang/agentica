## Encodes one function of the program (src/bytecode.rkt, `encode-function`): the instructions as four u16 words, a
## label as the number of the instruction after it, runs of `step` merged, and the constants, struct updates, builtins
## and spans the instructions name interned in the tables.
##
## A function body is flat, so this is a loop over the instructions and uses no recursion.

import Bytes from "bytecode_bytes"
import Failure from "bytecode_failure"
import Pool from "bytecode_pool"
import Spans from "bytecode_spans"
import {MAX_U16, NEEDS, OPCODES, PAIR_OPS, SINGLE_OPS, WIDE_OPS} from "bytecode_tables"
import Ir from "ir"

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
  parts: List[List[Int]]
end

## Encodes a function. It fails with BYTECODE-LIMIT when the function has more than 65,535 registers or the program
## more than 65,535 distinct struct updates.
export def encode(program: Ir.Program, tables: Tables, function: Ir.Function) -> Result[Encoded]
  if function.slots > MAX_U16
    return error(Failure.limit(program, function.file, "registers in one function", function.span))
  end
  body = function.body
  labels = label_pcs(body)
  constants = tables.constants
  updates = tables.updates
  builtins = tables.builtins
  spans = tables.spans
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
    if !OPCODES.has_key?(op)
      return error(Failure.internal(program, "unknown opcode #{op}"))
    end
    args = instr.args
    run = 1
    if op == "step"
      run = step_run_end(body, at) - at
    end
    # The three operands. A wide operand is a 32-bit index that the VM reads from the last two, low half first.
    a = 0
    b = 0
    c = 0
    index = 0
    wide = false
    generic = false
    if NEEDS.has_key?(op) and args.size < NEEDS[op]
      return error(Failure.internal(program, "#{op} has #{args.size} operands, not #{NEEDS[op]}"))
    end
    if op == "const"
      a = args[0]
      wide = true
      key = constant_key(instr.imm)
      if constants.index.has_key?(key)
        index = constants.index[key]
      else
        index = constants.count
        constants = Pool.add(constants, key, constant_bytes(instr.imm), 1)
      end
    elsif op == "struct-with"
      a = args[0]
      b = args[1]
      positions = args.drop(3)
      fields = positions.map do |position: Int| position.to_s end.join(",")
      key = "#{args[2]}:#{fields}"
      if updates.index.has_key?(key)
        c = updates.index[key]
      else
        if updates.count >= MAX_U16
          return error(Failure.limit(program, 0, "struct updates", program.span))
        end
        c = updates.count
        entry = Bytes.u32(args[2]).concat(Bytes.u32(positions.size))
        for position in positions
          entry = entry.concat(Bytes.u32(position))
        end
        updates = Pool.add(updates, key, entry, 1)
      end
    elsif op == "call-builtin"
      a = args[0]
      wide = true
      key = "#{args[1]}:#{instr.name}"
      if builtins.index.has_key?(key)
        index = builtins.index[key]
      else
        index = builtins.count
        builtins = Pool.add(builtins, key, Bytes.string(instr.name).concat(Bytes.u32(args[1])), 1)
      end
    elsif op == "jump" or op == "jump-if-false" or op == "jump-if-true"
      wide = true
      label = args[0]
      if op != "jump"
        a = args[0]
        label = args[1]
      end
      if !labels.has_key?(label)
        return error(Failure.internal(program, "the function #{function.name} jumps to a missing label"))
      end
      index = labels[label]
    elsif WIDE_OPS.include?(op)
      a = args[0]
      index = args[1]
      wide = true
    elsif op == "step"
      a = run
    elsif PAIR_OPS.include?(op)
      a = args[0]
      b = args[1]
    elsif SINGLE_OPS.include?(op)
      a = args[0]
    elsif args.size == 3
      a = args[0]
      b = args[1]
      c = args[2]
    else
      generic = true
    end
    if wide
      if index < 0
        return error(Failure.internal(program, "a negative index in #{op}"))
      end
      b = index % 65536
      c = index / 65536
    end
    if generic
      # Any other number of operands is written as given, as src/bytecode.rkt does; the loader rejects it.
      words = [OPCODES[op], 0]
      for arg in args
        if arg < 0 or arg > MAX_U16
          return error(Failure.internal(program, "an operand of #{op} does not fit in 16 bits"))
        end
        words = words.concat(Bytes.u16(arg))
      end
      code = code.concat(words)
    else
      if a < 0 or a > MAX_U16 or b < 0 or b > MAX_U16 or c < 0 or c > MAX_U16
        return error(Failure.internal(program, "an operand of #{op} does not fit in 16 bits"))
      end
      code = code.concat([OPCODES[op], 0, a % 256, a / 256, b % 256, b / 256, c % 256, c / 256])
    end
    interned = Spans.intern(spans, run_instrs(body, at, run))
    spans = interned.pool
    refs = refs.concat(Bytes.u32(interned.id))
    count += 1
    at += run
  end
  # The span of the function comes after those of its instructions.
  own = Spans.intern_one(spans, function.file, function.span)
  head = Bytes.string(function.name).concat(Bytes.u32(function.params)).concat(Bytes.u32(function.captures))
  head = head.concat(Bytes.u32(function.slots)).concat(Bytes.u32(own.id)).concat(Bytes.u32(count))
  return ok(Encoded(
    tables: Tables(constants: constants, updates: updates, builtins: builtins, spans: own.pool),
    parts: [head, code, refs],
  ))
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

# The instructions a written instruction stands for: itself, or a run of steps.
def run_instrs(body: List[Ir.Instr], at: Int, run: Int) -> List[Ir.Instr]
  if run == 1
    return [body[at]]
  end
  found: List[Ir.Instr] = []
  for offset in 0...run
    found = found.push(body[at + offset])
  end
  return found
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
    Ir.Imm.Int(number) -> return [4].concat(Bytes.i64(number))
    Ir.Imm.Float(number) -> return [5].concat(Bytes.f64(number))
    Ir.Imm.Text(text) -> return [6].concat(Bytes.string(text))
  end
end

def flag_bytes(flag: Bool) -> List[Int]
  if flag
    return [3]
  end
  return [2]
end

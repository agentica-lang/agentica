## Module constants in the lowering. The
## functions reachable from `main` decide which constants are built, a constant read by a function that is emitted gets
## a slot, and a constant that is one scalar literal gets neither: its reads are the literal.

import Ast from "../syntax/ast"
import Ir from "ir"
import Scans from "lower_scan"
import {INT_MIN, INT_MIN_DIGITS} from "lower_tables"

## What the lowering does with the constants. kept are the constants to build, in initialization order. slots maps the
## linked name of every non-literal constant that an emitted function reads to its slot of the Globals table, numbered
## in initialization order, so its size is the Globals count. literals maps the constants whose initializer is one
## scalar literal to its value.
export struct Plan
  kept: List[Ast.ConstDecl]
  slots: Map[String, Int]
  literals: Map[String, Ir.Imm]
end

## Decides which constants are built and which get a slot. The functions reachable from `main` (by calls, `&f` and the
## blocks inside, to a fixed point) decide the kept constants, then the constants those read. A slot is given to every
## non-literal constant that any emitted function reads, reachable or not, so the code of an unreachable function still
## loads. functions and constants are the declarations in program order, with the scan of each body; order is the
## initialization order of the constants (their linked names).
export def plan(
  functions: List[Ast.FunctionDecl],
  function_scans: List[Scans.Scan],
  constants: List[Ast.ConstDecl],
  constant_scans: List[Scans.Scan],
  order: List[String],
) -> Plan
  by_name: Map[String, Int] = {}
  literals: Map[String, Ir.Imm] = {}
  at = 0
  while at < constants.size
    by_name = by_name.put(constants[at].name, at)
    value = literal_value(constants[at].value)
    case value
      some(imm) -> literals = literals.put(constants[at].name, imm)
      none -> literals = literals
    end

    at += 1
  end

  by_function: Map[String, Int] = {}
  at = 0
  while at < functions.size
    by_function = by_function.put(functions[at].name, at)
    at += 1
  end

  kept_set = kept_names(function_scans, by_function, constant_scans, by_name, literals)
  slot_set = kept_set
  for scan in function_scans
    for name in scan.consts
      if !literals.has_key?(name)
        slot_set = slot_set.add(name)
      end
    end
  end

  kept: List[Ast.ConstDecl] = []
  slots: Map[String, Int] = {}
  for name in order
    if kept_set.include?(name)
      kept = kept.push(constants[by_name[name]])
    end

    if slot_set.include?(name)
      slots = slots.put(name, slots.size)
    end
  end

  return Plan(kept: kept, slots: slots, literals: literals)
end

## The value of a scalar literal initializer: one literal, or `-` and a number literal. `none` for any other
## initializer.
export def literal_value(value: Ast.Expr) -> Optional[Ir.Imm]
  case value
    Ast.Expr.Literal(node) -> return plain(node.value)
    Ast.Expr.Unary(node) ->
      if node.op != "minus"
        return none
      end

      case node.operand
        Ast.Expr.Literal(inner) -> return negated(inner.value)
        _ -> return none
      end

    _ -> return none
  end
end

# The names of the constants to build: those the reachable functions read and, to a fixed point, those the kept
# constants read and those the functions their initializers call read.
def kept_names(
  function_scans: List[Scans.Scan],
  by_function: Map[String, Int],
  constant_scans: List[Scans.Scan],
  by_name: Map[String, Int],
  literals: Map[String, Ir.Imm],
) -> Set[String]
  reached: Set[String] = Set.new([])
  pending: List[String] = ["main"]
  wanted: List[String] = []
  kept: Set[String] = Set.new([])
  at = 0
  wanted_at = 0
  while at < pending.size or wanted_at < wanted.size
    if at < pending.size
      name = pending[at]
      at += 1
      if by_function.has_key?(name) and !reached.include?(name)
        reached = reached.add(name)
        scan = function_scans[by_function[name]]
        wanted = wanted.concat(scan.consts)
        pending = pending.concat(scan.calls)
      end
    else
      name = wanted[wanted_at]
      wanted_at += 1
      if !literals.has_key?(name) and !kept.include?(name)
        kept = kept.add(name)
        scan = constant_scans[by_name[name]]
        wanted = wanted.concat(scan.consts)
        # Only a regex literal makes a constant call a function of the program: std/regex's compile.
        pending = pending.concat(scan.calls)
      end
    end
  end

  return kept
end

def plain(value: Ast.LitValue) -> Optional[Ir.Imm]
  case value
    Ast.LitValue.Whole(number) -> return some(Ir.Imm.Int(number))
    Ast.LitValue.Real(number) -> return some(Ir.Imm.Float(number))
    Ast.LitValue.Text(text) -> return some(Ir.Imm.Text(text))
    Ast.LitValue.Flag(flag) -> return some(Ir.Imm.Bool(flag))
    Ast.LitValue.Nothing -> return some(Ir.Imm.Nil)
    Ast.LitValue.Huge(digits) -> return none
  end
end

def negated(value: Ast.LitValue) -> Optional[Ir.Imm]
  case value
    Ast.LitValue.Whole(number) -> return some(Ir.Imm.Int(0 - number))
    Ast.LitValue.Real(number) -> return some(Ir.Imm.Float(-number))
    Ast.LitValue.Huge(digits) ->
      if digits == INT_MIN_DIGITS
        return some(Ir.Imm.Int(INT_MIN))
      end

      return none
    _ -> return none
  end
end

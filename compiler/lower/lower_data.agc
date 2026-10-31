## Lists, maps, enum values, structs and struct updates Each is a `step`, the items computed into consecutive
## registers, and one instruction that gathers them.

import Model from "../catalog/builtin_model"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Types from "../syntax/types"
import Ir from "ir"
import State from "lower_state"
import Builtins from "../catalog/builtins"
import {MAX_CHUNK} from "lower_tables"

## A list literal. One `list` instruction gathers at most MAX_CHUNK items; a longer literal is built in chunks joined
## with List.concat.
export def lower_list(cx: State.Cx, fx: State.Fx, node: Ast.ListLit, want: Int) -> Result[State.Out]
  span = node.span
  fx = State.step(fx, span)
  saved = fx.next
  count = node.elements.size
  dst = want
  if count <= MAX_CHUNK
    made = State.target(fx, want)
    fx = made.fx
    dst = made.slot
    start = fx.next
    fx = try items(cx, fx, node.elements, 0, count)
    first = start
    if count == 0
      first = dst
    end

    fx = State.emit_at(fx, "list", [dst, first, count], span)
  else
    fx = State.alloc(fx)
    base = fx.next - 1
    at = 0
    while at < count
      size = count - at
      if size > MAX_CHUNK
        size = MAX_CHUNK
      end

      fx = fx.with(next: base + 1)
      start = fx.next
      fx = try items(cx, fx, node.elements, at, at + size)
      if at == 0
        fx = State.emit_at(fx, "list", [base, start, size], span)
      else
        fx = State.emit_at(fx, "list", [start, start, size], span)
        fx = State.emit_builtin(fx, base, "List.concat", 2, [span, span, span])
      end

      at += size
    end

    dst = base
    if want >= 0
      fx = State.emit_at(fx, "move", [want, base], span)
      dst = want
    end
  end

  return ok(State.Out(fx: State.release(fx, saved, want, dst), slot: dst))
end

## Type.members: the list of StructMember for the fields the checker recorded, each name and type a constant text.
## Like a list literal, one `list` instruction gathers at most MAX_CHUNK items and a struct with more fields is built
## in chunks joined with List.concat.
export def lower_members(
  cx: State.Cx, fx: State.Fx, fields: List[Model.Named], span: Source.Span, want: Int
) -> Result[State.Out]
  index = cx.structs["StructMember"].index
  fx = State.step(fx, span)
  saved = fx.next
  fx = State.alloc(fx)
  base = fx.next - 1
  count = fields.size
  if count == 0
    fx = State.emit_at(fx, "list", [base, base, 0], span)
  end

  at = 0
  while at < count
    size = count - at
    if size > MAX_CHUNK
      size = MAX_CHUNK
    end

    fx = fx.with(next: base + 1)
    start = fx.next
    fx = member_items(fx, fields, at, at + size, index, span)
    if at == 0
      fx = State.emit_at(fx, "list", [base, start, size], span)
    else
      fx = State.emit_at(fx, "list", [start, start, size], span)
      fx = State.emit_builtin(fx, base, "List.concat", 2, [span, span, span])
    end

    at += size
  end

  dst = base
  if want >= 0
    fx = State.emit_at(fx, "move", [want, base], span)
    dst = want
  end

  return ok(State.Out(fx: State.release(fx, saved, want, dst), slot: dst))
end

## A map literal: key and value registers one after the other. One `map` instruction gathers at most MAX_CHUNK entries;
## the rest are added with Map.put.
export def lower_map(cx: State.Cx, fx: State.Fx, node: Ast.MapLit, want: Int) -> Result[State.Out]
  span = node.span
  fx = State.step(fx, span)
  saved = fx.next
  count = node.entries.size
  dst = want
  if count <= MAX_CHUNK
    made = State.target(fx, want)
    fx = made.fx
    dst = made.slot
    start = fx.next
    fx = try entries(cx, fx, node.entries, 0, count)
    first = start
    if count == 0
      first = dst
    end

    fx = State.emit_at(fx, "map", [dst, first, count], span)
  else
    fx = State.alloc(fx)
    base = fx.next - 1
    start = fx.next
    fx = try entries(cx, fx, node.entries, 0, MAX_CHUNK)
    fx = State.emit_at(fx, "map", [base, start, MAX_CHUNK], span)
    at = MAX_CHUNK
    while at < count
      fx = fx.with(next: base + 1)
      fx = try entries(cx, fx, node.entries, at, at + 1)
      fx = State.emit_builtin(fx, base, "Map.put", 3, [span, span, span, span])
      at += 1
    end

    dst = base
    if want >= 0
      fx = State.emit_at(fx, "move", [want, base], span)
      dst = want
    end
  end

  return ok(State.Out(fx: State.release(fx, saved, want, dst), slot: dst))
end

## An enum value: the payload items in consecutive registers and an `enum` instruction with the id of the variant.
## known skips the type check of the items, which the type of the enum value covered (an Optional's item).
export def lower_enum(
  cx: State.Cx, fx: State.Fx, enum_name: String, variant_name: String, args: List[Ast.Expr], span: Source.Span,
  want: Int, known: Bool
) -> Result[State.Out]
  fx = State.step(fx, span)
  saved = fx.next
  made = State.target(fx, want)
  fx = made.fx
  dst = made.slot
  id = cx.variants["#{enum_name}.#{variant_name}"]
  start = fx.next
  for arg in args
    fx = State.alloc(fx)
    out = try cx.expression.call(cx, fx, arg, fx.next - 1, false, known)
    fx = out.fx
  end

  first = start
  if args.size == 0
    first = dst
  end

  fx = State.emit_at(fx, "enum", [dst, first, id], span)
  return ok(State.Out(fx: State.release(fx, saved, want, dst), slot: dst))
end

## A struct construction: a register for each field, each value computed into the register of its field, in source
## order, then the default of each field the construction leaves out, and a `struct` instruction. The checker accepted
## only a construction that gives every field without a default.
export def lower_struct(cx: State.Cx, fx: State.Fx, node: Ast.Construct, want: Int) -> Result[State.Out]
  span = node.span
  info = cx.structs[node.type_name]
  fx = State.step(fx, span)
  saved = fx.next
  made = State.target(fx, want)
  fx = made.fx
  dst = made.slot
  start = fx.next
  for field in info.fields
    fx = State.alloc(fx)
  end

  after = fx.next
  for arg in node.args
    out = try cx.expression.call(cx, fx, arg.value, start + info.positions[arg.name], false, false)
    fx = out.fx.with(next: after)
  end

  if Builtins.RECORDS.has_key?(node.type_name)
    fx = try lower_record_defaults(cx, fx, node, info, start, after)
  end

  if cx.field_fills.has_key?(node.type_name)
    fills = cx.field_fills[node.type_name]
    given = Set.new(node.args.map do |arg: Ast.NamedArg| arg.name end)
    for field in info.fields
      if !given.include?(field) and fills.values.has_key?(field)
        fx = try lower_field_default(cx, fx, fills, fills.values[field], start + info.positions[field])
        fx = fx.with(next: after)
      end
    end
  end

  first = start
  if info.fields.size == 0
    first = dst
  end

  fx = State.emit_at(fx, "struct", [dst, first, info.index], span)
  return ok(State.Out(fx: State.release(fx, saved, want, dst), slot: dst))
end

## The value of a catalog default (Model.Default) in register want: a literal, an empty list, map or Bytes, or a
## variant without a payload. id and span are the ones of the node that the default stands in for.
export def lower_catalog_default(
  cx: State.Cx, fx: State.Fx, value: Model.Default, id: Int, span: Source.Span, want: Int
) -> Result[State.Out]
  literal = Ast.LitValue.Nothing
  case value
    Model.Default.Whole(number) -> literal = Ast.LitValue.Whole(number)
    Model.Default.Real(number) -> literal = Ast.LitValue.Real(number)
    Model.Default.Text(text) -> literal = Ast.LitValue.Text(text)
    Model.Default.Flag(flag) -> literal = Ast.LitValue.Flag(flag)
    Model.Default.Nothing -> literal = Ast.LitValue.Nothing
    Model.Default.EmptyList -> return lower_list(cx, fx, Ast.ListLit(id: id, elements: [], span: span), want)
    Model.Default.EmptyMap -> return lower_map(cx, fx, Ast.MapLit(id: id, entries: [], span: span), want)
    Model.Default.EmptyBytes ->
      # `"".bytes`: the empty Bytes constant.
      made = State.target(State.step(fx, span), want)
      return ok(State.Out(fx: State.emit_const(made.fx, made.slot, Ir.Imm.Bytes(""), span), slot: made.slot))
    Model.Default.Variant(name) ->
      parts = name.split(".")
      return lower_enum(cx, fx, parts[0], parts[1], [], span, want, false)
    Model.Default.Absent -> return error(State.internal(cx, "lower: a missing argument has no default", span))
  end

  return lower_known_literal(cx, fx, literal, id, span, want)
end

## A struct update, `target.with(f: v)`: the receiver goes to the first register of a window and the new values after
## it, in the order of the struct's fields (the order of the update table of the bytecode), so one `struct-with` copies
## the receiver and overwrites those fields. The receiver runs first, then the values in source order; the register a
## value lands in does not depend on where it is written.
export def lower_update(cx: State.Cx, fx: State.Fx, node: Ast.StructUpdate, want: Int) -> Result[State.Out]
  span = node.span
  info = cx.structs[Types.name(State.type_of(cx, Ast.Expr.Update(node)))]
  fx = State.step(fx, span)
  saved = fx.next
  made = State.target(fx, want)
  fx = made.fx
  dst = made.slot
  fx = State.alloc(fx)
  window = fx.next - 1
  out = try cx.expression.call(cx, fx, node.target, window, false, false)
  fx = out.fx
  positions = node.args.map do |arg: Ast.NamedArg| info.positions[arg.name] end.sort
  for position in positions
    fx = State.alloc(fx)
  end

  after = fx.next
  for arg in node.args
    rank = rank_of(positions, info.positions[arg.name])
    done = try cx.expression.call(cx, fx, arg.value, window + 1 + rank, false, false)
    fx = done.fx.with(next: after)
  end

  fx = State.emit_at(fx, "struct-with", [dst, window, info.index].concat(positions), span)
  return ok(State.Out(fx: State.release(fx, saved, want, dst), slot: dst))
end

# The StructMember of fields[from, to) in consecutive registers: a register for each, then two scratch registers
# above them for the name and the type, which the `struct` instruction reads as consecutive fields.
def member_items(
  fx: State.Fx, fields: List[Model.Named], from: Int, to: Int, index: Int, span: Source.Span
) -> State.Fx
  start = fx.next
  at = from
  while at < to
    fx = State.alloc(fx)
    at += 1
  end

  scratch = fx.next
  fx = State.alloc(State.alloc(fx))
  at = from
  while at < to
    fx = State.emit_const(fx, scratch, Ir.Imm.Text(fields[at].name), span)
    fx = State.emit_const(fx, scratch + 1, Ir.Imm.Text(Types.to_text(fields[at].type)), span)
    fx = State.emit_at(fx, "struct", [start + at - from, scratch, index], span)
    at += 1
  end

  return fx.with(next: start + to - from)
end

# A literal that the catalog gives: its type is the one of the parameter or field it fills, so it has no check.
def lower_known_literal(
  cx: State.Cx, fx: State.Fx, value: Ast.LitValue, id: Int, span: Source.Span, want: Int
) -> Result[State.Out]
  literal = Ast.Expr.Literal(Ast.Literal(id: id, value: value, span: span))
  return cx.expression.call(cx, fx, literal, want, false, true)
end

# The fields of a builtin record that a construction leaves out, from the defaults of the catalog (the checker let
# only those be left out), each in the register of its field.
def lower_record_defaults(
  cx: State.Cx, fx: State.Fx, node: Ast.Construct, info: State.StructInfo, start: Int, after: Int
) -> Result[State.Fx]
  given = Set.new(node.args.map do |arg: Ast.NamedArg| arg.name end)
  for field in Builtins.RECORDS[node.type_name]
    if !given.include?(field.name) and Builtins.default_present?(field.default)
      out = try lower_catalog_default(cx, fx, field.default, node.id, node.span, start + info.positions[field.name])
      fx = out.fx.with(next: after)
    end
  end

  return ok(fx)
end

# A default is an expression of the file that declares the struct, so it is lowered with that file's index (the spans
# of its instructions point into that file), as the default of a parameter is, and the file of the construction comes
# back after it.
def lower_field_default(
  cx: State.Cx, fx: State.Fx, fills: State.FieldFill, value: Ast.Expr, slot: Int
) -> Result[State.Fx]
  here = cx.with(file: fills.file, index: fills.index)
  out = try cx.expression.call(here, fx.with(file: fills.index), value, slot, false, false)
  return ok(out.fx.with(file: fx.file))
end

# Lowers items[from] up to items[stop] into consecutive new registers. A literal item needs no type check of its own:
# the list's type was checked.
def items(cx: State.Cx, fx: State.Fx, elements: List[Ast.Expr], from: Int, stop: Int) -> Result[State.Fx]
  at = from
  while at < stop
    fx = State.alloc(fx)
    out = try cx.expression.call(cx, fx, elements[at], fx.next - 1, false, true)
    fx = out.fx
    at += 1
  end

  return ok(fx)
end

# The same for map entries: the key, then the value.
def entries(cx: State.Cx, fx: State.Fx, pairs: List[Ast.MapEntry], from: Int, stop: Int) -> Result[State.Fx]
  at = from
  while at < stop
    fx = State.alloc(fx)
    key = try cx.expression.call(cx, fx, pairs[at].key, fx.next - 1, false, true)
    fx = State.alloc(key.fx)
    value = try cx.expression.call(cx, fx, pairs[at].value, fx.next - 1, false, true)
    fx = value.fx
    at += 1
  end

  return ok(fx)
end

# The index of a value in the sorted positions.
def rank_of(positions: List[Int], position: Int) -> Int
  at = 0
  while positions[at] != position
    at += 1
  end

  return at
end

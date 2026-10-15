## Lists, maps, enum values, structs and struct updates (src/lower.rkt: lower-list, lower-map, lower-enum,
## lower-struct, lower-update). Each is a `step`, the items computed into consecutive registers, and one instruction
## that gathers them.

import Ast from "ast"
import Ir from "ir"
import State from "lower_state"
import {MAX_CHUNK} from "lower_tables"
import Source from "source"
import Types from "types"

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
export def lower_enum(
  cx: State.Cx, fx: State.Fx, enum_name: String, variant_name: String, args: List[Ast.Expr], span: Source.Span,
  want: Int
) -> Result[State.Out]
  fx = State.step(fx, span)
  saved = fx.next
  made = State.target(fx, want)
  fx = made.fx
  dst = made.slot
  id = cx.variants[enum_name + "." + variant_name]
  start = fx.next
  for arg in args
    fx = State.alloc(fx)
    out = try cx.expression.call(cx, fx, arg, fx.next - 1, false, false)
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
## order, and a `struct` instruction.
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
  first = start
  if info.fields.size == 0
    first = dst
  end
  fx = State.emit_at(fx, "struct", [dst, first, info.index], span)
  return ok(State.Out(fx: State.release(fx, saved, want, dst), slot: dst))
end

# `target.with(f: v)`: the receiver goes to the first register of a window and the new values after it, in the order of
# the struct's fields (the order of the update table of the bytecode), so one `struct-with` copies the receiver and
# overwrites those fields. The receiver runs first, then the values in source order; the register a value lands in does
# not depend on where it is written.
## A struct update.
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

## What the child of `agentica repl` holds, and the program of the next entry over it. The child loads each program of
## the session over the one it runs (vm/session.c), and only when every table starts with the entries it has (a
## session load, docs/vm/08-loader-and-cli.md §8). Each entry is compiled from the whole session, so `merge` takes
## the fresh program and gives it the numbers of the image: a function, struct, enum or slot that the child has keeps
## its number, and a new or changed one is added at the end, with every reference to it renumbered.
##
## A fresh function is the function of the image with its name when both have the same code after renumbering. Calls
## make that circular, so the match starts from the names and drops what differs until nothing changes: a changed
## function and every function that calls it are added again, and the ones that did not change keep their numbers.

import Function from "../bytecode/bytecode_function"
import Ir from "../lower/ir"
import Paths from "../modules/import_path"
import Source from "../syntax/source"
import T from "../syntax/types"

## The tables the child holds and the writer's tables after them. functions and slots are the current function of
## each name and the slot of each constant (by linked name); set_by is the slot that each constant function set.
struct Image
  program: Ir.Program
  tables: Function.Tables
  functions: Map[String, Int]
  slots: Map[String, Int]
  set_by: Map[Int, Int]
end

## A fresh program over an image: the program to write (the image's tables and what is new after them), the number of
## the entry function, and the image when the child loaded it and the entry ran (`ran`) or did not (`loaded`, where
## the declarations of the entry are not kept, so nothing but the tables grows).
struct Merged
  program: Ir.Program
  entry: Int
  ran: Image
  loaded: Image
end

## The image of the first program of a session, which the child runs from the start.
def first(program: Ir.Program, tables: Function.Tables) -> Image
  functions: Map[String, Int] = {}
  at = 0
  for function in program.functions
    functions = functions.put(function.name, at)
    at += 1
  end

  Image(program: program, tables: tables, functions: functions, slots: {}, set_by: {})
end

## The image with the tables that the writer gave after writing `program`.
def written(image: Image, program: Ir.Program, tables: Function.Tables) -> Image
  image.with(program: program, tables: tables)
end

## The place of `position` in the session: `lines` maps each line of the fresh file to the session's line, negative for
## a line the session wrote, whose columns are not the user's: a place on it is the start of that line. A line it does
## not map stands at `line`.
def moved(position: Source.Position, lines: Map[Int, Int], line: Int) -> Source.Position
  found = lines.get(position.line, -line)
  return position.with(line: -found, column: 1) if found < 0

  position.with(line: found)
end

## The program `given` over the image. `entry` is the name of its entry function. The spans of the file `root` move to
## the lines `lines` maps them to (a line it does not map goes to `line`), and its text becomes `text`.
def merge(
  image: Image,
  given: Ir.Program,
  entry: String,
  root: String,
  text: String,
  lines: Map[Int, Int],
  line: Int,
) -> Merged
  fresh = renamed_blocks(given, "@#{Paths.last_part(root)}:", lines)
  held = image.program
  files = file_numbers(held.sources, fresh.sources)
  sources = merged_sources(held.sources, fresh.sources, root, text)
  structs = struct_numbers(held.structs, fresh.structs)
  enums = enum_numbers(held.enums, fresh.enums)
  variants = variant_numbers(held.enums, fresh.enums, enums.numbers)
  starts = start_pairs(fresh)
  base = Numbers(functions: {}, files: files, structs: structs.numbers, variants: variants, slots: {})
  matched = matching(image, fresh, base)
  slots = slot_numbers(image, fresh, matched, starts)
  functions = matched
  added: List[Ir.Function] = []
  at = 0
  for function in fresh.functions
    if function.name != START and !matched.has_key?(at)
      functions = functions.put(at, held.functions.size + added.size)
      added = added.push(function)
    end

    at += 1
  end

  numbers = base.with(functions: functions, slots: slots.slots)
  repl = files.get(fresh_root(fresh, root), 0)
  moved = Moves(file: repl, lines: lines, line: line)
  renumbered = added.map { |function: Ir.Function| renumber(function, numbers, moved) }
  table = held.functions.concat(renumbered)
  entry_number = -1
  at = 0
  for function in fresh.functions
    if function.name == entry
      entry_number = functions.get(at, -1)
    end

    at += 1
  end

  program_entry = held.entry
  if slots.count > held.globals
    init = init_function(starts, numbers, slots.added, repl, moved_span(fresh.span, moved))
    program_entry = table.size
    table = table.push(init)
  end

  program = held.with(
    sources: sources,
    structs: held.structs.concat(structs.added),
    enums: held.enums.concat(enums.added),
    instances: merged_instances(held.instances, fresh.instances),
    written: merged_written(held.written, fresh.written),
    functions: table,
    entry: program_entry,
    globals: slots.count,
    global_names: held.global_names.concat(slots.names),
  )

  loaded = image.with(program: program)
  current = image.functions
  at = 0
  for function in fresh.functions
    if function.name != START
      current = current.put(function.name, functions[at])
    end

    at += 1
  end

  named = image.slots
  at = 0
  for name in fresh.global_names
    named = named.put(name, slots.slots[at])
    at += 1
  end

  set_by = image.set_by
  for pair in starts
    if slots.added.include?(pair.slot)
      set_by = set_by.put(functions[pair.function], slots.slots[pair.slot])
    end
  end

  ran = loaded.with(functions: current, slots: named, set_by: set_by)
  Merged(program: program, entry: entry_number, ran: ran, loaded: loaded)
end

private

# The name of the function that the lowering adds to set the constants and call main (lowering.agc, start_function).
START = "<start>"

# What a fresh number is in the image: of a function, a source file, a struct, a variant and a slot. A number that is
# not mapped has none yet.
struct Numbers
  functions: Map[Int, Int]
  files: Map[Int, Int]
  structs: Map[Int, Int]
  variants: Map[Int, Int]
  slots: Map[Int, Int]
end

# A fresh table's numbers in the image and the entries the image does not have, in fresh order.
struct Structs
  numbers: Map[Int, Int]
  added: List[Ir.StructDef]
end

struct Enums
  numbers: Map[Int, Int]
  added: List[Ir.EnumDef]
end

# The slots: the image's slot of each fresh slot, how many slots there are with the new ones, the fresh slots that
# are new, and the names of the new ones.
struct Slots
  slots: Map[Int, Int]
  count: Int
  added: Set[Int]
  names: List[String]
end

# A constant that `<start>` sets: the fresh number of its function and its fresh slot.
struct StartPair
  function: Int
  slot: Int
end

# Where the spans of the root file go: its number in the image and the line of each fresh line.
struct Moves
  file: Int
  lines: Map[Int, Int]
  line: Int
end

def fresh_root(fresh: Ir.Program, root: String) -> Int
  at = 0
  for source in fresh.sources
    return at if source.file == root

    at += 1
  end

  0
end

def file_numbers(held: List[Ir.SourceFile], fresh: List[Ir.SourceFile]) -> Map[Int, Int]
  numbers: Map[Int, Int] = {}
  known: Map[String, Int] = {}
  at = 0
  for source in held
    known = known.put(source.file, at)
    at += 1
  end

  count = held.size
  at = 0
  for source in fresh
    found = known.get(source.file)
    if found.some?
      numbers = numbers.put(at, found.unwrap!)
    else
      numbers = numbers.put(at, count)
      known = known.put(source.file, count)
      count += 1
    end

    at += 1
  end

  numbers
end

# The image's sources with the new files after them; the root file holds the session's text, which only a message
# reads (the loader counts the sources and never compares them).
def merged_sources(
  held: List[Ir.SourceFile],
  fresh: List[Ir.SourceFile],
  root: String,
  text: String,
) -> List[Ir.SourceFile]
  known = Set.new(held.map { |source: Ir.SourceFile| source.file })
  sources = held.concat(fresh.filter { |source: Ir.SourceFile| !known.include?(source.file) })
  sources.map do |source: Ir.SourceFile| with_text(source, root, text) end
end

def with_text(source: Ir.SourceFile, root: String, text: String) -> Ir.SourceFile
  return source.with(text: text) if source.file == root

  source
end

def struct_numbers(held: List[Ir.StructDef], fresh: List[Ir.StructDef]) -> Structs
  keys = held.map { |item: Ir.StructDef| struct_key(item) }
  numbers: Map[Int, Int] = {}
  added: List[Ir.StructDef] = []
  at = 0
  for entry in fresh
    found = latest(keys, struct_key(entry))
    if found >= 0
      numbers = numbers.put(at, found)
    else
      numbers = numbers.put(at, held.size + added.size)
      added = added.push(entry)
    end

    at += 1
  end

  Structs(numbers: numbers, added: added)
end

def enum_numbers(held: List[Ir.EnumDef], fresh: List[Ir.EnumDef]) -> Enums
  keys = held.map { |item: Ir.EnumDef| enum_key(item) }
  numbers: Map[Int, Int] = {}
  added: List[Ir.EnumDef] = []
  at = 0
  for entry in fresh
    found = latest(keys, enum_key(entry))
    if found >= 0
      numbers = numbers.put(at, found)
    else
      numbers = numbers.put(at, held.size + added.size)
      added = added.push(entry)
    end

    at += 1
  end

  Enums(numbers: numbers, added: added)
end

# The variants of all enums are numbered one after the other in table order (ir.agc, EnumDef): the image's number of
# each fresh variant is the first variant of its enum in the image's table, with the new enums after it, and its place.
def variant_numbers(held: List[Ir.EnumDef], fresh: List[Ir.EnumDef], enums: Map[Int, Int]) -> Map[Int, Int]
  firsts: List[Int] = []
  count = 0
  for entry in held
    firsts = firsts.push(count)
    count += entry.variants.size
  end

  added = 0
  at = 0
  for entry in fresh
    if enums[at] >= held.size
      firsts = firsts.push(count + added)
      added += entry.variants.size
    end

    at += 1
  end

  numbers: Map[Int, Int] = {}
  variant = 0
  at = 0
  for entry in fresh
    for place in 0...entry.variants.size
      numbers = numbers.put(variant, firsts[enums[at]] + place)
      variant += 1
    end

    at += 1
  end

  numbers
end

# A block of the session's file is named after its place (`block@(repl):LINE:COL`, lower_stmt.agc), which moves in
# the file as declarations come and go: it takes the line of the session instead, so an unchanged block keeps its name.
def renamed_blocks(program: Ir.Program, marker: String, lines: Map[Int, Int]) -> Ir.Program
  program.with(functions: program.functions.map { |function: Ir.Function| renamed(function, marker, lines) })
end

def renamed(function: Ir.Function, marker: String, lines: Map[Int, Int]) -> Ir.Function
  parts = function.name.split(marker)
  return function if parts.size != 2

  place = parts[1].split(":")
  return function if place.size != 2 or !place[0].to_i.ok?

  function.with(name: "#{parts[0]}#{marker}#{lines.get(place[0].to_i.unwrap!, 0)}:#{place[1]}")
end

# The last place of `name` in `names`, or -1.
def latest(names: List[String], name: String) -> Int
  at = names.size - 1
  while at >= 0
    return at if names[at] == name

    at -= 1
  end

  -1
end

def struct_key(entry: Ir.StructDef) -> String
  types = entry.types.map { |type: T.Type| T.to_text(type) }
  defaults = entry.defaults.map { |default: Ir.FieldDefault| default_key(default) }
  "#{entry.name}|#{entry.fields.join(",")}|#{entry.decodable}|#{types.join(",")}|#{defaults.join(",")}"
end

def default_key(default: Ir.FieldDefault) -> String
  case default
    Ir.FieldDefault.Required -> "r"
    Ir.FieldDefault.Value(imm) -> "c#{Function.constant_key(imm)}"
    Ir.FieldDefault.EmptyList -> "l"
    Ir.FieldDefault.EmptyMap -> "m"
    Ir.FieldDefault.Variant(id) -> "v#{id}"
  end
end

def enum_key(entry: Ir.EnumDef) -> String
  variants = entry.variants.map { |variant: Ir.VariantDef| "#{variant.name}/#{variant.size}" }
  types = entry.types.map { |type: T.Type| T.to_text(type) }
  "#{entry.name}|#{variants.join(",")}|#{entry.decodable}|#{types.join(",")}"
end

def merged_instances(held: List[Ir.InstanceDef], fresh: List[Ir.InstanceDef]) -> List[Ir.InstanceDef]
  known = Set.new(held.map { |instance: Ir.InstanceDef| instance.name })
  held.concat(fresh.filter { |instance: Ir.InstanceDef| !known.include?(instance.name) })
end

def merged_written(held: Map[String, String], fresh: Map[String, String]) -> Map[String, String]
  written = held
  for prefix in fresh.keys
    if !written.has_key?(prefix)
      written = written.put(prefix, fresh[prefix])
    end
  end

  written
end

# The constants that `<start>` sets, in order: each `call` of a constant function and the `global-set` after it.
def start_pairs(fresh: Ir.Program) -> List[StartPair]
  pairs: List[StartPair] = []
  for function in fresh.functions
    if function.name == START
      called = -1
      for instr in function.body
        if instr.op == "call"
          called = instr.args[1]
        elsif instr.op == "global-set"
          pairs = pairs.push(StartPair(function: called, slot: instr.args[1]))
        end
      end
    end
  end

  pairs
end

# The fresh functions that keep the number of the image's function with their name: those whose code is the same
# with every reference renumbered, to a fixed point.
def matching(image: Image, fresh: Ir.Program, base: Numbers) -> Map[Int, Int]
  held = image.program.functions
  matched: Map[Int, Int] = {}
  at = 0
  for function in fresh.functions
    found = image.functions.get(function.name)
    if function.name != START and found.some?
      matched = matched.put(at, found.unwrap!)
    end

    at += 1
  end

  starts = start_pairs(fresh)
  changed = true
  while changed
    changed = false
    numbers = base.with(functions: matched, slots: slot_numbers(image, fresh, matched, starts).slots)
    kept: Map[Int, Int] = {}
    for index in matched.keys
      if same_function?(fresh.functions[index], held[matched[index]], numbers)
        kept = kept.put(index, matched[index])
      else
        changed = true
      end
    end

    matched = kept
  end

  matched
end

# The image's slot of each fresh slot. A constant that `<start>` sets keeps the slot its function set before, when
# that function is matched; a constant that it does not set (no function of the entry reads it) has the slot of its
# name. Any other slot is new, numbered after the image's in fresh order.
def slot_numbers(image: Image, fresh: Ir.Program, matched: Map[Int, Int], starts: List[StartPair]) -> Slots
  set_at: Map[Int, Int] = {}
  for pair in starts
    set_at = set_at.put(pair.slot, pair.function)
  end

  slots: Map[Int, Int] = {}
  added: Set[Int] = Set.new([])
  names: List[String] = []
  count = image.program.globals
  for slot in 0...fresh.globals
    found: Optional[Int] = none
    setter = set_at.get(slot)
    if setter.some?
      function = matched.get(setter.unwrap!)
      if function.some?
        found = image.set_by.get(function.unwrap!)
      end
    else
      found = image.slots.get(fresh.global_names[slot])
    end

    if found.some?
      slots = slots.put(slot, found.unwrap!)
    else
      slots = slots.put(slot, count)
      added = added.add(slot)
      names = names.push(fresh.global_names[slot])
      count += 1
    end
  end

  Slots(slots: slots, count: count, added: added, names: names)
end

def same_function?(fresh: Ir.Function, held: Ir.Function, numbers: Numbers) -> Bool
  if (
    fresh.name != held.name or
    fresh.params != held.params or
    fresh.captures != held.captures or
    fresh.slots != held.slots or
    fresh.body.size != held.body.size or
    numbers.files.get(fresh.file, -1) != held.file
  )
    return false
  end

  for at in 0...fresh.body.size
    return false if !same_instr?(fresh.body[at], held.body[at], numbers)
  end

  true
end

def same_instr?(fresh: Ir.Instr, held: Ir.Instr, numbers: Numbers) -> Bool
  if (
    fresh.op != held.op or
    fresh.name != held.name or
    fresh.args.size != held.args.size or
    Function.constant_key(fresh.imm) != Function.constant_key(held.imm) or
    numbers.files.get(fresh.file, -1) != held.file
  )
    return false
  end

  args = renumbered_args(fresh, numbers)
  for at in 0...args.size
    return false if args[at] != held.args[at]
  end

  true
end

# The arguments with the number in the image of each function, struct, variant and slot they name; -1 for one that
# has none yet.
def renumbered_args(instr: Ir.Instr, numbers: Numbers) -> List[Int]
  args = instr.args
  op = instr.op
  if op == "call" or op == "tail-call" or op == "closure"
    return args.set(1, numbers.functions.get(args[1], -1))
  elsif op == "global" or op == "global-set"
    return args.set(1, numbers.slots.get(args[1], -1))
  elsif op == "struct" or op == "struct-with"
    return args.set(2, numbers.structs.get(args[2], -1))
  elsif op == "enum" or op == "is-variant"
    return args.set(2, numbers.variants.get(args[2], -1))
  elsif op == "jump-variant"
    return args.set(1, numbers.variants.get(args[1], -1))
  end

  args
end

def renumber(function: Ir.Function, numbers: Numbers, moved: Moves) -> Ir.Function
  file = numbers.files.get(function.file, 0)
  body = function.body.map do |instr: Ir.Instr|
    at = numbers.files.get(instr.file, 0)
    spans = instr.spans
    if at == moved.file
      spans = spans.map { |span: Source.Span| moved_span(span, moved) }
    end

    instr.with(args: renumbered_args(instr, numbers), file: at, spans: spans)
  end

  span = function.span
  if file == moved.file
    span = moved_span(span, moved)
  end

  function.with(file: file, body: body, span: span)
end

def moved_span(span: Source.Span, moved: Moves) -> Source.Span
  Source.Span(start: moved_position(span.start, moved), stop: moved_position(span.stop, moved))
end

def moved_position(position: Source.Position, moved: Moves) -> Source.Position
  moved(position, moved.lines, moved.line)
end

# The function that sets the new slots, the entry of the program: each new constant that `<start>` sets, in its order,
# by a call of its function.
def init_function(
  starts: List[StartPair],
  numbers: Numbers,
  added: Set[Int],
  file: Int,
  span: Source.Span,
) -> Ir.Function
  body: List[Ir.Instr] = [Ir.instr("step", [], file, [span])]
  for pair in starts
    if added.include?(pair.slot)
      body = body.push(Ir.instr("call", [0, numbers.functions[pair.function]], file, [span]))
      body = body.push(Ir.instr("global-set", [0, numbers.slots[pair.slot]], file, [span]))
    end
  end

  body = body.push(Ir.Instr(op: "const", args: [0], imm: Ir.Imm.Void, name: "", file: file, spans: [span]))
  body = body.push(Ir.instr("return", [0], file, [span]))
  Ir.Function(name: START, params: 0, captures: 0, slots: 1, body: body, file: file, span: span)
end

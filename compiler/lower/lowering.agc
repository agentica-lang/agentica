## The lowering: takes a linked and checked program and gives the VM IR (ir.agc), or the first
## LOWER- problem. The function table is, in this order: the declared functions in program order, the kept constants in
## initialization order, `<start>` when the program has constant slots, then the blocks in the order they were found
## (docs/future/44-module-constants.md 44.7).
##
## Recursion: lowering an expression or a statement takes at most 3 VM frames for each level of the tree (most shapes
## take 1 or 2, because many calls are tail calls), and the checker allows 1,000 levels (CHECK-TOO-DEEP), so it uses
## about 3,000 of the 10,000 frames of the VM. The scans that read the whole tree use a worklist and do not recurse.

import Ast from "../syntax/ast"
import Failure from "../diagnostics/problem"
import Checker from "../check/checker"
import Defaults from "../check/defaults"
import Ir from "ir"
import {PRELUDE_PREFIX} from "../syntax/prelude_name"
import Const from "lower_const"
import Expr from "lower_expr"
import Program from "lower_program"
import Scans from "lower_scan"
import Lowering from "lower_state"
import Stmt from "lower_stmt"
import {BUILTIN_STRUCTS} from "lower_tables"
import Linker from "../modules/linker"
import Source from "../syntax/source"
import Types from "../syntax/types"
import {ENUMS} from "../catalog/builtins"

## The result of lowering: the program, or the first problem (the file it is in comes with it).
export enum Lowered
  Done(Ir.Program)
  Failed(Failure.Problem)
end

# A function or constant of the program with the file it is declared in.
struct Located
  file: String
  function: Ast.FunctionDecl
end

struct LocatedConst
  file: String
  constant: Ast.ConstDecl
end

# The functions lowered so far, with the block functions their bodies made and the next free index of the table.
struct Table
  functions: List[Ir.Function]
  blocks: Map[Int, Ir.Function]
  block_count: Int
end

# What the scans of all the bodies give: one per function and constant, and the watched type names written anywhere,
# with whether a function uses a type name as a value.
struct Scanned
  function_scans: List[Scans.Scan]
  constant_scans: List[Scans.Scan]
  written: List[String]
  type_value: Bool
end

## Lowers a linked program that the checker accepted.
export def lower(linked: Linker.Linked, checked: Checker.Checked) -> Lowered
  result = run(linked, checked)
  if result.ok?
    return Lowered.Done(result.unwrap!)
  end
  return Lowered.Failed(Failure.unpack(result.message))
end

def run(linked: Linker.Linked, checked: Checker.Checked) -> Result[Ir.Program]
  functions: List[Located] = []
  constants: List[LocatedConst] = []
  decls: List[Ast.Decl] = []
  modules = linked.modules.concat(checked.prelude)
  for module in modules
    for decl in module.declarations
      decls = decls.push(decl)
      case decl
        Ast.Decl.Function(node) -> functions = functions.push(Located(file: module.file, function: node))
        Ast.Decl.Constant(node) -> constants = constants.push(LocatedConst(file: module.file, constant: node))
        _ -> functions = functions
      end
    end
  end
  function_decls = functions.map do |entry: Located| entry.function end
  constant_decls = constants.map do |entry: LocatedConst| entry.constant end
  watched = Set.new(BUILTIN_STRUCTS.concat(ENUMS.keys))
  scanned = scan_all(decls, function_decls, constant_decls, watched)
  used = Set.new(scanned.written.concat(mentioned_in(checked.types, watched)))
  tables = Program.build(decls, used, scanned.type_value)
  plan = Const.plan(function_decls, scanned.function_scans, constant_decls, scanned.constant_scans, checked.constants)
  start = plan.slots.size > 0
  files_of = constant_files(constants)
  files = source_order(linked, functions, plan.kept, files_of)
  index_of: Map[String, Int] = {}
  for file in files
    index_of = index_of.put(file, index_of.size)
  end
  by_name: Map[String, Int] = {}
  at = 0
  for entry in functions
    by_name = by_name.put(entry.function.name, at)
    at += 1
  end
  main_index = by_name["main"]
  cx = Lowering.Cx(
    types: checked.types,
    resolved: checked.resolved,
    user_types: tables.user_types,
    structs: tables.infos,
    variants: tables.variants,
    json_structs: tables.json_structs,
    functions: by_name,
    bodies: checked.bodies,
    step_tries: checked.step_tries,
    fills: fills_of(functions, index_of),
    reads: reads_of(plan),
    file: linked.modules[0].file,
    index: 0,
    expression: &Expr.lower_expression,
    block: &Stmt.lower_block_function
  )
  table_size = functions.size + plan.kept.size
  if start
    table_size += 1
  end
  table = Table(functions: [], blocks: {}, block_count: table_size)
  for entry in functions
    params = entry.function.params.map do |param: Ast.Param| param.name end
    function = entry.function
    table = try add_function(
      cx, table, entry.file, index_of[entry.file], function.name, params, function.body, function.span,
    )
  end
  for entry in plan.kept
    file = files_of[entry.name]
    body = [Ast.Stmt.Return(Ast.Return(id: entry.id, value: Ast.Optional.Present(entry.value), span: entry.span))]
    table = try add_function(cx, table, file, index_of[file], entry.name, [], body, entry.span)
  end
  built = table.functions
  blocks = table.blocks
  block_count = table.block_count
  if start
    built = built.push(start_function(linked.root.span, plan, files_of, index_of, functions.size, main_index))
  end
  index = table_size
  while index < block_count
    built = built.push(blocks[index])
    index += 1
  end
  entry = main_index
  if start
    entry = functions.size + plan.kept.size
  end
  sources = modules.map do |module: Linker.LinkedModule| source_of(module) end
  kept_sources = used_sources(sources, files)
  return ok(Ir.Program(
    sources: kept_sources,
    structs: tables.structs,
    enums: tables.enums,
    functions: pin_prelude_spans(built, kept_sources),
    entry: entry,
    globals: plan.slots.size,
    span: linked.root.span
  ))
end

# A file of the prelude is only a name in the program: no text, so no program can show its lines.
def source_of(module: Linker.LinkedModule) -> Ir.SourceFile
  if module.file.starts_with?(PRELUDE_PREFIX)
    return Ir.SourceFile(file: module.file, name: module.name, text: "")
  end
  return Ir.SourceFile(file: module.file, name: module.name, text: module.text)
end

# Every span in a function of the prelude becomes the first character of its file: the file has no text, and the VM
# reports a runtime error of a prelude function at the call of the program (docs/vm/03-ir-and-bytecode.md). The
# number of spans of each instruction stays, because the loader checks it.
def pin_prelude_spans(functions: List[Ir.Function], sources: List[Ir.SourceFile]) -> List[Ir.Function]
  start = Source.Position(offset: 0, line: 1, column: 1)
  pinned = Source.Span(start: start, stop: start)
  found: List[Ir.Function] = []
  for function in functions
    if sources[function.file].file.starts_with?(PRELUDE_PREFIX)
      body = function.body.map do |instr: Ir.Instr| pin_instr(instr, pinned) end
      found = found.push(function.with(body: body, span: pinned))
    else
      found = found.push(function)
    end
  end
  return found
end

def pin_instr(instr: Ir.Instr, pinned: Source.Span) -> Ir.Instr
  return instr.with(spans: instr.spans.map do |span: Source.Span| pinned end)
end

# The functions that have default values, by name, with the file each is declared in.
def fills_of(functions: List[Located], index_of: Map[String, Int]) -> Map[String, Lowering.Fill]
  fills: Map[String, Lowering.Fill] = {}
  for entry in functions
    shape = Defaults.shape(entry.function.params)
    if Defaults.has_defaults?(shape)
      fill = Lowering.Fill(shape: shape, params: entry.function.params, file: entry.file, index: index_of[entry.file])
      fills = fills.put(entry.function.name, fill)
    end
  end
  return fills
end

# Lowers one function into a new table whose index is the next to fill, and adds the blocks it made.
def add_function(
  cx: Lowering.Cx, table: Table, file: String, index: Int, name: String, params: List[String], body: List[Ast.Stmt],
  span: Source.Span
) -> Result[Table]
  here = cx.with(file: file, index: index)
  inner = Lowering.fresh(index, table.blocks, table.block_count)
  done = try Stmt.lower_function(here, inner, name, params, [], body, span, false)
  return ok(Table(
    functions: table.functions.push(done.function),
    blocks: done.fx.blocks,
    block_count: done.fx.block_count
  ))
end

def scan_all(
  decls: List[Ast.Decl], functions: List[Ast.FunctionDecl], constants: List[Ast.ConstDecl], watched: Set[String]
) -> Scanned
  function_scans: List[Scans.Scan] = []
  constant_scans: List[Scans.Scan] = []
  written: List[String] = []
  type_value = false
  for decl in functions
    scan = Scans.scan_body(decl.body, watched)
    function_scans = function_scans.push(scan)
    written = written.concat(scan.written).concat(Scans.written_signature(decl, watched))
    if scan.type_value
      type_value = true
    end
  end
  for decl in constants
    scan = Scans.scan_value(decl.value, watched)
    constant_scans = constant_scans.push(scan)
    written = written.concat(scan.written)
    case decl.type
      Ast.Optional.Present(ref) -> written = written.concat(Scans.written_in(ref, watched))
      Ast.Optional.Absent -> written = written
    end
  end
  for decl in decls
    written = written.concat(declared_names(decl, watched))
  end
  return Scanned(
    function_scans: function_scans,
    constant_scans: constant_scans,
    written: written,
    type_value: type_value,
  )
end

# The watched type names the field types of a struct and the payload types of an enum write.
def declared_names(decl: Ast.Decl, watched: Set[String]) -> List[String]
  found: List[String] = []
  case decl
    Ast.Decl.Struct(node) ->
      for field in node.fields
        found = found.concat(Scans.written_in(field.type, watched))
      end
    Ast.Decl.Enum(node) ->
      for variant in node.variants
        for ref in variant.payload_types
          found = found.concat(Scans.written_in(ref, watched))
        end
      end
    _ -> found = found
  end
  return found
end

# The watched struct and enum names that the type of some expression mentions.
def mentioned_in(types: List[Types.Type], watched: Set[String]) -> List[String]
  found: List[String] = []
  for type in types
    found = found.concat(names_in(type, watched))
  end
  return found
end

def names_in(type: Types.Type, watched: Set[String]) -> List[String]
  case type
    Types.Type.Struct(name) -> return only(name, watched)
    Types.Type.Enum(name, args) -> return only(name, watched).concat(names_in_all(args, watched))
    Types.Type.List(item) -> return names_in(item, watched)
    Types.Type.Set(item) -> return names_in(item, watched)
    Types.Type.Result(item) -> return names_in(item, watched)
    Types.Type.Task(item) -> return names_in(item, watched)
    Types.Type.Channel(item) -> return names_in(item, watched)
    Types.Type.Lazy(item) -> return names_in(item, watched)
    Types.Type.Map(key, value) -> return names_in(key, watched).concat(names_in(value, watched))
    Types.Type.Fn(params, result) -> return names_in_all(params, watched).concat(names_in(result, watched))
    _ -> return []
  end
end

def names_in_all(types: List[Types.Type], watched: Set[String]) -> List[String]
  found: List[String] = []
  for type in types
    found = found.concat(names_in(type, watched))
  end
  return found
end

def only(name: String, watched: Set[String]) -> List[String]
  if watched.include?(name)
    return [name]
  end
  return []
end

# What a read of each constant becomes: the literal of a scalar constant, else its slot.
def reads_of(plan: Const.Plan) -> Map[String, Lowering.Read]
  reads: Map[String, Lowering.Read] = {}
  for name in plan.literals.keys
    reads = reads.put(name, Lowering.Read.Literal(plan.literals[name]))
  end
  for name in plan.slots.keys
    reads = reads.put(name, Lowering.Read.Slot(plan.slots[name]))
  end
  return reads
end

# The files in the order the lowering first emits an instruction of each: the root, then the file of each function,
# then of each kept constant.
def source_order(
  linked: Linker.Linked, functions: List[Located], kept: List[Ast.ConstDecl], files_of: Map[String, String]
) -> List[String]
  seen: Set[String] = Set.new([linked.modules[0].file])
  files: List[String] = [linked.modules[0].file]
  for entry in functions
    if !seen.include?(entry.file)
      seen = seen.add(entry.file)
      files = files.push(entry.file)
    end
  end
  for decl in kept
    file = files_of[decl.name]
    if !seen.include?(file)
      seen = seen.add(file)
      files = files.push(file)
    end
  end
  return files
end

# The file each constant is declared in, by name.
def constant_files(constants: List[LocatedConst]) -> Map[String, String]
  files: Map[String, String] = {}
  for entry in constants
    files = files.put(entry.constant.name, entry.file)
  end
  return files
end

# The source files in the order of files.
def used_sources(sources: List[Ir.SourceFile], files: List[String]) -> List[Ir.SourceFile]
  by_file: Map[String, Ir.SourceFile] = {}
  for source in sources
    by_file = by_file.put(source.file, source)
  end
  return files.map do |file: String| by_file[file] end
end

# `<start>`: a step, then for each kept constant a call of its function and a store of the result in its slot, then a
# tail call of main. The loader wants a function to start with a step and to end with a return, so a `const` and a
# `return` follow the tail call.
def start_function(
  span: Source.Span, plan: Const.Plan, files_of: Map[String, String], index_of: Map[String, Int], declared: Int,
  main_index: Int
) -> Ir.Function
  body: List[Ir.Instr] = [Ir.instr("step", [], 0, [span])]
  offset = 0
  for decl in plan.kept
    file = index_of[files_of[decl.name]]
    body = body.push(Ir.instr("call", [0, declared + offset], file, [decl.span]))
    body = body.push(Ir.instr("global-set", [0, plan.slots[decl.name]], file, [decl.span]))
    offset += 1
  end
  body = body.push(Ir.instr("tail-call", [0, main_index], 0, [span]))
  body = body.push(Ir.Instr(op: "const", args: [0], imm: Ir.Imm.Void, name: "", file: 0, spans: [span]))
  body = body.push(Ir.instr("return", [0], 0, [span]))
  return Ir.Function(name: "<start>", params: 0, captures: 0, slots: 1, body: body, file: 0, span: span)
end

## `native_modules` (#1156): the `extern module "NAME"` blocks of a file, described for a code generator outside the
## core (the C header of a module, its codecs). The signature texts and the shapes of the user types are the ones that
## the lowering writes for the VM to compare (check/native_shape.agc), so a generator cannot differ from the compiler
## by one byte. Names, docs and places come from the file as parsed (the linker drops the `export` and the doc that
## sits on it), and the types from the checked program, which a function is matched to by its node id.

import NativeShape from "../check/native_shape"
import Checker from "../check/checker"
import Diag from "../diagnostics/diagnostic"
import DiagnosticModel from "../diagnostics/diagnostic_model"
import DocModel from "../docs/doc_model"
import Linker from "../modules/linker"
import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Types from "../syntax/types"
import Model from "model"

# The version of the shape.
NATIVE_MODULES_VERSION = 1

# What the walk reads besides the declarations of the file: the types of the checker, the structs and enums of every
# module by linked name, and the functions of the file as linked, by node id (their types are the ones recorded).
struct Program
  types: List[Types.Type]
  structs: Map[String, Ast.StructDecl]
  enums: Map[String, Ast.EnumDecl]
  functions: Map[Int, Ast.FunctionDecl]
end

# The blocks found so far: their libraries in order of first appearance, and for each one its members, its types and
# the span that holds them.
struct Found
  order: List[String]
  functions: Map[String, List[Model.NativeFunction]]
  resources: Map[String, List[Model.NativeResource]]
  types: Map[String, List[Model.NativeType]]
  spans: Map[String, Source.Span]
end

# What the declaration of a member says besides itself: the doc and span of the export or of the declaration alone.
struct Placed
  exported: Bool
  doc: Optional[String]
  span: Source.Span
end

## The blocks of the root file of `linked` (checked as `checked`), or CHECK-INTERNAL when the checker recorded no type
## for a type of a function. `file` is the name the answer gives the file.
export def of_program(
  file: String,
  linked: Linker.Linked,
  checked: Checker.Checked,
) -> Diag.Outcome[Model.NativeModules]
  root = linked.modules[0]
  built = blocks_of(root, program_of(linked, checked))
  if !built.ok?
    return Diag.Outcome.Failed(Diag.fail("CHECK-INTERNAL", built.message, root.parsed.span, Diag.Help.NoHelp))
  end

  Diag.Outcome.Done(Model.NativeModules(version: NATIVE_MODULES_VERSION, file: file, blocks: built.unwrap!))
end

def program_of(linked: Linker.Linked, checked: Checker.Checked) -> Program
  structs: Map[String, Ast.StructDecl] = {}
  enums: Map[String, Ast.EnumDecl] = {}
  for module in linked.modules
    for decl in module.declarations
      case decl
        Ast.Decl.Struct(node) -> structs = structs.put(node.name, node)
        Ast.Decl.Enum(node) -> enums = enums.put(node.name, node)
        _ -> next
      end
    end
  end

  functions: Map[Int, Ast.FunctionDecl] = {}
  for decl in linked.modules[0].declarations
    case decl
      Ast.Decl.Function(node) -> functions = functions.put(node.id, node)
      _ -> next
    end
  end

  Program(types: checked.types, structs: structs, enums: enums, functions: functions)
end

def blocks_of(root: Linker.LinkedModule, program: Program) -> Result[List[Model.NativeBlock]]
  found = Found(order: [], functions: {}, resources: {}, types: {}, spans: {})
  for decl in root.parsed.declarations
    case decl
      Ast.Decl.Export(node) ->
        found = try member(found, program, node.declaration, Placed(exported: true, doc: node.doc, span: node.span))
      Ast.Decl.Function(node) ->
        found = try member(found, program, decl, Placed(exported: false, doc: node.doc, span: node.span))
      Ast.Decl.Resource(node) ->
        found = try member(found, program, decl, Placed(exported: false, doc: node.doc, span: node.span))
      _ -> next
    end
  end

  ok(found.order.map do |library: String| block_of(found, library) end)
end

# The blocks with the member `decl` added when it is a function or resource of an extern module block.
def member(found: Found, program: Program, decl: Ast.Decl, placed: Placed) -> Result[Found]
  case decl
    Ast.Decl.Function(node) ->
      case node.native
        some(native) if native.module -> function_in(found, program, node, native.library, placed)
        _ -> ok(found)
      end

    Ast.Decl.Resource(node) ->
      return ok(found) if node.module == ""

      known = found.resources.get(node.module, [])
      made = Model.NativeResource(
        name: node.name,
        name_range: DiagnosticModel.range_of(node.name_span),
        exported: placed.exported,
        doc: doc_text(placed.doc),
        range: DiagnosticModel.range_of(placed.span),
      )

      ok(opened(found, node.module, placed.span).with(resources: found.resources.put(node.module, known.push(made))))
    _ -> ok(found)
  end
end

# The block of `library` with the function `node` (as written) added, and the structs and enums it reaches. The types
# of the function come from its linked twin, which has the same node ids.
def function_in(
  found: Found,
  program: Program,
  node: Ast.FunctionDecl,
  library: String,
  placed: Placed,
) -> Result[Found]
  return error("the linked program has no function for #{node.name}") if !program.functions.has_key?(node.id)

  linked = program.functions[node.id]
  made = NativeShape.of_function(program.types, linked, program.structs, program.enums)
  return error(made.message) if !made.ok?

  signature = made.unwrap!
  parameters: List[Model.NativeParameter] = []
  at = 0
  for param in node.params
    parameters = parameters.push(Model.NativeParameter(name: param.name, type: signature.params[at]))
    at += 1
  end

  function = Model.NativeFunction(
    name: node.name,
    name_range: DiagnosticModel.range_of(node.name_span),
    mode: mode_of(node),
    exported: placed.exported,
    doc: doc_text(placed.doc),
    range: DiagnosticModel.range_of(placed.span),
    parameters: parameters,
    result: signature.result,
    signature: signature.text,
    types_in: signature.from_params.map do |name: String| Types.display_name(name) end,
    types_out: signature.from_result.map do |name: String| Types.display_name(name) end,
  )

  opened_block = opened(found, library, placed.span)
  known = found.types.get(library, [])
  for crossing in signature.crossings
    if (
      crossing.tag != NativeShape.RESOURCE and
      !known.any? do |type: Model.NativeType| type.name == Types.display_name(crossing.name) end
    )
      known = known.push(type_of(crossing))
    end
  end

  ok(
    opened_block.with(
      functions: found.functions.put(library, found.functions.get(library, []).push(function)),
      types: found.types.put(library, known),
    ),
  )
end

# `dirty` for a `compute def`, which runs on the compute pool, else `short`.
def mode_of(node: Ast.FunctionDecl) -> String
  case node.native
    some(native) if native.compute -> "dirty"
    _ -> "short"
  end
end

# A struct or enum that crosses as plain data.
def type_of(crossing: NativeShape.Crossing) -> Model.NativeType
  kind = "enum"
  if crossing.tag == NativeShape.STRUCT
    kind = "struct"
  end

  members = crossing.members.map do |member: NativeShape.Member|
    Model.NativeMember(name: member.name, types: member.types)
  end

  Model.NativeType(kind: kind, name: Types.display_name(crossing.name), members: members, shape: crossing.shape)
end

# `found` with the block of `library` known, and its span grown to hold `span`.
def opened(found: Found, library: String, span: Source.Span) -> Found
  order = found.order
  if !order.include?(library)
    order = order.push(library)
  end

  known = found.spans.get(library, span)
  grown = Source.Span(start: earlier(known.start, span.start), stop: later(known.stop, span.stop))
  found.with(order: order, spans: found.spans.put(library, grown))
end

def earlier(a: Source.Position, b: Source.Position) -> Source.Position
  return b if b.offset < a.offset

  a
end

def later(a: Source.Position, b: Source.Position) -> Source.Position
  return b if b.offset > a.offset

  a
end

# The finished block of `library`: its API version is the least one that has what it declares.
def block_of(found: Found, library: String) -> Model.NativeBlock
  functions = found.functions.get(library, [])
  resources = found.resources.get(library, [])
  types = found.types.get(library, [])
  minor = 0
  if types.size > 0
    minor = NativeShape.API_MINOR_TYPES
  end

  if resources.size > 0
    minor = NativeShape.API_MINOR_RESOURCES
  end

  Model.NativeBlock(
    library: library,
    range: DiagnosticModel.range_of(found.spans[library]),
    api_major: NativeShape.API_MAJOR,
    api_minor: minor,
    functions: functions,
    resources: resources,
    types: types,
  )
end

def doc_text(doc: Optional[String]) -> String = DocModel.cleaned(doc).unwrap_or("")

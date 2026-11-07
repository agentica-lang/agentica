## Extern functions: the body of a function of an `extern "library"` block is one call of the Native.call builtin,
## which the VM answers with libffi (vm/ffi.c). Its arguments are the signature string and a List of the parameters:
## "CODES SYMBOL LIBRARY", the codes of Ast.Native, the C name and the library as written (it may hold spaces, so it is
## last). Each resource that the call makes adds two words after SYMBOL, the C name of its free function (&NAME for a
## free_ref: resource, whose function takes the pointer's address) and the resource's name as written: the result's
## first (result code r), then each out resource's (code R) in order, "CODES SYMBOL FREE NAME ... LIBRARY". A compute
## def puts "compute " in front: the VM then runs the call on its compute pool while the task waits. A function with
## out parameters gets from Native.call a List of the record's fields, in order (the C result, unless Void, then each
## out value), and builds its record from it. A struct passed or returned by value gets the index of its record in the
## struct table after its {: "{N:CODES}", so the VM reads and makes the record itself (nested structs too); the parser
## wrote the field codes in the record's field order.
##
## A function of an `extern module "NAME"` block calls a function of a native module (vm/native_module.c) with
## "module TYPES(PARAMS) -> RESULT NAME LIBRARY" (module_signature), "compute " in front for a compute def.
##
## Native.callback(Name, &function) gets the signature of its callback as its first argument: "CODES NAME", the codes
## of Ast.Callback (the result's first) and the callback's name without its module prefix, which the VM shows for the
## resource.

import Ast from "../syntax/ast"
import Source from "../syntax/source"
import Types from "../syntax/types"
import Ir from "ir"
import Lowering from "lower_state"

## The builtin of every native call, and the most parameters the VM takes for one (AGC_FFI_MAX_PARAMS in vm/ffi_os.h).
NATIVE_CALL = "Native.call"
MAX_PARAMS = 64

## The function that calls the C function, or LOWER-UNSUPPORTED when it has more parameters than the VM takes. structs
## and enums are the program's struct and enum declarations by name, and index is the index of the function's file in
## the program's sources.
export def lower(
  cx: Lowering.Cx,
  function: Ast.FunctionDecl,
  native: Ast.Native,
  structs: Map[String, Ast.StructDecl],
  enums: Map[String, Ast.EnumDecl],
  index: Int,
) -> Result[Ir.Function]
  span = function.span
  count = function.params.size
  if count > MAX_PARAMS
    return error(Lowering.unsupported(cx, "extern functions with more than #{MAX_PARAMS} parameters", span))
  end

  kind = ""
  if native.compute
    kind = "compute "
  end

  signature = ""
  if native.module
    text = try module_signature(cx, function, native, structs, enums)
    signature = kind + text
  else
    codes = try indexed_codes(cx, function, native, structs)
    words = [native.symbol]
    if native.free != ""
      words = words.concat([native.free, native.resource])
    end

    for out in native.outs
      words = words.concat([out.free, out.name])
    end

    signature = "#{kind}#{codes} #{words.join(" ")} #{native.library}"
  end

  body = [
    Ir.instr("step", [], index, [span]),
    Ir.Instr(op: "const", args: [count], imm: Ir.Imm.Text(signature), name: "", file: index, spans: [span]),
    Ir.instr("list", [count + 1, 0, count], index, [span]),
    Ir.Instr(
      op: "call-builtin",
      args: [count, 2],
      imm: Ir.Imm.Void,
      name: NATIVE_CALL,
      file: index,
      spans: [span, span, span],
    ),
  ]

  slots = count + 2
  if record?(native)
    info = cx.structs[function.result.name]
    fields = info.fields.size
    # The fields go to count+1 .. count+fields, read with the index in the register after them.
    position = count + 1 + fields
    field = 0
    while field < fields
      body = body.push(
        Ir.Instr(op: "const", args: [position], imm: Ir.Imm.Int(field), name: "", file: index, spans: [span]),
      )

      body = body.push(Ir.instr("list-get", [count + 1 + field, count, position], index, [span]))
      field += 1
    end

    body = body.push(Ir.instr("struct", [count, count + 1, info.index], index, [span]))
    slots = position + 1
  end

  body = body.push(Ir.instr("return", [count], index, [span]))
  name = function.name
  return ok(Ir.Function(name: name, params: count, captures: 0, slots: slots, body: body, file: index, span: span))
end

## The signature of a callback of an extern block that Native.callback gets: "CODES NAME".
export def callback_signature(decl: Ast.ResourceDecl) -> String
  case decl.callback
    some(callback) -> return "#{callback.codes} #{Types.display_name(decl.name)}"
    none -> return ""
  end
end

## The layout code of the C struct of this name with the index of each struct after its {, "{N:CODES}" as in a
## signature, for Native.size_of, get_struct and put_struct: the VM lays it out as it lays out a struct argument.
export def struct_layout(cx: Lowering.Cx, name: String, structs: Map[String, Ast.StructDecl]) -> Result[String]
  decl = structs[name]
  return indexed(cx, decl.layout, nested_structs(name, structs), name, decl.span)
end

# The signature of a function of a native module, after any "compute ": "module TYPES(PARAMS) -> RESULT NAME LIBRARY".
# PARAMS and RESULT are the canonical Agentica types, the text of the types the checker recorded for the written ones
# (check_native.agc: aliases expanded, user types by their bare names), which the module's table must have byte for
# byte. TYPES has one {S<index>=SHAPE} or {E<index>=SHAPE} for each struct or enum that crosses, in the order the walk
# meets them: its index in the table of structs or enums, and its shape, which the module's type of that name must
# have too: "name: Type, ..." for a struct, "Variant | Variant(Type, ...)" for an enum, from the recorded types of
# its fields and payloads; and one {R=Name} for each resource, which the module's resource table must have. NAME is
# the def's name and LIBRARY the module's name as written (it may hold spaces, so it is last).
def module_signature(
  cx: Lowering.Cx,
  function: Ast.FunctionDecl,
  native: Ast.Native,
  structs: Map[String, Ast.StructDecl],
  enums: Map[String, Ast.EnumDecl],
) -> Result[String]
  span = function.span
  params: List[String] = []
  pending: List[Types.Type] = []
  for param in function.params
    type = try recorded(cx, param.type, span)
    params = params.push(Types.to_text(type))
    pending = pending.push(type)
  end

  result = try recorded(cx, function.result, span)
  pending = pending.push(result)
  blocks: List[String] = []
  seen: Set[String] = Set.new([])
  at = 0
  while at < pending.size
    type = pending[at]
    at += 1
    name = Types.name(type)
    if seen.include?(name)
      next
    end

    if Types.is?(type, "Struct")
      seen = seen.add(name)
      fields: List[String] = []
      for field in structs[name].fields
        field_type = try recorded(cx, field.type, span)
        fields = fields.push("#{field.name}: #{Types.to_text(field_type)}")
        pending = pending.push(field_type)
      end

      blocks = blocks.push("{S#{cx.structs[name].index}=#{fields.join(", ")}}")
    elsif Types.is?(type, "Enum")
      seen = seen.add(name)
      variants: List[String] = []
      for variant in enums[name].variants
        payload: List[String] = []
        for ref in variant.payload_types
          payload_type = try recorded(cx, ref, span)
          payload = payload.push(Types.to_text(payload_type))
          pending = pending.push(payload_type)
        end

        if payload.size == 0
          variants = variants.push(variant.name)
        else
          variants = variants.push("#{variant.name}(#{payload.join(", ")})")
        end
      end

      blocks = blocks.push("{E#{cx.enums[name]}=#{variants.join(" | ")}}")
    elsif Types.is?(type, "Opaque")
      # The checker lets only a resource of the module block through as an opaque type.
      seen = seen.add(name)
      blocks = blocks.push("{R=#{Types.display_name(name)}}")
    else
      pending = pending.concat(inner_types(type))
    end
  end

  canon = "(#{params.join(", ")}) -> #{Types.to_text(result)}"
  return ok("module #{blocks.join("")}#{canon} #{native.symbol} #{native.library}")
end

# The type the checker recorded for a written type of a native module function, or LOWER-INTERNAL when it has none.
def recorded(cx: Lowering.Cx, ref: Ast.TypeRef, span: Source.Span) -> Result[Types.Type]
  if ref.id < 0 or ref.id >= cx.types.size or Types.unknown?(cx.types[ref.id])
    return error(Lowering.internal(cx, "the checker recorded no type for #{ref.name}", span))
  end

  return ok(cx.types[ref.id])
end

# The types inside a List, Optional, Result or Map, which crossing types are besides the scalars and user types.
def inner_types(type: Types.Type) -> List[Types.Type]
  if Types.is?(type, "Map")
    return [Types.key(type), Types.value(type)]
  end

  if Types.is?(type, "List") or Types.is?(type, "Optional") or Types.is?(type, "Result")
    return [Types.item(type)]
  end

  return []
end

# Whether the function has out parameters: one of the codes is a capital (no other code holds one).
def record?(native: Ast.Native) -> Bool
  return native.codes.split("").any? do |code: String| "ABCDEFGHIJKLMNOPQRSTUVWXYZ".contains?(code) end
end

# The codes of the signature with the index of each struct after its {. The structs come in the order of their {: the C
# result's (the field result of the record of a function with out parameters), then each parameter's, each one before
# the structs of its fields. LOWER-INTERNAL when they do not match the codes.
def indexed_codes(
  cx: Lowering.Cx,
  function: Ast.FunctionDecl,
  native: Ast.Native,
  structs: Map[String, Ast.StructDecl],
) -> Result[String]
  pieces = native.codes.split("{")
  if pieces.size == 1
    return ok(native.codes)
  end

  result = function.result.name
  if record?(native)
    first = structs[result].fields[0]
    result = ""
    if first.name == "result"
      result = first.type.name
    end
  end

  names = nested_structs(result, structs)
  for param in function.params
    names = names.concat(nested_structs(param.type.name, structs))
  end

  return indexed(cx, native.codes, names, function.name, function.span)
end

# The codes with the index of the struct names, in order, after each {; LOWER-INTERNAL when they do not match.
def indexed(cx: Lowering.Cx, codes: String, names: List[String], owner: String, span: Source.Span) -> Result[String]
  pieces = codes.split("{")
  if names.size != pieces.size - 1
    return error(Lowering.internal(cx, "the structs of #{owner} do not match its codes", span))
  end

  out = pieces[0]
  at = 1
  for name in names
    out += "{#{cx.structs[name].index}:#{pieces[at]}"
    at += 1
  end

  return ok(out)
end

# The struct of this name, then the structs of its fields in order, each before its own; none when it is not a struct.
def nested_structs(name: String, structs: Map[String, Ast.StructDecl]) -> List[String]
  if !structs.has_key?(name)
    return []
  end

  names = [name]
  for field in structs[name].fields
    names = names.concat(nested_structs(field.type.name, structs))
  end

  return names
end

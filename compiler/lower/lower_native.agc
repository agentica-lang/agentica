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
## are the program's struct declarations by name, and index is the index of the function's file in the program's
## sources.
export def lower(
  cx: Lowering.Cx,
  function: Ast.FunctionDecl,
  native: Ast.Native,
  structs: Map[String, Ast.StructDecl],
  index: Int,
) -> Result[Ir.Function]
  span = function.span
  count = function.params.size
  if count > MAX_PARAMS
    return error(Lowering.unsupported(cx, "extern functions with more than #{MAX_PARAMS} parameters", span))
  end

  codes = try indexed_codes(cx, function, native, structs)
  kind = ""
  if native.compute
    kind = "compute "
  end

  words = [native.symbol]
  if native.free != ""
    words = words.concat([native.free, native.resource])
  end

  for out in native.outs
    words = words.concat([out.free, out.name])
  end

  signature = "#{kind}#{codes} #{words.join(" ")} #{native.library}"
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

# Whether the function has out parameters: one of the codes is a capital (no other code holds one).
def record?(native: Ast.Native) -> Bool
  return native.codes.split("").any? do |code: String| "ABCDEFGHIJKLMNOPQRSTUVWXYZ".contains?(code) end
end

# The codes of the signature with the index of each struct after its {. The structs come in the order of their {: the C
# result's (the field result of the record of a function with out parameters), then each parameter's, each one before
# the structs of its fields. LOWER-INTERNAL when they do not match the codes.
def indexed_codes(
  cx: Lowering.Cx, function: Ast.FunctionDecl, native: Ast.Native, structs: Map[String, Ast.StructDecl],
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

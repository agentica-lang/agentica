## Extern functions: the body of a function of an `extern "library"` block is one call of the Native.call builtin,
## which the VM answers with libffi (vm/ffi.c). Its arguments are the signature string and a List of the parameters:
## "CODES SYMBOL LIBRARY", the codes of Ast.Native, the C name and the library as written (it may hold spaces, so it is
## last). Each resource that the call makes adds two words after SYMBOL, the C name of its free function and the
## resource's name as written: the result's first (result code r), then each out resource's (code R) in order,
## "CODES SYMBOL FREE NAME ... LIBRARY". A compute def puts "compute " in front: the VM then runs the call on its
## compute pool while the task waits. A function with out parameters gets from Native.call a List of the record's
## fields, in order (the C result, unless Void, then each out value), and builds its record from it.

import Ast from "../syntax/ast"
import Ir from "ir"
import Lowering from "lower_state"

## The builtin of every native call, and the most parameters the VM takes for one (AGC_FFI_MAX_PARAMS in vm/ffi_os.h).
NATIVE_CALL = "Native.call"
MAX_PARAMS = 64

## The function that calls the C function, or LOWER-UNSUPPORTED when it has more parameters than the VM takes. index
## is the index of the function's file in the program's sources.
export def lower(cx: Lowering.Cx, function: Ast.FunctionDecl, native: Ast.Native, index: Int) -> Result[Ir.Function]
  span = function.span
  count = function.params.size
  if count > MAX_PARAMS
    return error(Lowering.unsupported(cx, "extern functions with more than #{MAX_PARAMS} parameters", span))
  end
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
  signature = "#{kind}#{native.codes} #{words.join(" ")} #{native.library}"
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

# Whether the function has out parameters: one of the codes is a capital.
def record?(native: Ast.Native) -> Bool
  return native.codes.split("").any? do |code: String| "ILDFBPR".contains?(code) end
end

## Extern functions: the body of a function of an `extern "library"` block is one call of the Native.call builtin,
## which the VM answers with libffi (vm/ffi.c). Its arguments are the signature string and a List of the parameters:
## "CODES SYMBOL LIBRARY", the codes of Ast.Native, the C name and the library as written (it may hold spaces, so it is
## last). A function that returns a resource (result code r) has two more words after SYMBOL: the C name of the
## resource's free function and the resource's name as written, "CODES SYMBOL FREE NAME LIBRARY". A compute def puts
## "compute " in front: the VM then runs the call on its compute pool while the task waits.

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
  symbol = native.symbol
  if native.free != ""
    symbol = "#{symbol} #{native.free} #{native.resource}"
  end
  signature = "#{kind}#{native.codes} #{symbol} #{native.library}"
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
    Ir.instr("return", [count], index, [span]),
  ]
  name = function.name
  return ok(Ir.Function(name: name, params: count, captures: 0, slots: count + 2, body: body, file: index, span: span))
end

import Types from "../syntax/types"
import Model from "builtin_model"

ROWS: List[Model.Builtin] = [
  Model.Builtin(
    name: "Native.address",
    parameters: [Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer"))],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Native.address",
    effects: ["native"],
    description: (
      "The integer value of the C.Pointer, the inverse of Native.pointer: subtract two to count the bytes between " +
      "them. A freed owned buffer is RUNTIME-NATIVE-CLOSED."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.callback",
    parameters: [
      Model.Named(name: "type", type: Types.Type.Var("T")),
      Model.Named(name: "function", type: Types.Type.Var("F")),
    ],
    result: Types.Type.Var("T"),
    rule: Model.Rule.NativeCallback,
    implementation: "Native.callback",
    effects: ["native"],
    description: (
      "A C function pointer of a callback of an extern block that calls the named function, a resource that " +
      "the calling task owns; C must not call it after Native.close or the owner's end."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.close",
    parameters: [Model.Named(name: "resource", type: Types.Type.Var("R"))],
    result: Types.Type.Void,
    rule: Model.Rule.NativeClose,
    implementation: "Native.close",
    effects: ["native"],
    description: (
      "Free a resource of an extern block with its free function, once; a closed resource is left as it is and " +
      "a native call with it fails with RUNTIME-NATIVE-CLOSED."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.closed?",
    parameters: [Model.Named(name: "resource", type: Types.Type.Var("R"))],
    result: Types.Type.Bool,
    rule: Model.Rule.NativeClosed,
    implementation: "Native.closed?",
    effects: ["native"],
    description: (
      "True when a resource is closed (by Native.close, its owner's end, or C leaving an out resource NULL) or an " +
      "owned buffer is freed; false for a live one and for a C.Pointer of C. It never stops the task."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.free",
    parameters: [Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer"))],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.free",
    effects: ["native"],
    description: (
      "Free an owned buffer of Native.memory_pointer once; a freed buffer is left as it is, and a C.Pointer of C " +
      "or a view is RUNTIME-NATIVE-NOT-OWNED."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.from_string",
    parameters: [Model.Named(name: "text", type: Types.Type.String)],
    result: Types.Type.Opaque("C.Pointer"),
    rule: Model.Rule.Plain,
    implementation: "Native.from_string",
    effects: ["native"],
    description: (
      "A new owned buffer of the UTF-8 bytes of text and a NUL after them (text.bytesize + 1 bytes, a NUL inside " +
      "text kept), as a C.Pointer that the calling task owns, like Native.memory_pointer. With a block, it is " +
      "freed when the block ends and the call returns the block's value."
    ),
    alternatives: [
      Model.Builtin(
        name: "Native.from_string",
        parameters: [
          Model.Named(name: "text", type: Types.Type.String),
          Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Opaque("C.Pointer")], Types.Type.Var("T"))),
        ],
        result: Types.Type.Var("T"),
        rule: Model.Rule.NativeMemoryBlock,
        implementation: "Native.from_string",
        effects: ["native"],
        description: (
          "Yield a new owned buffer of the UTF-8 bytes of text and a NUL to the block, free it when the block " +
          "ends (an error it returns included), and return the block's value."
        ),
        alternatives: [],
      ),
    ],
  ),
  Model.Builtin(
    name: "Native.get_array_of_float32",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "count", type: Types.Type.Int),
    ],
    result: Types.Type.List(Types.Type.Float),
    rule: Model.Rule.Plain,
    implementation: "Native.get_array_of_float32",
    effects: ["native"],
    description: (
      "Read count 32-bit floats from offset bytes past the C.Pointer into a list; a negative count is " +
      "RUNTIME-INVALID-COUNT."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_array_of_float64",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "count", type: Types.Type.Int),
    ],
    result: Types.Type.List(Types.Type.Float),
    rule: Model.Rule.Plain,
    implementation: "Native.get_array_of_float64",
    effects: ["native"],
    description: (
      "Read count 64-bit doubles from offset bytes past the C.Pointer into a list; a negative count is " +
      "RUNTIME-INVALID-COUNT."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_array_of_int32",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "count", type: Types.Type.Int),
    ],
    result: Types.Type.List(Types.Type.Int),
    rule: Model.Rule.Plain,
    implementation: "Native.get_array_of_int32",
    effects: ["native"],
    description: (
      "Read count signed 32-bit integers from offset bytes past the C.Pointer into a list; a negative count is " +
      "RUNTIME-INVALID-COUNT."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_array_of_int64",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "count", type: Types.Type.Int),
    ],
    result: Types.Type.List(Types.Type.Int),
    rule: Model.Rule.Plain,
    implementation: "Native.get_array_of_int64",
    effects: ["native"],
    description: (
      "Read count signed 64-bit integers from offset bytes past the C.Pointer into a list; a negative count is " +
      "RUNTIME-INVALID-COUNT."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_bytes",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "length", type: Types.Type.Int),
    ],
    result: Types.Type.Bytes,
    rule: Model.Rule.Plain,
    implementation: "Native.get_bytes.bytes",
    effects: ["native"],
    description: (
      "Copy length bytes from offset bytes past the C.Pointer into a Bytes; NULL with length 0 is empty, other " +
      "NULL is RUNTIME-NATIVE-NULL, a negative length RUNTIME-INVALID-COUNT; a length past C memory is undefined."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_float32",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
    ],
    result: Types.Type.Float,
    rule: Model.Rule.Plain,
    implementation: "Native.get_float32",
    effects: ["native"],
    description: (
      "Read a 32-bit float at offset bytes past the C.Pointer; see Native.memory_pointer for the bounds of an " +
      "owned buffer."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_float64",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
    ],
    result: Types.Type.Float,
    rule: Model.Rule.Plain,
    implementation: "Native.get_float64",
    effects: ["native"],
    description: (
      "Read a 64-bit double at offset bytes past the C.Pointer; see Native.memory_pointer for the bounds of an " +
      "owned buffer."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_int16",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
    ],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Native.get_int16",
    effects: ["native"],
    description: (
      "Read a signed 16-bit integer at offset bytes past the C.Pointer; see Native.memory_pointer for the bounds " +
      "of an owned buffer."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_int32",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
    ],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Native.get_int32",
    effects: ["native"],
    description: (
      "Read a signed 32-bit integer at offset bytes past the C.Pointer; see Native.memory_pointer for the bounds " +
      "of an owned buffer."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_int64",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
    ],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Native.get_int64",
    effects: ["native"],
    description: (
      "Read a signed 64-bit integer at offset bytes past the C.Pointer; see Native.memory_pointer for the bounds " +
      "of an owned buffer."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_int8",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
    ],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Native.get_int8",
    effects: ["native"],
    description: (
      "Read a signed 8-bit integer at offset bytes past the C.Pointer; see Native.memory_pointer for the bounds " +
      "of an owned buffer."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_pointer",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
    ],
    result: Types.Type.Opaque("C.Pointer"),
    rule: Model.Rule.Plain,
    implementation: "Native.get_pointer",
    effects: ["native"],
    description: (
      "Read a pointer at offset bytes past the C.Pointer; see Native.memory_pointer for the bounds of an owned " +
      "buffer."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_string",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
    ],
    result: Types.Type.String,
    rule: Model.Rule.Plain,
    implementation: "Native.get_string",
    effects: ["native"],
    description: (
      "Copy the NUL-terminated text from offset bytes past the C.Pointer; bytes that are not UTF-8 become U+FFFD, " +
      "and NULL is RUNTIME-NATIVE-NULL."
    ),
    alternatives: [
      Model.Builtin(
        name: "Native.get_string",
        parameters: [
          Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
          Model.Named(name: "offset", type: Types.Type.Int),
          Model.Named(name: "length", type: Types.Type.Int),
        ],
        result: Types.Type.String,
        rule: Model.Rule.Plain,
        implementation: "Native.get_string",
        effects: ["native"],
        description: (
          "Copy exactly length bytes from offset bytes past the C.Pointer, NUL bytes included; NULL with length 0 " +
          "is \"\", other NULL is RUNTIME-NATIVE-NULL, a negative length RUNTIME-INVALID-COUNT."
        ),
        alternatives: [],
      ),
    ],
  ),
  Model.Builtin(
    name: "Native.get_struct",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "type", type: Types.Type.Var("T")),
    ],
    result: Types.Type.Var("T"),
    rule: Model.Rule.NativeStruct,
    implementation: "Native.get_struct",
    effects: ["native"],
    description: (
      "Read a struct of an extern block, laid out as C does, at offset bytes past the C.Pointer; see " +
      "Native.memory_pointer for the bounds of an owned buffer."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_uint16",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
    ],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Native.get_uint16",
    effects: ["native"],
    description: (
      "Read an unsigned 16-bit integer at offset bytes past the C.Pointer; see Native.memory_pointer for the " +
      "bounds of an owned buffer."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_uint32",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
    ],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Native.get_uint32",
    effects: ["native"],
    description: (
      "Read an unsigned 32-bit integer at offset bytes past the C.Pointer; see Native.memory_pointer for the " +
      "bounds of an owned buffer."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.get_uint8",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
    ],
    result: Types.Type.Int,
    rule: Model.Rule.Plain,
    implementation: "Native.get_uint8",
    effects: ["native"],
    description: (
      "Read an unsigned 8-bit integer at offset bytes past the C.Pointer; see Native.memory_pointer for the " +
      "bounds of an owned buffer."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.load",
    parameters: [Model.Named(name: "library", type: Types.Type.String)],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "Native.load",
    effects: ["native"],
    description: (
      "Open the library that extern \"library\" names (a string literal, CHECK-NATIVE-LOAD otherwise) now, or " +
      "give its loader error; the library stays open for the extern functions. Refused by --deny-native."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.function?",
    parameters: [
      Model.Named(name: "library", type: Types.Type.String),
      Model.Named(name: "name", type: Types.Type.String),
    ],
    result: Types.Type.Bool,
    rule: Model.Rule.Plain,
    implementation: "Native.function?",
    effects: ["native"],
    description: (
      "Whether the library that extern \"library\" names (a string literal, CHECK-NATIVE-LOAD otherwise) opens and " +
      "exports the function name, so a program can fall back before it calls one that the library lacks. Refused by " +
      "--deny-native."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.memory_pointer",
    parameters: [Model.Named(name: "size", type: Types.Type.Int)],
    result: Types.Type.Opaque("C.Pointer"),
    rule: Model.Rule.Plain,
    implementation: "Native.memory_pointer",
    effects: ["native"],
    description: (
      "A new owned buffer of size zeroed bytes, as a C.Pointer that the calling task owns; Native.free or the " +
      "owner's end frees it, and every read or write past it is RUNTIME-NATIVE-BOUNDS. With a block, it is freed " +
      "when the block ends and the call returns the block's value."
    ),
    alternatives: [
      Model.Builtin(
        name: "Native.memory_pointer",
        parameters: [
          Model.Named(name: "size", type: Types.Type.Int),
          Model.Named(name: "block", type: Types.Type.Fn([Types.Type.Opaque("C.Pointer")], Types.Type.Var("T"))),
        ],
        result: Types.Type.Var("T"),
        rule: Model.Rule.NativeMemoryBlock,
        implementation: "Native.memory_pointer",
        effects: ["native"],
        description: (
          "Yield a new owned buffer of size zeroed bytes to the block, free it when the block ends (an error it " +
          "returns included), and return the block's value."
        ),
        alternatives: [],
      ),
    ],
  ),
  Model.Builtin(
    name: "Native.null",
    parameters: [],
    result: Types.Type.Opaque("C.Pointer"),
    rule: Model.Rule.Plain,
    implementation: "Native.null",
    effects: ["native"],
    description: "The NULL C.Pointer.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.null?",
    parameters: [Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer"))],
    result: Types.Type.Bool,
    rule: Model.Rule.Plain,
    implementation: "Native.null?",
    effects: ["native"],
    description: "True when the C.Pointer is NULL.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.offset",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
    ],
    result: Types.Type.Opaque("C.Pointer"),
    rule: Model.Rule.Plain,
    implementation: "Native.offset",
    effects: ["native"],
    description: (
      "The C.Pointer offset bytes further. In an owned buffer it is a view up to the buffer's end (offset 0 to " +
      "the size, else RUNTIME-NATIVE-BOUNDS), freed with the buffer; Native.free of a view is " +
      "RUNTIME-NATIVE-NOT-OWNED."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.pointer",
    parameters: [Model.Named(name: "address", type: Types.Type.Int)],
    result: Types.Type.Opaque("C.Pointer"),
    rule: Model.Rule.Plain,
    implementation: "Native.pointer",
    effects: ["native"],
    description: "The C.Pointer with this integer value, for a sentinel such as SQLITE_TRANSIENT (-1).",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_array_of_float32",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "values", type: Types.Type.List(Types.Type.Float)),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_array_of_float32",
    effects: ["native"],
    description: (
      "Write the values as 32-bit floats from offset bytes past the C.Pointer; every value is checked before the " +
      "first write."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_array_of_float64",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "values", type: Types.Type.List(Types.Type.Float)),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_array_of_float64",
    effects: ["native"],
    description: (
      "Write the values as 64-bit doubles from offset bytes past the C.Pointer; every value is checked before the " +
      "first write."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_array_of_int32",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "values", type: Types.Type.List(Types.Type.Int)),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_array_of_int32",
    effects: ["native"],
    description: (
      "Write the values as signed 32-bit integers from offset bytes past the C.Pointer; every value is checked " +
      "before the first write."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_array_of_int64",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "values", type: Types.Type.List(Types.Type.Int)),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_array_of_int64",
    effects: ["native"],
    description: (
      "Write the values as signed 64-bit integers from offset bytes past the C.Pointer; every value is checked " +
      "before the first write."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_bytes",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "bytes", type: Types.Type.Bytes),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_bytes.bytes",
    effects: ["native"],
    description: "Write the bytes from offset bytes past the C.Pointer.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_float32",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "value", type: Types.Type.Float),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_float32",
    effects: ["native"],
    description: "Write value as a 32-bit float at offset bytes past the C.Pointer.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_float64",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "value", type: Types.Type.Float),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_float64",
    effects: ["native"],
    description: "Write value as a 64-bit double at offset bytes past the C.Pointer.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_int16",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "value", type: Types.Type.Int),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_int16",
    effects: ["native"],
    description: (
      "Write value as a 16-bit integer (-32768 to 65535) at offset bytes past the C.Pointer; a value outside that " +
      "range is RUNTIME-INTEGER-OVERFLOW."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_int32",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "value", type: Types.Type.Int),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_int32",
    effects: ["native"],
    description: (
      "Write value as a 32-bit integer (-2147483648 to 4294967295) at offset bytes past the C.Pointer; a value " +
      "outside that range is RUNTIME-INTEGER-OVERFLOW."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_int64",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "value", type: Types.Type.Int),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_int64",
    effects: ["native"],
    description: "Write value as a 64-bit integer at offset bytes past the C.Pointer.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_int8",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "value", type: Types.Type.Int),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_int8",
    effects: ["native"],
    description: (
      "Write value as an 8-bit integer (-128 to 255) at offset bytes past the C.Pointer; a value outside that " +
      "range is RUNTIME-INTEGER-OVERFLOW."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_pointer",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "value", type: Types.Type.Opaque("C.Pointer")),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_pointer",
    effects: ["native"],
    description: "Write value as a pointer at offset bytes past the C.Pointer.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_string",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "text", type: Types.Type.String),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.Plain,
    implementation: "Native.put_string",
    effects: ["native"],
    description: (
      "Write the bytes of text and a NUL after them at offset bytes past the C.Pointer, a C string; a NUL in text " +
      "is RUNTIME-INVALID-CHARACTER."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.put_struct",
    parameters: [
      Model.Named(name: "pointer", type: Types.Type.Opaque("C.Pointer")),
      Model.Named(name: "offset", type: Types.Type.Int),
      Model.Named(name: "value", type: Types.Type.Var("T")),
    ],
    result: Types.Type.Void,
    rule: Model.Rule.NativeStruct,
    implementation: "Native.put_struct",
    effects: ["native"],
    description: (
      "Write a struct of an extern block, laid out as C does, at offset bytes past the C.Pointer; a field is " +
      "checked as for an extern call."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.size_of",
    parameters: [Model.Named(name: "type", type: Types.Type.Var("T"))],
    result: Types.Type.Int,
    rule: Model.Rule.NativeStruct,
    implementation: "Native.size_of",
    effects: ["native"],
    description: "The size in bytes of a struct of an extern block as C lays it out (sizeof), padding included.",
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.wait_readable",
    parameters: [Model.Named(name: "fd", type: Types.Type.Int), Model.Named(name: "timeout_ms", type: Types.Type.Int)],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "Native.wait_readable",
    effects: ["native"],
    description: (
      "Park this task until the descriptor fd of native code can be read, at most positive timeout_ms " +
      "(error native: timed out); Linux only, refused by --deny-native."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.wait_writable",
    parameters: [Model.Named(name: "fd", type: Types.Type.Int), Model.Named(name: "timeout_ms", type: Types.Type.Int)],
    result: Types.Type.Result(Types.Type.Void),
    rule: Model.Rule.Plain,
    implementation: "Native.wait_writable",
    effects: ["native"],
    description: (
      "Park this task until the descriptor fd of native code can be written, at most positive timeout_ms " +
      "(error native: timed out); Linux only, refused by --deny-native."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.mutex",
    parameters: [],
    result: Types.Type.Opaque("Native.Mutex"),
    rule: Model.Rule.Plain,
    implementation: "Native.mutex",
    effects: ["native"],
    description: (
      "A new Native.Mutex, for the calls of a native library that is not thread-safe: native calls run on several " +
      "schedulers at once."
    ),
    alternatives: [],
  ),
  Model.Builtin(
    name: "Native.Mutex.synchronize",
    parameters: [
      Model.Named(name: "mutex", type: Types.Type.Opaque("Native.Mutex")),
      Model.Named(name: "block", type: Types.Type.Fn([], Types.Type.Var("T"))),
    ],
    result: Types.Type.Var("T"),
    rule: Model.Rule.NativeSynchronize,
    implementation: "Native.Mutex.synchronize",
    effects: ["native"],
    description: (
      "Run the block with the mutex held and return its value; a task that waits for it parks, so other tasks " +
      "run; a task that holds it already is RUNTIME-NATIVE-MUTEX."
    ),
    alternatives: [],
  ),
]

## The types the checker works with, as an enum.

## The builtin types that a std/ module re-exports, by their builtin name, with the name a program writes: the alias
## that the module's docs import it as (STD_ONLY_IMPORTS of the catalog), then the member. Messages, `help`, `doc`,
## the queries and a printed value (vm/text.c) show the written name.
REEXPORTED_TYPES: Map[String, String] = {
  "HttpWire.ClientOptions": "HTTP.ClientOptions",
  "HttpWire.Header": "HTTP.Header",
  "HttpWire.Request": "HTTP.Request",
  "HttpWire.Response": "HTTP.Response",
  "HttpWire.Server": "HTTP.Server",
  "HttpWire.ServerOptions": "HTTP.ServerOptions",
  "LogRegistry.Event": "Logger.Event",
  "LogRegistry.Level": "Logger.Level",
}

## The integer types narrower than Int, by name, with their least and greatest values. Only the checker tells them from
## Int: the VM holds their values as Ints.
NARROW_INTS: Map[String, List[Int]] = {
  "Int8": [-128, 127],
  "Int16": [-32768, 32767],
  "Int32": [-2147483648, 2147483647],
  "UInt8": [0, 255],
  "UInt16": [0, 65535],
  "UInt32": [0, 4294967295],
}

## The decimal digits of the greatest UInt64. It has its own tag in the VM, and its range does not fit an Int.
UINT64_MAX_DIGITS = "18446744073709551615"
## 2^128 - 2^103 as a Float and as its digits: a float literal from it up rounds to an infinity in Float32.
FLOAT32_HALFWAY = 340282356779733661637539395458142568448.0
FLOAT32_HALFWAY_DIGITS = "340282356779733661637539395458142568448"

## The narrow integer types by name.
NARROW_TYPES: Map[String, Type] = {
  "Int8": Type.Int8,
  "Int16": Type.Int16,
  "Int32": Type.Int32,
  "UInt8": Type.UInt8,
  "UInt16": Type.UInt16,
  "UInt32": Type.UInt32,
}

## The linked name of the builtin type Ref (Ref.new). Ref is not reserved, and the names of the root file keep no
## prefix, so the linker gives the builtin a name that no file can declare, as it does to the names of other files.
REF_TYPE = "@Ref"

## A resolved type. Opaque holds the name of a handle or other builtin type with no structure (TCP.Socket, Process,
## Test.Case, C.Pointer), or the linked name of a resource of an extern block. Struct and Enum hold the linked name and
## carry their type arguments (none for a plain struct or enum). Var is a type variable of a builtin signature, a
## generic struct or a generic enum. Fn lists the parameters, then the result. Codec is Codec[T], the codec of a
## struct or enum (T.codec). Optional is Optional[T], a value that is some(x) or none. Unknown is no type: the expected
## type when none is known (Unknown), and the type of a literal the lexer could not classify.
enum Type
  Int
  Float
  Int8
  Int16
  Int32
  UInt8
  UInt16
  UInt32
  UInt64
  Float32
  Bool
  String
  Nil
  Void
  Json
  Range
  Bytes
  Unknown
  Opaque(String)
  Result(Type)
  Optional(Type)
  Task(Type)
  Channel(Type)
  Address(Type)
  Lazy(Type)
  Codec(Type)
  List(Type)
  Set(Type)
  Map(Type, Type)
  ATS(Type, Type)
  Fn(List[Type], Type)
  Struct(String, List[Type])
  Enum(String, List[Type])
  Var(String)
end

## The builtin Error record, the payload of a failed Result.
def error_type() -> Type = Type.Struct("Error", [])

## True for the builtin Error record.
def error?(type: Type) -> Bool = tag(type) == "Struct" and name(type) == "Error"

## The variant of a type as a word: "Int", "List", "Struct", ... Every test of a type's shape is a comparison with this
## word.
def tag(type: Type) -> String
  case type
    Type.Int -> "Int"
    Type.Float -> "Float"
    Type.Int8 -> "Int8"
    Type.Int16 -> "Int16"
    Type.Int32 -> "Int32"
    Type.UInt8 -> "UInt8"
    Type.UInt16 -> "UInt16"
    Type.UInt32 -> "UInt32"
    Type.UInt64 -> "UInt64"
    Type.Float32 -> "Float32"
    Type.Bool -> "Bool"
    Type.String -> "String"
    Type.Nil -> "Nil"
    Type.Void -> "Void"
    Type.Json -> "Json"
    Type.Range -> "Range"
    Type.Bytes -> "Bytes"
    Type.Unknown -> "Unknown"
    Type.Opaque(_) -> "Opaque"
    Type.Result(_) -> "Result"
    Type.Optional(_) -> "Optional"
    Type.Task(_) -> "Task"
    Type.Channel(_) -> "Channel"
    Type.Address(_) -> "Address"
    Type.Lazy(_) -> "Lazy"
    Type.Codec(_) -> "Codec"
    Type.List(_) -> "List"
    Type.Set(_) -> "Set"
    Type.Map(_, _) -> "Map"
    Type.ATS(_, _) -> "ATS"
    Type.Fn(_, _) -> "Fn"
    Type.Struct(_, _) -> "Struct"
    Type.Enum(_, _) -> "Enum"
    Type.Var(_) -> "Var"
  end
end

## True when the type is that variant: is?(type, "List").
def is?(type: Type, word: String) -> Bool = tag(type) == word

## True for Int8, Int16, Int32, UInt8, UInt16 and UInt32.
def narrow_int?(type: Type) -> Bool = NARROW_INTS.has_key?(tag(type))

## True for UInt64, the integer type that has a tag of its own in the VM.
def uint64?(type: Type) -> Bool = tag(type) == "UInt64"

## True for a narrow integer type and for UInt64: the types whose literals the context gives, and that the operators
## take two of.
def sized_int?(type: Type) -> Bool = narrow_int?(type) or uint64?(type)

## True for UInt8, UInt16, UInt32 and UInt64.
def unsigned?(type: Type) -> Bool = uint64?(type) or (narrow_int?(type) and NARROW_INTS[tag(type)][0] == 0)

## True when the sized integer type holds the value. UInt64 holds every Int from 0 up.
def narrow_fits?(type: Type, value: Int) -> Bool
  return value >= 0 if uint64?(type)

  bounds = NARROW_INTS[tag(type)]
  value >= bounds[0] and value <= bounds[1]
end

## True when the digits of an integer literal, past the Int range, are no more than the greatest UInt64. A literal with
## a prefix or a sign (the Huge text of a long hex literal, `-5`) is not.
def uint64_digits_fit?(digits: String) -> Bool
  return false if digits.length > UINT64_MAX_DIGITS.length or !digits.split("").all? do |c: String| digit?(c) end
  return true if digits.length < UINT64_MAX_DIGITS.length

  head = digits.slice(0, 19).to_i!
  head < 1844674407370955161 or (head == 1844674407370955161 and digits.slice(19, 1).to_i! <= 5)
end

## The Int that holds the 64 bits of a UInt64 literal above the greatest Int (a Huge literal): its value less 2^64.
## With 2^64 = 10 * 1844674407370955161 + 6, the sum 10 * head + last - 2^64 is computed as
## 10 * (head - 1844674407370955160) + last - 16, which stays in the Int range. The checker has seen the digits fit
## (uint64_digits_fit?).
def uint64_bits(digits: String) -> Int
  head = digits.slice(0, digits.length - 1).to_i!
  last = digits.slice(digits.length - 1, 1).to_i!
  10 * (head - 1844674407370955160) + (last - 16)
end

## The message of a literal (its text) that the sized integer type does not hold: "300 is outside UInt8, 0 to 255".
def narrow_outside(type: Type, text: String) -> String
  return "#{text} is outside UInt64, 0 to #{UINT64_MAX_DIGITS}" if uint64?(type)

  bounds = NARROW_INTS[tag(type)]
  "#{text} is outside #{tag(type)}, #{bounds[0]} to #{bounds[1]}"
end

## True for a Float halfway between two Float32s: the texts on either side of it, which it stands for, give two.
def float32_halfway?(x: Float) -> Bool
  magnitude = x.abs
  rounded = magnitude.to_float32
  near = rounded.to_f
  return false if near == magnitude

  bits = rounded.to_bits
  other = Float32.from_bits(bits + 1).to_f
  if near > magnitude
    other = Float32.from_bits(bits - 1).to_f
  end

  (near + other) / 2.0 == magnitude
end

## The bits of the Float32 that a float literal gives, its value and its text, or none when its Float is halfway
## between two Float32s and the text is not that Float exactly (or that cannot be told in 62 bits).
def float32_bits(x: Float, text: String) -> Optional[Int]
  return some(x.to_float32.to_bits.to_i) if !float32_halfway?(x) or exact_text?(x.abs, text)

  none
end

## True when a float literal, its value and its text, rounds to an infinity in the type, Float or Float32. In Float32
## that is from 2^128 - 2^103 up, halfway between the largest Float32 and 2^128; that bound is a Float, so only a text
## whose Float is the bound itself needs its digits: the part before the point decides, as the text is that close.
def float_overflow?(type: Type, number: Float, text: String) -> Bool
  magnitude = number.abs
  return Float.to_bits(magnitude) == 0x7FF0000000000000 if !is?(type, "Float32")
  return magnitude > FLOAT32_HALFWAY if magnitude != FLOAT32_HALFWAY

  digits = integer_digits(text)
  return digits.size > FLOAT32_HALFWAY_DIGITS.size if digits.size != FLOAT32_HALFWAY_DIGITS.size

  for at in 0...digits.size
    mine = digits.slice(at, 1).to_i!
    bound = FLOAT32_HALFWAY_DIGITS.slice(at, 1).to_i!
    return mine > bound if mine != bound
  end

  true
end

## The message of a float literal (its text) that rounds to an infinity in the type.
def float_outside(type: Type, text: String) -> String
  largest = "1.7976931348623157e308"
  if is?(type, "Float32")
    largest = "3.4028235e38"
  end

  "#{text} is past the largest #{tag(type)}, #{largest}, and would be an infinity"
end

## The narrow integer type of that name (a key of NARROW_INTS), or UInt64.
def narrow_int(name: String) -> Type = NARROW_TYPES[name]

## True for a name of a sized integer type: a key of NARROW_INTS, or UInt64.
def sized_name?(name: String) -> Bool = NARROW_INTS.has_key?(name) or name == "UInt64"

## The sized integer type of that name (sized_name?).
def sized_int(name: String) -> Type
  return Type.UInt64 if name == "UInt64"

  NARROW_TYPES[name]
end

## True for no type (Unknown).
def unknown?(type: Type) -> Bool = tag(type) == "Unknown"

## The element type of a List, Set, Result, Optional, Task, Channel, Address, Lazy or Codec; Unknown for any other
## type.
def item(type: Type) -> Type
  case type
    Type.Result(inner) -> inner
    Type.Optional(inner) -> inner
    Type.Task(inner) -> inner
    Type.Channel(inner) -> inner
    Type.Address(inner) -> inner
    Type.Lazy(inner) -> inner
    Type.Codec(inner) -> inner
    Type.List(inner) -> inner
    Type.Set(inner) -> inner
    _ -> Type.Unknown
  end
end

## The key type of a Map or an ATS; Unknown for any other type.
def key(type: Type) -> Type
  case type
    Type.Map(inner, _) -> inner
    Type.ATS(inner, _) -> inner
    _ -> Type.Unknown
  end
end

## The value type of a Map or an ATS; Unknown for any other type.
def value(type: Type) -> Type
  case type
    Type.Map(_, inner) -> inner
    Type.ATS(_, inner) -> inner
    _ -> Type.Unknown
  end
end

## The parameter types of an Fn; empty for any other type.
def params(type: Type) -> List[Type]
  case type
    Type.Fn(found, _) -> found
    _ -> []
  end
end

## The result type of an Fn; Unknown for any other type.
def result(type: Type) -> Type
  case type
    Type.Fn(_, last) -> last
    _ -> Type.Unknown
  end
end

## The name of an Opaque, Var, Struct or Enum type; "" for any other type.
def name(type: Type) -> String
  case type
    Type.Opaque(found) -> found
    Type.Var(found) -> found
    Type.Struct(found, _) -> found
    Type.Enum(found, _) -> found
    _ -> ""
  end
end

## The type arguments of a Struct or Enum type; empty for any other type.
def args(type: Type) -> List[Type]
  case type
    Type.Struct(_, list) -> list
    Type.Enum(_, list) -> list
    _ -> []
  end
end

## Structural equality: compiler/ does not use == on enums until stage0 lowers it.
def same?(a: Type, b: Type) -> Bool
  return false if tag(a) != tag(b)

  case a
    Type.Opaque(found) -> found == name(b)
    Type.Var(found) -> found == name(b)
    Type.Struct(found, list) -> found == name(b) and same_all?(list, args(b))
    Type.Enum(found, list) -> found == name(b) and same_all?(list, args(b))
    Type.Map(key_type, value_type) -> same?(key_type, key(b)) and same?(value_type, value(b))
    Type.ATS(key_type, value_type) -> same?(key_type, key(b)) and same?(value_type, value(b))
    Type.Fn(list, last) -> same_all?(list, params(b)) and same?(last, result(b))
    Type.Result(inner) -> same?(inner, item(b))
    Type.Optional(inner) -> same?(inner, item(b))
    Type.Task(inner) -> same?(inner, item(b))
    Type.Channel(inner) -> same?(inner, item(b))
    Type.Address(inner) -> same?(inner, item(b))
    Type.Lazy(inner) -> same?(inner, item(b))
    Type.Codec(inner) -> same?(inner, item(b))
    Type.List(inner) -> same?(inner, item(b))
    Type.Set(inner) -> same?(inner, item(b))
    _ -> true
  end
end

## True when the two lists have the same length and equal types in order.
def same_all?(a: List[Type], b: List[Type]) -> Bool
  return false if a.size != b.size

  index = 0
  while index < a.size
    return false if !same?(a[index], b[index])

    index += 1
  end

  true
end

## Result[type], or Unknown when there is no type: the expected type of the operand of try.
def result_of(type: Type) -> Type
  return type if unknown?(type)

  Type.Result(type)
end

## Task[type], or Unknown when there is no type.
def task_of(type: Type) -> Type
  return type if unknown?(type)

  Type.Task(type)
end

## List[type], or Unknown when there is no type.
def list_of(type: Type) -> Type
  return type if unknown?(type)

  Type.List(type)
end

## The type itself when it is a List, else Unknown: the expected type that a list operation passes on.
def only_list(type: Type) -> Type
  return type if is?(type, "List")

  Type.Unknown
end

## The type itself when it is a Map, else Unknown.
def only_map(type: Type) -> Type
  return type if is?(type, "Map")

  Type.Unknown
end

## The type itself when it is a Set, else Unknown.
def only_set(type: Type) -> Type
  return type if is?(type, "Set")

  Type.Unknown
end

## The item of a Result, else Unknown: the expected type of the value inside a Result.
def only_result_item(type: Type) -> Type
  return item(type) if is?(type, "Result")

  Type.Unknown
end

## The item of an Optional, else Unknown: the expected type of the value inside some(...).
def only_optional_item(type: Type) -> Type
  return item(type) if is?(type, "Optional")

  Type.Unknown
end

## The name as the user wrote it: the linker gives a name from another file the prefix "@N::" to keep it unique, and
## messages leave it out.
def display_name(name: String) -> String
  return name if not name.start_with?("@")
  return "Ref" if name == REF_TYPE

  digits_end = 1
  while digits_end < name.length and digit?(name.at(digits_end))
    digits_end += 1
  end

  if digits_end > 1 and name.length >= digits_end + 2 and name.slice(digits_end, 2) == "::"
    return name.slice(digits_end + 2, name.length - digits_end - 2)
  end

  name
end

## The name of a struct, enum or other named type as a message prints it: display_name, and a builtin type that a std/
## module re-exports by its written name (HttpWire.Request is HTTP.Request).
def written_type(name: String) -> String = REEXPORTED_TYPES.get(name, display_name(name))

## The name that the std/ module `key` (`std/http.agc`) writes its types through (`HTTP`), "" for a module that
## re-exports no builtin type. A module's own types are written so too, `HTTP.App`.
def reexporting_stem(key: String) -> String
  for original in REEXPORTED_TYPES.keys
    stem = REEXPORTED_TYPES[original].split(".")[0]
    return stem if key == "std/#{stem.downcase}.agc"
  end

  ""
end

## Source text with each re-exported builtin type written by its written name: the default `HttpWire.ClientOptions()`
## of a std/ signature prints as `HTTP.ClientOptions()`. Only a whole name outside a string literal is a type: the
## default `"HttpWire.Server"` stays as written.
def written_types_in(text: String) -> String = replaced_names(text, REEXPORTED_TYPES, true)

## The text with each whole name that `names` has (not the start of a longer name, nor the end of `My.HttpWire.Server`)
## written as `names` maps it. A string literal stays as written when `keep_strings` says so.
def replaced_names(text: String, names: Map[String, String], keep_strings: Bool) -> String
  pieces: List[String] = []
  quoted = false
  at = 0
  while at < text.length
    character = text.at(at)
    if keep_strings and quoted and character == "\\" and at + 1 < text.length
      pieces = pieces.push(text.slice(at, 2))
      at += 2
      next
    elsif keep_strings and (quoted or character == "\"")
      quoted = quoted != (character == "\"")
    else
      name = name_at(text, at, names)
      if name != ""
        pieces = pieces.push(names[name])
        at += name.length
        next
      end
    end

    pieces = pieces.push(character)
    at += 1
  end

  pieces.join("")
end

## The type as the messages print it: Int, List[String], Map[String, Int], Fn[Int, Void], Point, Option[Int],
## HTTP.Request.
def to_text(type: Type) -> String = to_text_as(type, {})

## The type as `to_text` prints it, but a re-exported builtin type keeps its builtin name (HttpWire.Request): the text
## that runtime data holds (Type.members, a codec), which a printed value shows.
def builtin_text(type: Type) -> String = to_text_as(type, KEEP_BUILTIN)

## The type as `to_text` prints it, except that a struct or an enum of another file is written through the import alias
## of the file that asks: `written` maps the "@N::" prefix of a linked name to that alias, so `@1::User` prints as
## `Models.User` (`agentica type-at`). A linked name that `written` maps itself (a type that a file re-exports) is
## written through that alias too. A prefix it does not map prints as the bare name. A re-exported builtin type
## (REEXPORTED_TYPES) prints as the text `written` maps its builtin name to (`H.Request` for import H from "std/http",
## `Request` for import {Request}), else by its written name.
def to_text_as(type: Type, written: Map[String, String]) -> String
  case type
    Type.Int -> "Int"
    Type.Float -> "Float"
    Type.Int8 -> "Int8"
    Type.Int16 -> "Int16"
    Type.Int32 -> "Int32"
    Type.UInt8 -> "UInt8"
    Type.UInt16 -> "UInt16"
    Type.UInt32 -> "UInt32"
    Type.UInt64 -> "UInt64"
    Type.Float32 -> "Float32"
    Type.Bool -> "Bool"
    Type.String -> "String"
    Type.Nil -> "Nil"
    Type.Void -> "Void"
    Type.Json -> "JSON.Value"
    Type.Range -> "Range"
    Type.Bytes -> "Bytes"
    Type.Unknown -> "?"
    Type.Opaque(name) -> written_name(name, written)
    Type.Var(name) -> name
    Type.Struct(name, args) -> generic_text(name, args, written)
    Type.Enum(name, args) -> generic_text(name, args, written)
    Type.Result(item) -> "Result[#{to_text_as(item, written)}]"
    Type.Optional(item) -> "Optional[#{to_text_as(item, written)}]"
    Type.Task(item) -> "Task[#{to_text_as(item, written)}]"
    Type.Channel(item) -> "Channel[#{to_text_as(item, written)}]"
    Type.Address(item) -> "Address[#{to_text_as(item, written)}]"
    Type.Lazy(item) -> "Lazy[#{to_text_as(item, written)}]"
    Type.Codec(item) -> "Codec[#{to_text_as(item, written)}]"
    Type.List(item) -> "List[#{to_text_as(item, written)}]"
    Type.Set(item) -> "Set[#{to_text_as(item, written)}]"
    Type.Map(key, value) -> "Map[#{to_text_as(key, written)}, #{to_text_as(value, written)}]"
    Type.ATS(key, value) -> "ATS[#{to_text_as(key, written)}, #{to_text_as(value, written)}]"
    Type.Fn(params, result) -> "Fn[#{list_text_as(params.concat([result]), written)}]"
  end
end

## The type with its variant written out, for tests: Struct(Header), Struct(Box, [Int]), Enum(Await, [Var(T)]),
## Fn([Int], Void). Unlike to_text, two variants never print the same.
def debug_text(type: Type) -> String
  case type
    Type.Opaque(name) -> "Opaque(#{name})"
    Type.Var(name) -> "Var(#{name})"
    Type.Struct(name, args) -> struct_debug(name, args)
    Type.Enum(name, args) -> "Enum(#{name}, [#{debug_list(args)}])"
    Type.Result(item) -> "Result(#{debug_text(item)})"
    Type.Optional(item) -> "Optional(#{debug_text(item)})"
    Type.Task(item) -> "Task(#{debug_text(item)})"
    Type.Channel(item) -> "Channel(#{debug_text(item)})"
    Type.Address(item) -> "Address(#{debug_text(item)})"
    Type.Lazy(item) -> "Lazy(#{debug_text(item)})"
    Type.Codec(item) -> "Codec(#{debug_text(item)})"
    Type.List(item) -> "List(#{debug_text(item)})"
    Type.Set(item) -> "Set(#{debug_text(item)})"
    Type.Map(key, value) -> "Map(#{debug_text(key)}, #{debug_text(value)})"
    Type.ATS(key, value) -> "ATS(#{debug_text(key)}, #{debug_text(value)})"
    Type.Fn(params, result) -> "Fn([#{debug_list(params)}], #{debug_text(result)})"
    _ -> to_text(type)
  end
end

## The types joined by ", ".
def list_text(types: List[Type]) -> String = types.map(&to_text).join(", ")

## The types joined by ", ", as debug_text writes each.
def debug_list(types: List[Type]) -> String = types.map(&debug_text).join(", ")

## The type with its linked names and type arguments, as the VM names a JSON type: List[app.Person], app.Box[Int].
def json_name(type: Type) -> String
  case type
    Type.List(item) -> "List[#{json_name(item)}]"
    Type.Map(key, value) -> "Map[#{json_name(key)}, #{json_name(value)}]"
    Type.Optional(item) -> "Optional[#{json_name(item)}]"
    Type.Struct(name, list) -> with_arguments(name, list)
    Type.Enum(name, list) -> with_arguments(name, list)
    _ -> tag(type)
  end
end

private

# A `written` map whose key "" (no linked name or prefix is empty) asks to_text_as for the builtin names.
KEEP_BUILTIN: Map[String, String] = {"": ""}

# The characters that may continue a name: a type name next to one of them is part of a longer name.
NAME_CHARACTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_?!"

def with_arguments(name: String, list: List[Type]) -> String
  return name if list.size == 0

  "#{name}[#{list.map(&json_name).join(", ")}]"
end

# A struct with no type arguments prints as Struct(Name), a generic one as Struct(Name, [Int]).
def struct_debug(name: String, args: List[Type]) -> String
  return "Struct(#{name})" if args.size == 0

  "Struct(#{name}, [#{debug_list(args)}])"
end

def generic_text(name: String, args: List[Type], written: Map[String, String]) -> String
  return written_name(name, written) if args.size == 0

  "#{written_name(name, written)}[#{list_text_as(args, written)}]"
end

def list_text_as(types: List[Type], written: Map[String, String]) -> String
  texts = types.map do |type: Type| to_text_as(type, written) end
  texts.join(", ")
end

# The name with the alias that `written` has for the linked name or, failing that, for its prefix.
def written_name(name: String, written: Map[String, String]) -> String
  bare = display_name(name)
  return reexported_name(name, written) if bare == name
  return bare if written.size == 0

  alias = written.get(name, written.get(name.slice(0, name.length - bare.length), ""))
  return bare if alias == ""

  "#{alias}.#{bare}"
end

# A name with no "@N::" prefix: a re-exported builtin type as `written` writes it, or by its written name; any other
# name as it is.
def reexported_name(name: String, written: Map[String, String]) -> String
  return name if !REEXPORTED_TYPES.has_key?(name) or written.has_key?("")

  written.get(name, REEXPORTED_TYPES[name])
end

# The name of `names` written as a whole name at `at` of `text` (not the start of a longer name, nor the end of
# `My.HttpWire.Server`), or "".
def name_at(text: String, at: Int, names: Map[String, String]) -> String
  return "" if at > 0 and (NAME_CHARACTERS.include?(text.at(at - 1)) or text.at(at - 1) == ".")

  for name in names.keys
    stop = at + name.length
    next if stop > text.length or text.slice(at, name.length) != name
    return name if stop == text.length or !NAME_CHARACTERS.include?(text.at(stop))
  end

  ""
end

def digit?(character: String) -> Bool
  code = character.code
  code >= 48 and code <= 57
end

# The digits before the point of a decimal text, without its sign or leading zeros: "-1.25e2" gives "125".
def integer_digits(text: String) -> String
  unsigned = text
  if text.start_with?("-")
    unsigned = text.slice(1, text.size - 1)
  end

  parts = unsigned.replace("E", "e").split("e")
  exponent = 0
  if parts.size > 1
    exponent = parts[1].replace("+", "").to_i!
  end

  halves = parts[0].split(".")
  digits = halves[0]
  if halves.size > 1
    digits += halves[1]
  end

  point = halves[0].size + exponent
  whole = "0"
  if point >= digits.size
    whole = digits + "0" * (point - digits.size)
  elsif point > 0
    whole = digits.slice(0, point)
  end

  while whole.size > 1 and whole.start_with?("0")
    whole = whole.slice(1, whole.size - 1)
  end

  whole
end

# True when the digits of TEXT times 10^q are X > 0 (M * 2^k, M odd) exactly, compared in 62 bits; false past them.
def exact_text?(x: Float, text: String) -> Bool
  bits = Float.to_bits(x).to_i!
  m = bits.bit_and(0xFFFFFFFFFFFFF).bit_or(0x10000000000000)
  k = bits.shift_right(52) - 1075
  while m % 2 == 0
    m = m / 2
    k += 1
  end

  unsigned = text
  if text.start_with?("-")
    unsigned = text.slice(1, text.size - 1)
  end

  parts = unsigned.replace("E", "e").split("e")
  q = 0
  if parts.size > 1
    q = parts[1].replace("+", "").to_i!
  end

  number = parts[0].split(".")
  digits = number[0]
  if number.size > 1
    digits = digits + number[1]
    q -= number[1].size
  end

  digits = digits.replace("_", "")
  while digits.size > 1 and digits.start_with?("0")
    digits = digits.slice(1, digits.size - 1)
  end

  while digits.size > 1 and digits.end_with?("0")
    digits = digits.slice(0, digits.size - 1)
    q += 1
  end

  return false if digits.size > 18

  left = scaled(digits.to_i!, q, 0 - k)
  right = scaled(m, 0 - q, k)
  left >= 0 and left == right
end

# n times 10^tens (tens >= 0) times 2^twos (twos >= 0), or -1 past 62 bits. A negative count leaves its factor out.
def scaled(n: Int, tens: Int, twos: Int) -> Int
  value = n
  for _ in 0...tens
    return -1 if value > 0x3FFFFFFFFFFFFFFF / 10

    value *= 10
  end

  for _ in 0...twos
    return -1 if value > 0x3FFFFFFFFFFFFFFF / 2

    value *= 2
  end

  value
end

## The types the checker works with, as an enum.

## The builtin types that a std/ module re-exports, by their builtin name, with the name a program writes: the alias
## that the module's docs import it as (STD_ONLY_IMPORTS of the catalog), then the member. Messages, `help`, `doc`,
## the queries and a printed value (vm/text.c) show the written name.
export REEXPORTED_TYPES: Map[String, String] = {
  "HttpWire.Client": "HTTP.Client",
  "HttpWire.ClientOptions": "HTTP.ClientOptions",
  "HttpWire.Header": "HTTP.Header",
  "HttpWire.Request": "HTTP.Request",
  "HttpWire.Response": "HTTP.Response",
  "HttpWire.Server": "HTTP.Server",
  "HttpWire.ServerOptions": "HTTP.ServerOptions",
  "LogRegistry.Event": "Logger.Event",
  "LogRegistry.Level": "Logger.Level",
}

# A `written` map whose key "" (no linked name or prefix is empty) asks to_text_as for the builtin names.
KEEP_BUILTIN: Map[String, String] = {"": ""}

# The characters that may continue a name: a type name next to one of them is part of a longer name.
NAME_CHARACTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_?!"

## A resolved type. Opaque holds the name of a handle or other builtin type with no structure (Socket, Process,
## TestCase, C.Pointer), or the linked name of a resource of an extern block. Struct and Enum hold the linked name and
## carry their type arguments (none for a plain struct or enum). Var is a type variable of a builtin signature, a
## generic struct or a generic enum. Fn lists the parameters, then the result. Codec is Codec[T], the codec of a
## struct or enum (T.codec). Optional is Optional[T], a value that is some(x) or none. Unknown is no type: the expected
## type when none is known (Unknown), and the type of a literal the lexer could not classify.
export enum Type
  Int
  Float
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

## The variant of a type as a word: "Int", "List", "Struct", ... Every test of a type's shape is a comparison with this
## word.
export def tag(type: Type) -> String
  case type
    Type.Int -> "Int"
    Type.Float -> "Float"
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
export def is?(type: Type, word: String) -> Bool = tag(type) == word

## True for no type (Unknown).
export def unknown?(type: Type) -> Bool = tag(type) == "Unknown"

## The element type of a List, Set, Result, Optional, Task, Channel, Address, Lazy or Codec; Unknown for any other
## type.
export def item(type: Type) -> Type
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
export def key(type: Type) -> Type
  case type
    Type.Map(inner, _) -> inner
    Type.ATS(inner, _) -> inner
    _ -> Type.Unknown
  end
end

## The value type of a Map or an ATS; Unknown for any other type.
export def value(type: Type) -> Type
  case type
    Type.Map(_, inner) -> inner
    Type.ATS(_, inner) -> inner
    _ -> Type.Unknown
  end
end

## The parameter types of an Fn; empty for any other type.
export def params(type: Type) -> List[Type]
  case type
    Type.Fn(found, _) -> found
    _ -> []
  end
end

## The result type of an Fn; Unknown for any other type.
export def result(type: Type) -> Type
  case type
    Type.Fn(_, last) -> last
    _ -> Type.Unknown
  end
end

## The name of an Opaque, Var, Struct or Enum type; "" for any other type.
export def name(type: Type) -> String
  case type
    Type.Opaque(found) -> found
    Type.Var(found) -> found
    Type.Struct(found, _) -> found
    Type.Enum(found, _) -> found
    _ -> ""
  end
end

## The type arguments of a Struct or Enum type; empty for any other type.
export def args(type: Type) -> List[Type]
  case type
    Type.Struct(_, list) -> list
    Type.Enum(_, list) -> list
    _ -> []
  end
end

## Structural equality: compiler/ does not use == on enums until stage0 lowers it.
export def same?(a: Type, b: Type) -> Bool
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
export def same_all?(a: List[Type], b: List[Type]) -> Bool
  return false if a.size != b.size

  index = 0
  while index < a.size
    return false if !same?(a[index], b[index])

    index += 1
  end

  true
end

## Result[type], or Unknown when there is no type: the expected type of the operand of try.
export def result_of(type: Type) -> Type
  return type if unknown?(type)

  Type.Result(type)
end

## Task[type], or Unknown when there is no type.
export def task_of(type: Type) -> Type
  return type if unknown?(type)

  Type.Task(type)
end

## List[type], or Unknown when there is no type.
export def list_of(type: Type) -> Type
  return type if unknown?(type)

  Type.List(type)
end

## The type itself when it is a List, else Unknown: the expected type that a list operation passes on.
export def only_list(type: Type) -> Type
  return type if is?(type, "List")

  Type.Unknown
end

## The type itself when it is a Map, else Unknown.
export def only_map(type: Type) -> Type
  return type if is?(type, "Map")

  Type.Unknown
end

## The type itself when it is a Set, else Unknown.
export def only_set(type: Type) -> Type
  return type if is?(type, "Set")

  Type.Unknown
end

## The item of a Result, else Unknown: the expected type of the value inside a Result.
export def only_result_item(type: Type) -> Type
  return item(type) if is?(type, "Result")

  Type.Unknown
end

## The item of an Optional, else Unknown: the expected type of the value inside some(...).
export def only_optional_item(type: Type) -> Type
  return item(type) if is?(type, "Optional")

  Type.Unknown
end

## The name as the user wrote it: the linker gives a name from another file the prefix "@N::" to keep it unique, and
## messages leave it out.
export def display_name(name: String) -> String
  return name if not name.start_with?("@")

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
export def written_type(name: String) -> String = REEXPORTED_TYPES.get(name, display_name(name))

## Source text with each re-exported builtin type written by its written name: the default `HttpWire.ClientOptions()`
## of a std/ signature prints as `HTTP.ClientOptions()`. Only a whole name outside a string literal is a type: the
## default `"HttpWire.Client"` stays as written.
export def written_types_in(text: String) -> String
  pieces: List[String] = []
  quoted = false
  at = 0
  while at < text.length
    character = text.at(at)
    if quoted and character == "\\" and at + 1 < text.length
      pieces = pieces.push(text.slice(at, 2))
      at += 2
      next
    elsif quoted or character == "\""
      quoted = quoted != (character == "\"")
    else
      name = type_name_at(text, at)
      if name != ""
        pieces = pieces.push(REEXPORTED_TYPES[name])
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
export def to_text(type: Type) -> String = to_text_as(type, {})

## The type as `to_text` prints it, but a re-exported builtin type keeps its builtin name (HttpWire.Request): the text
## that runtime data holds (Type.members, a codec), which a printed value shows.
export def builtin_text(type: Type) -> String = to_text_as(type, KEEP_BUILTIN)

## The type as `to_text` prints it, except that a struct or an enum of another file is written through the import alias
## of the file that asks: `written` maps the "@N::" prefix of a linked name to that alias, so `@1::User` prints as
## `Models.User` (`agentica type-at`). A linked name that `written` maps itself (a type that a file re-exports) is
## written through that alias too. A prefix it does not map prints as the bare name. A re-exported builtin type
## (REEXPORTED_TYPES) prints as the text `written` maps its builtin name to (`H.Request` for import H from "std/http",
## `Request` for import {Request}), else by its written name.
export def to_text_as(type: Type, written: Map[String, String]) -> String
  case type
    Type.Int -> "Int"
    Type.Float -> "Float"
    Type.Bool -> "Bool"
    Type.String -> "String"
    Type.Nil -> "Nil"
    Type.Void -> "Void"
    Type.Json -> "Json"
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
export def debug_text(type: Type) -> String
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
export def list_text(types: List[Type]) -> String = types.map(&to_text).join(", ")

## The types joined by ", ", as debug_text writes each.
export def debug_list(types: List[Type]) -> String = types.map(&debug_text).join(", ")

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

# The re-exported builtin type written as a whole name at `at` of `text` (not the start of `HttpWire.ClientOptions`
# for HttpWire.Client, nor the end of `My.HttpWire.Client`), or "".
def type_name_at(text: String, at: Int) -> String
  return "" if at > 0 and (NAME_CHARACTERS.include?(text.at(at - 1)) or text.at(at - 1) == ".")

  for name in REEXPORTED_TYPES.keys
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

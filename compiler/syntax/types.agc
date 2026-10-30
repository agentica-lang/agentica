## The types the checker works with, as an enum.

## A resolved type. Opaque holds the name of a handle or other builtin type with no structure (Socket, Process,
## TestCase, C.Pointer), or the linked name of a resource of an extern block. Struct and Enum hold the linked name and
## carry their type arguments (none for a plain struct or enum). Var is a type variable of a builtin signature, a
## generic struct or a generic enum. Fn lists the parameters, then the result. Codec is JSON.Codec[T], the JSON codec
## of a struct (JSON.codec). Optional is Optional[T], a value that is some(x) or none. Unknown is no type: the expected
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
    Type.Int -> return "Int"
    Type.Float -> return "Float"
    Type.Bool -> return "Bool"
    Type.String -> return "String"
    Type.Nil -> return "Nil"
    Type.Void -> return "Void"
    Type.Json -> return "Json"
    Type.Range -> return "Range"
    Type.Bytes -> return "Bytes"
    Type.Unknown -> return "Unknown"
    Type.Opaque(name) -> return "Opaque"
    Type.Result(item) -> return "Result"
    Type.Optional(item) -> return "Optional"
    Type.Task(item) -> return "Task"
    Type.Channel(item) -> return "Channel"
    Type.Lazy(item) -> return "Lazy"
    Type.Codec(item) -> return "Codec"
    Type.List(item) -> return "List"
    Type.Set(item) -> return "Set"
    Type.Map(key, value) -> return "Map"
    Type.ATS(key, value) -> return "ATS"
    Type.Fn(params, result) -> return "Fn"
    Type.Struct(name, args) -> return "Struct"
    Type.Enum(name, args) -> return "Enum"
    Type.Var(name) -> return "Var"
  end
end

## True when the type is that variant: is?(type, "List").
export def is?(type: Type, word: String) -> Bool
  return tag(type) == word
end

## True for no type (Unknown).
export def unknown?(type: Type) -> Bool
  return tag(type) == "Unknown"
end

## The element type of a List, Set, Result, Optional, Task, Channel, Lazy or Codec; Unknown for any other type.
export def item(type: Type) -> Type
  case type
    Type.Result(inner) -> return inner
    Type.Optional(inner) -> return inner
    Type.Task(inner) -> return inner
    Type.Channel(inner) -> return inner
    Type.Lazy(inner) -> return inner
    Type.Codec(inner) -> return inner
    Type.List(inner) -> return inner
    Type.Set(inner) -> return inner
    _ -> return Type.Unknown
  end
end

## The key type of a Map or an ATS; Unknown for any other type.
export def key(type: Type) -> Type
  case type
    Type.Map(inner, value) -> return inner
    Type.ATS(inner, value) -> return inner
    _ -> return Type.Unknown
  end
end

## The value type of a Map or an ATS; Unknown for any other type.
export def value(type: Type) -> Type
  case type
    Type.Map(key, inner) -> return inner
    Type.ATS(key, inner) -> return inner
    _ -> return Type.Unknown
  end
end

## The parameter types of an Fn; empty for any other type.
export def params(type: Type) -> List[Type]
  case type
    Type.Fn(found, result) -> return found
    _ -> return []
  end
end

## The result type of an Fn; Unknown for any other type.
export def result(type: Type) -> Type
  case type
    Type.Fn(found, last) -> return last
    _ -> return Type.Unknown
  end
end

## The name of an Opaque, Var, Struct or Enum type; "" for any other type.
export def name(type: Type) -> String
  case type
    Type.Opaque(found) -> return found
    Type.Var(found) -> return found
    Type.Struct(found, list) -> return found
    Type.Enum(found, args) -> return found
    _ -> return ""
  end
end

## The type arguments of a Struct or Enum type; empty for any other type.
export def args(type: Type) -> List[Type]
  case type
    Type.Struct(found, list) -> return list
    Type.Enum(found, list) -> return list
    _ -> return []
  end
end

## Structural equality, since an enum cannot be compared with ==.
export def same?(a: Type, b: Type) -> Bool
  if tag(a) != tag(b)
    return false
  end

  case a
    Type.Opaque(found) -> return found == name(b)
    Type.Var(found) -> return found == name(b)
    Type.Struct(found, list) -> return found == name(b) and same_all?(list, args(b))
    Type.Enum(found, list) -> return found == name(b) and same_all?(list, args(b))
    Type.Map(key_type, value_type) -> return same?(key_type, key(b)) and same?(value_type, value(b))
    Type.ATS(key_type, value_type) -> return same?(key_type, key(b)) and same?(value_type, value(b))
    Type.Fn(list, last) -> return same_all?(list, params(b)) and same?(last, result(b))
    Type.Result(inner) -> return same?(inner, item(b))
    Type.Optional(inner) -> return same?(inner, item(b))
    Type.Task(inner) -> return same?(inner, item(b))
    Type.Channel(inner) -> return same?(inner, item(b))
    Type.Lazy(inner) -> return same?(inner, item(b))
    Type.Codec(inner) -> return same?(inner, item(b))
    Type.List(inner) -> return same?(inner, item(b))
    Type.Set(inner) -> return same?(inner, item(b))
    _ -> return true
  end
end

## True when the two lists have the same length and equal types in order.
export def same_all?(a: List[Type], b: List[Type]) -> Bool
  if a.size != b.size
    return false
  end

  index = 0
  while index < a.size
    if !same?(a[index], b[index])
      return false
    end

    index += 1
  end

  return true
end

## Result[type], or Unknown when there is no type: the expected type of the operand of try.
export def result_of(type: Type) -> Type
  if unknown?(type)
    return type
  end

  return Type.Result(type)
end

## Task[type], or Unknown when there is no type.
export def task_of(type: Type) -> Type
  if unknown?(type)
    return type
  end

  return Type.Task(type)
end

## List[type], or Unknown when there is no type.
export def list_of(type: Type) -> Type
  if unknown?(type)
    return type
  end

  return Type.List(type)
end

## The type itself when it is a List, else Unknown: the expected type that a list operation passes on.
export def only_list(type: Type) -> Type
  if is?(type, "List")
    return type
  end

  return Type.Unknown
end

## The type itself when it is a Map, else Unknown.
export def only_map(type: Type) -> Type
  if is?(type, "Map")
    return type
  end

  return Type.Unknown
end

## The type itself when it is a Set, else Unknown.
export def only_set(type: Type) -> Type
  if is?(type, "Set")
    return type
  end

  return Type.Unknown
end

## The item of a Result, else Unknown: the expected type of the value inside a Result.
export def only_result_item(type: Type) -> Type
  if is?(type, "Result")
    return item(type)
  end

  return Type.Unknown
end

## The item of an Optional, else Unknown: the expected type of the value inside some(...).
export def only_optional_item(type: Type) -> Type
  if is?(type, "Optional")
    return item(type)
  end

  return Type.Unknown
end

## The name as the user wrote it: the linker gives a name from another file the prefix "@N::" to keep it unique, and
## messages leave it out.
export def display_name(name: String) -> String
  if not name.starts_with?("@")
    return name
  end

  digits_end = 1
  while digits_end < name.length and digit?(name.at(digits_end))
    digits_end += 1
  end

  if digits_end > 1 and name.length >= digits_end + 2 and name.slice(digits_end, 2) == "::"
    return name.slice(digits_end + 2, name.length - digits_end - 2)
  end

  return name
end

## The type as the messages print it: Int, List[String], Map[String, Int], Fn[Int, Void], Point, Option[Int].
export def to_text(type: Type) -> String
  return to_text_as(type, {})
end

## The type as `to_text` prints it, except that a struct or an enum of another file is written through the import alias
## of the file that asks: `written` maps the "@N::" prefix of a linked name to that alias, so `@1::User` prints as
## `Models.User` (`agentica type-at`). A linked name that `written` maps itself (a type that a file re-exports) is
## written through that alias too. A prefix it does not map prints as the bare name.
export def to_text_as(type: Type, written: Map[String, String]) -> String
  case type
    Type.Int -> return "Int"
    Type.Float -> return "Float"
    Type.Bool -> return "Bool"
    Type.String -> return "String"
    Type.Nil -> return "Nil"
    Type.Void -> return "Void"
    Type.Json -> return "Json"
    Type.Range -> return "Range"
    Type.Bytes -> return "Bytes"
    Type.Unknown -> return "?"
    Type.Opaque(name) -> return written_name(name, written)
    Type.Var(name) -> return name
    Type.Struct(name, args) -> return generic_text(name, args, written)
    Type.Enum(name, args) -> return generic_text(name, args, written)
    Type.Result(item) -> return "Result[#{to_text_as(item, written)}]"
    Type.Optional(item) -> return "Optional[#{to_text_as(item, written)}]"
    Type.Task(item) -> return "Task[#{to_text_as(item, written)}]"
    Type.Channel(item) -> return "Channel[#{to_text_as(item, written)}]"
    Type.Lazy(item) -> return "Lazy[#{to_text_as(item, written)}]"
    Type.Codec(item) -> return "JSON.Codec[#{to_text_as(item, written)}]"
    Type.List(item) -> return "List[#{to_text_as(item, written)}]"
    Type.Set(item) -> return "Set[#{to_text_as(item, written)}]"
    Type.Map(key, value) -> return "Map[#{to_text_as(key, written)}, #{to_text_as(value, written)}]"
    Type.ATS(key, value) -> return "ATS[#{to_text_as(key, written)}, #{to_text_as(value, written)}]"
    Type.Fn(params, result) -> return "Fn[#{list_text_as(params.concat([result]), written)}]"
  end
end

## The type with its variant written out, for tests: Struct(Header), Struct(Box, [Int]), Enum(Await, [Var(T)]),
## Fn([Int], Void). Unlike to_text, two variants never print the same.
export def debug_text(type: Type) -> String
  case type
    Type.Opaque(name) -> return "Opaque(#{name})"
    Type.Var(name) -> return "Var(#{name})"
    Type.Struct(name, args) -> return struct_debug(name, args)
    Type.Enum(name, args) -> return "Enum(#{name}, [#{debug_list(args)}])"
    Type.Result(item) -> return "Result(#{debug_text(item)})"
    Type.Optional(item) -> return "Optional(#{debug_text(item)})"
    Type.Task(item) -> return "Task(#{debug_text(item)})"
    Type.Channel(item) -> return "Channel(#{debug_text(item)})"
    Type.Lazy(item) -> return "Lazy(#{debug_text(item)})"
    Type.Codec(item) -> return "Codec(#{debug_text(item)})"
    Type.List(item) -> return "List(#{debug_text(item)})"
    Type.Set(item) -> return "Set(#{debug_text(item)})"
    Type.Map(key, value) -> return "Map(#{debug_text(key)}, #{debug_text(value)})"
    Type.ATS(key, value) -> return "ATS(#{debug_text(key)}, #{debug_text(value)})"
    Type.Fn(params, result) -> return "Fn([#{debug_list(params)}], #{debug_text(result)})"
    _ -> return to_text(type)
  end
end

## The types joined by ", ".
export def list_text(types: List[Type]) -> String
  return types.map do |type: Type| to_text(type) end.join(", ")
end

# A struct with no type arguments prints as Struct(Name), a generic one as Struct(Name, [Int]).
def struct_debug(name: String, args: List[Type]) -> String
  if args.size == 0
    return "Struct(#{name})"
  end

  return "Struct(#{name}, [#{debug_list(args)}])"
end

def debug_list(types: List[Type]) -> String
  return types.map do |type: Type| debug_text(type) end.join(", ")
end

def generic_text(name: String, args: List[Type], written: Map[String, String]) -> String
  if args.size == 0
    return written_name(name, written)
  end

  return "#{written_name(name, written)}[#{list_text_as(args, written)}]"
end

def list_text_as(types: List[Type], written: Map[String, String]) -> String
  return types.map do |type: Type| to_text_as(type, written) end.join(", ")
end

# The name with the alias that `written` has for the linked name or, failing that, for its prefix.
def written_name(name: String, written: Map[String, String]) -> String
  bare = display_name(name)
  if written.size == 0 or bare == name
    return bare
  end

  alias = written.get(name, written.get(name.slice(0, name.length - bare.length), ""))
  if alias == ""
    return bare
  end

  return "#{alias}.#{bare}"
end

def digit?(character: String) -> Bool
  code = character.code
  return code >= 48 and code <= 57
end

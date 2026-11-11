## A type as a line of text and back, for the type of a module constant that the cache of checked modules keeps
## (check_cache.agc). A struct, enum or resource type names the module that declares it by the key of its file and not
## by the "@N::" prefix of this walk, which depends on where the file sits in it, so an entry made under one root is
## read under another. The text has no space or line feed, and a corrupt text is an error, never a halt: the depth is
## limited, every length is looked at before a slice is taken, and the whole text must be used.

import T from "../syntax/types"

# A type nests at most this deep in the text; a constant type is far shallower, and a deeper text is not one.
MAX_DEPTH = 48

# The longest number the text may hold: a length or a count.
MAX_DIGITS = 9

# The letters of the types with no parts, and of the types with one or two.
SIMPLE = {
  "i": T.Type.Int,
  "f": T.Type.Float,
  "b": T.Type.Bool,
  "s": T.Type.String,
  "n": T.Type.Nil,
  "v": T.Type.Void,
  "j": T.Type.Json,
  "r": T.Type.Range,
  "y": T.Type.Bytes,
  "u": T.Type.Unknown,
}

# What a reader gives: the type and the index after its text.
struct Read
  type: T.Type
  next: Int
end

# A number and the index after its colon.
struct Counted
  value: Int
  next: Int
end

# What read_list gives: the types and the index after them.
struct Types
  types: List[T.Type]
  next: Int
end

# A name and the index after it.
struct Named
  name: String
  next: Int
end

## The text of `type`. `keys` maps the prefix of each module of the walk ("@3::") to the key of its file. A name with a
## prefix that `keys` lacks is an error.
export def encode(type: T.Type, keys: Map[String, String]) -> Result[String] = written(type, keys, 0)

## The type that `text` holds. `prefixes` maps the key of each file of the walk to its prefix. A text that is not one
## whole type, or that names a file the walk lacks, is an error.
export def decode(text: String, prefixes: Map[String, String]) -> Result[T.Type]
  found = try read_type(text, 0, 0, prefixes)
  return error("the type has text after it") if found.next != text.length

  ok(found.type)
end

def written(type: T.Type, keys: Map[String, String], depth: Int) -> Result[String]
  return error("the type is too deep") if depth > MAX_DEPTH

  case type
    T.Type.Int -> ok("i")
    T.Type.Float -> ok("f")
    T.Type.Bool -> ok("b")
    T.Type.String -> ok("s")
    T.Type.Nil -> ok("n")
    T.Type.Void -> ok("v")
    T.Type.Json -> ok("j")
    T.Type.Range -> ok("r")
    T.Type.Bytes -> ok("y")
    T.Type.Unknown -> ok("u")
    T.Type.Opaque(name) -> ok("O" + try name_text(name, keys))
    T.Type.Struct(name, args) -> struct_text(name, args, keys, depth)
    T.Type.Var(name) -> ok("X" + name_plain(name))
    T.Type.Result(item) -> ok("R" + try written(item, keys, depth + 1))
    T.Type.Optional(item) -> ok("P" + try written(item, keys, depth + 1))
    T.Type.Task(item) -> ok("K" + try written(item, keys, depth + 1))
    T.Type.Channel(item) -> ok("C" + try written(item, keys, depth + 1))
    T.Type.Address(item) -> ok("W" + try written(item, keys, depth + 1))
    T.Type.Lazy(item) -> ok("Z" + try written(item, keys, depth + 1))
    T.Type.Codec(item) -> ok("D" + try written(item, keys, depth + 1))
    T.Type.List(item) -> ok("L" + try written(item, keys, depth + 1))
    T.Type.Set(item) -> ok("S" + try written(item, keys, depth + 1))
    T.Type.Map(key, value) -> ok("M" + try written(key, keys, depth + 1) + try written(value, keys, depth + 1))
    T.Type.ATS(key, value) -> ok("A" + try written(key, keys, depth + 1) + try written(value, keys, depth + 1))
    T.Type.Fn(params, result) ->
      ok("F#{params.size}:" + try list_text(params, keys, depth) + try written(result, keys, depth + 1))
    T.Type.Enum(name, args) -> ok("E" + try name_text(name, keys) + "#{args.size}:" + try list_text(args, keys, depth))
  end
end

# `T<name>` for a plain struct, `G<name><count>:<types>` for one with type arguments.
def struct_text(name: String, args: List[T.Type], keys: Map[String, String], depth: Int) -> Result[String]
  return ok("T" + try name_text(name, keys)) if args.size == 0

  ok("G" + try name_text(name, keys) + "#{args.size}:" + try list_text(args, keys, depth))
end

def list_text(types: List[T.Type], keys: Map[String, String], depth: Int) -> Result[String]
  parts: List[String] = []
  for type in types
    parts = parts.push(try written(type, keys, depth + 1))
  end

  ok(parts.join(""))
end

# `<length>:<name>` for a name with no prefix, `@<length>:<key><length>:<local>` for "@N::local" with the key of the
# file that has the prefix "@N::".
def name_text(name: String, keys: Map[String, String]) -> Result[String]
  return ok(name_plain(name)) if !name.starts_with?("@")

  split = name.index_of("::")
  return error("the name has a prefix that does not end") if split.none?

  prefix = name.slice(0, split.unwrap! + 2)
  return error("the name belongs to a file that is not in the walk") if !keys.has_key?(prefix)

  local = name.slice(prefix.length, name.length - prefix.length)
  ok("@" + name_plain(keys[prefix]) + name_plain(local))
end

def name_plain(name: String) -> String = "#{name.length}:#{name}"

def read_type(text: String, at: Int, depth: Int, prefixes: Map[String, String]) -> Result[Read]
  return error("the type ends too soon or is too deep") if depth > MAX_DEPTH or at >= text.length

  letter = text.slice(at, 1)
  return ok(Read(type: SIMPLE[letter], next: at + 1)) if SIMPLE.has_key?(letter)

  after = at + 1
  if "RPKCWZDLS".contains?(letter)
    item = try read_type(text, after, depth + 1, prefixes)
    return ok(Read(type: around(letter, item.type), next: item.next))
  end

  case letter
    "O" ->
      named = try read_name(text, after, prefixes)
      ok(Read(type: T.Type.Opaque(named.name), next: named.next))
    "T" ->
      named = try read_name(text, after, prefixes)
      ok(Read(type: T.Type.Struct(named.name, []), next: named.next))
    "G" ->
      named = try read_name(text, after, prefixes)
      count = try read_count(text, named.next)
      args = try read_list(text, count, depth, prefixes)
      ok(Read(type: T.Type.Struct(named.name, args.types), next: args.next))
    "X" ->
      named = try read_plain(text, after)
      ok(Read(type: T.Type.Var(named.name), next: named.next))
    "M" ->
      key = try read_type(text, after, depth + 1, prefixes)
      value = try read_type(text, key.next, depth + 1, prefixes)
      ok(Read(type: T.Type.Map(key.type, value.type), next: value.next))
    "A" ->
      key = try read_type(text, after, depth + 1, prefixes)
      value = try read_type(text, key.next, depth + 1, prefixes)
      ok(Read(type: T.Type.ATS(key.type, value.type), next: value.next))
    "F" ->
      count = try read_count(text, after)
      params = try read_list(text, count, depth, prefixes)
      result = try read_type(text, params.next, depth + 1, prefixes)
      ok(Read(type: T.Type.Fn(params.types, result.type), next: result.next))
    "E" ->
      named = try read_name(text, after, prefixes)
      count = try read_count(text, named.next)
      args = try read_list(text, count, depth, prefixes)
      ok(Read(type: T.Type.Enum(named.name, args.types), next: args.next))
    _ -> error("the type has a letter that is not one")
  end
end

# The type with one part that `letter` stands for, around `item`.
def around(letter: String, item: T.Type) -> T.Type
  case letter
    "R" -> T.Type.Result(item)
    "P" -> T.Type.Optional(item)
    "K" -> T.Type.Task(item)
    "C" -> T.Type.Channel(item)
    "W" -> T.Type.Address(item)
    "Z" -> T.Type.Lazy(item)
    "D" -> T.Type.Codec(item)
    "L" -> T.Type.List(item)
    _ -> T.Type.Set(item)
  end
end

def read_list(text: String, count: Counted, depth: Int, prefixes: Map[String, String]) -> Result[Types]
  types: List[T.Type] = []
  at = count.next
  left = count.value
  while left > 0
    item = try read_type(text, at, depth + 1, prefixes)
    types = types.push(item.type)
    at = item.next
    left -= 1
  end

  ok(Types(types: types, next: at))
end

# The number at `at` and its colon, with at most MAX_DIGITS digits.
def read_count(text: String, at: Int) -> Result[Counted]
  stop = at
  while stop < text.length and "0123456789".contains?(text.slice(stop, 1))
    stop += 1
  end

  if stop == at or stop - at > MAX_DIGITS or stop >= text.length or text.slice(stop, 1) != ":"
    return error("the type has a number that is not one")
  end

  ok(Counted(value: text.slice(at, stop - at).to_i!(), next: stop + 1))
end

# A name written by name_plain: its length, a colon and the name.
def read_plain(text: String, at: Int) -> Result[Named]
  length = try read_count(text, at)
  return error("the type has a name that ends too soon") if length.next + length.value > text.length

  ok(Named(name: text.slice(length.next, length.value), next: length.next + length.value))
end

# A name written by name_text: plain, or "@" and the key of a file of the walk and the local name, which gets the
# prefix that file has in this walk.
def read_name(text: String, at: Int, prefixes: Map[String, String]) -> Result[Named]
  return error("the type ends too soon") if at >= text.length

  return read_plain(text, at) if text.slice(at, 1) != "@"

  key = try read_plain(text, at + 1)
  local = try read_plain(text, key.next)
  return error("the type names a file that is not in the walk") if !prefixes.has_key?(key.name)

  ok(Named(name: prefixes[key.name] + local.name, next: local.next))
end

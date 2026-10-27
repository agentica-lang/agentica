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
export def encode(type: T.Type, keys: Map[String, String]) -> Result[String]
  return written(type, keys, 0)
end

## The type that `text` holds. `prefixes` maps the key of each file of the walk to its prefix. A text that is not one
## whole type, or that names a file the walk lacks, is an error.
export def decode(text: String, prefixes: Map[String, String]) -> Result[T.Type]
  found = try read_type(text, 0, 0, prefixes)
  if found.next != text.length
    return error("the type has text after it")
  end

  return ok(found.type)
end

def written(type: T.Type, keys: Map[String, String], depth: Int) -> Result[String]
  if depth > MAX_DEPTH
    return error("the type is too deep")
  end

  case type
    T.Type.Int -> return ok("i")
    T.Type.Float -> return ok("f")
    T.Type.Bool -> return ok("b")
    T.Type.String -> return ok("s")
    T.Type.Nil -> return ok("n")
    T.Type.Void -> return ok("v")
    T.Type.Json -> return ok("j")
    T.Type.Range -> return ok("r")
    T.Type.Unknown -> return ok("u")
    T.Type.Opaque(name) -> return ok("O" + try name_text(name, keys))
    T.Type.Struct(name, args) -> return struct_text(name, args, keys, depth)
    T.Type.Var(name) -> return ok("X" + name_plain(name))
    T.Type.Result(item) -> return ok("R" + try written(item, keys, depth + 1))
    T.Type.Task(item) -> return ok("K" + try written(item, keys, depth + 1))
    T.Type.Channel(item) -> return ok("C" + try written(item, keys, depth + 1))
    T.Type.Lazy(item) -> return ok("Z" + try written(item, keys, depth + 1))
    T.Type.List(item) -> return ok("L" + try written(item, keys, depth + 1))
    T.Type.Set(item) -> return ok("S" + try written(item, keys, depth + 1))
    T.Type.Map(key, value) -> return ok("M" + try written(key, keys, depth + 1) + try written(value, keys, depth + 1))
    T.Type.ATS(key, value) -> return ok("A" + try written(key, keys, depth + 1) + try written(value, keys, depth + 1))
    T.Type.Fn(params, result) ->
      return ok("F#{params.size}:" + try list_text(params, keys, depth) + try written(result, keys, depth + 1))
    T.Type.Enum(name, args) ->
      return ok("E" + try name_text(name, keys) + "#{args.size}:" + try list_text(args, keys, depth))
  end
end

# `T<name>` for a plain struct, `G<name><count>:<types>` for one with type arguments.
def struct_text(name: String, args: List[T.Type], keys: Map[String, String], depth: Int) -> Result[String]
  if args.size == 0
    return ok("T" + try name_text(name, keys))
  end

  return ok("G" + try name_text(name, keys) + "#{args.size}:" + try list_text(args, keys, depth))
end

def list_text(types: List[T.Type], keys: Map[String, String], depth: Int) -> Result[String]
  parts: List[String] = []
  for type in types
    parts = parts.push(try written(type, keys, depth + 1))
  end

  return ok(parts.join(""))
end

# `<length>:<name>` for a name with no prefix, `@<length>:<key><length>:<local>` for "@N::local" with the key of the
# file that has the prefix "@N::".
def name_text(name: String, keys: Map[String, String]) -> Result[String]
  if !name.starts_with?("@")
    return ok(name_plain(name))
  end

  split = name.index_of("::")
  if !split.ok?
    return error("the name has a prefix that does not end")
  end

  prefix = name.slice(0, split.unwrap! + 2)
  if !keys.has_key?(prefix)
    return error("the name belongs to a file that is not in the walk")
  end

  local = name.slice(prefix.length, name.length - prefix.length)
  return ok("@" + name_plain(keys[prefix]) + name_plain(local))
end

def name_plain(name: String) -> String
  return "#{name.length}:#{name}"
end

def read_type(text: String, at: Int, depth: Int, prefixes: Map[String, String]) -> Result[Read]
  if depth > MAX_DEPTH or at >= text.length
    return error("the type ends too soon or is too deep")
  end

  letter = text.slice(at, 1)
  if SIMPLE.has_key?(letter)
    return ok(Read(type: SIMPLE[letter], next: at + 1))
  end

  after = at + 1
  if "RKCZLS".contains?(letter)
    item = try read_type(text, after, depth + 1, prefixes)
    return ok(Read(type: around(letter, item.type), next: item.next))
  end

  case letter
    "O" ->
      named = try read_name(text, after, prefixes)
      return ok(Read(type: T.Type.Opaque(named.name), next: named.next))
    "T" ->
      named = try read_name(text, after, prefixes)
      return ok(Read(type: T.Type.Struct(named.name, []), next: named.next))
    "G" ->
      named = try read_name(text, after, prefixes)
      count = try read_count(text, named.next)
      args = try read_list(text, count, depth, prefixes)
      return ok(Read(type: T.Type.Struct(named.name, args.types), next: args.next))
    "X" ->
      named = try read_plain(text, after)
      return ok(Read(type: T.Type.Var(named.name), next: named.next))
    "M" ->
      key = try read_type(text, after, depth + 1, prefixes)
      value = try read_type(text, key.next, depth + 1, prefixes)
      return ok(Read(type: T.Type.Map(key.type, value.type), next: value.next))
    "A" ->
      key = try read_type(text, after, depth + 1, prefixes)
      value = try read_type(text, key.next, depth + 1, prefixes)
      return ok(Read(type: T.Type.ATS(key.type, value.type), next: value.next))
    "F" ->
      count = try read_count(text, after)
      params = try read_list(text, count, depth, prefixes)
      result = try read_type(text, params.next, depth + 1, prefixes)
      return ok(Read(type: T.Type.Fn(params.types, result.type), next: result.next))
    "E" ->
      named = try read_name(text, after, prefixes)
      count = try read_count(text, named.next)
      args = try read_list(text, count, depth, prefixes)
      return ok(Read(type: T.Type.Enum(named.name, args.types), next: args.next))
    _ -> return error("the type has a letter that is not one")
  end
end

# The type with one part that `letter` stands for, around `item`.
def around(letter: String, item: T.Type) -> T.Type
  case letter
    "R" -> return T.Type.Result(item)
    "K" -> return T.Type.Task(item)
    "C" -> return T.Type.Channel(item)
    "Z" -> return T.Type.Lazy(item)
    "L" -> return T.Type.List(item)
    _ -> return T.Type.Set(item)
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

  return ok(Types(types: types, next: at))
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

  return ok(Counted(value: text.slice(at, stop - at).to_i!(), next: stop + 1))
end

# A name written by name_plain: its length, a colon and the name.
def read_plain(text: String, at: Int) -> Result[Named]
  length = try read_count(text, at)
  if length.next + length.value > text.length
    return error("the type has a name that ends too soon")
  end

  return ok(Named(name: text.slice(length.next, length.value), next: length.next + length.value))
end

# A name written by name_text: plain, or "@" and the key of a file of the walk and the local name, which gets the
# prefix that file has in this walk.
def read_name(text: String, at: Int, prefixes: Map[String, String]) -> Result[Named]
  if at >= text.length
    return error("the type ends too soon")
  end

  if text.slice(at, 1) != "@"
    return read_plain(text, at)
  end

  key = try read_plain(text, at + 1)
  local = try read_plain(text, key.next)
  if !prefixes.has_key?(key.name)
    return error("the type names a file that is not in the walk")
  end

  return ok(Named(name: prefixes[key.name] + local.name, next: local.next))
end

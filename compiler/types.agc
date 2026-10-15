## The types the checker works with: the lists headed by a name of src/checker.rkt ('Int, '(List T), '(Struct "Point")) as an enum.

## A resolved type. Opaque holds the name of a handle or other builtin type with no structure (Socket, Process, TestCase). Struct and Enum hold the linked name; Enum carries its type arguments (none for a plain enum). Var is a type variable of a builtin signature or a generic enum. Fn lists the parameters, then the result. Unknown is the type of a literal the lexer could not classify; the checker never produces it from valid source.
export enum Type
  Int
  Float
  Bool
  String
  Nil
  Void
  Json
  Range
  Unknown
  Opaque(String)
  Result(Type)
  Task(Type)
  Channel(Type)
  List(Type)
  Set(Type)
  Map(Type, Type)
  Fn(List[Type], Type)
  Struct(String)
  Enum(String, List[Type])
  Var(String)
end

## The name as the user wrote it: the linker gives a name from another file the prefix "@N::" to keep it unique, and messages leave it out.
export def display_name(name: String) -> String
  if not name.starts_with?("@")
    return name
  end
  digits_end = 1
  while digits_end < name.length and digit?(name.at(digits_end))
    digits_end += 1
  end
  if digits_end > 1 and name.slice(digits_end, 2) == "::"
    return name.slice(digits_end + 2, name.length - digits_end - 2)
  end
  return name
end

## The type as the messages print it: Int, List[String], Map[String, Int], Fn[Int, Void], Point, Option[Int].
export def to_text(type: Type) -> String
  case type
    Type.Int -> return "Int"
    Type.Float -> return "Float"
    Type.Bool -> return "Bool"
    Type.String -> return "String"
    Type.Nil -> return "Nil"
    Type.Void -> return "Void"
    Type.Json -> return "Json"
    Type.Range -> return "Range"
    Type.Unknown -> return "?"
    Type.Opaque(name) -> return name
    Type.Var(name) -> return name
    Type.Struct(name) -> return display_name(name)
    Type.Enum(name, args) -> return enum_text(name, args)
    Type.Result(item) -> return "Result[" + to_text(item) + "]"
    Type.Task(item) -> return "Task[" + to_text(item) + "]"
    Type.Channel(item) -> return "Channel[" + to_text(item) + "]"
    Type.List(item) -> return "List[" + to_text(item) + "]"
    Type.Set(item) -> return "Set[" + to_text(item) + "]"
    Type.Map(key, value) -> return "Map[" + to_text(key) + ", " + to_text(value) + "]"
    Type.Fn(params, result) -> return "Fn[" + list_text(params.concat([result])) + "]"
  end
end

## The types joined by ", ".
export def list_text(types: List[Type]) -> String
  return types.map do |type: Type| to_text(type) end.join(", ")
end

def enum_text(name: String, args: List[Type]) -> String
  if args.size == 0
    return display_name(name)
  end
  return display_name(name) + "[" + list_text(args) + "]"
end

def digit?(character: String) -> Bool
  code = character.code
  return code >= 48 and code <= 57
end

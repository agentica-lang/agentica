## The help texts of the checker: the tables of check_tables.agc loaded into Maps once, and the helps
## that depend only on types or names. A help is a String, and "" means there is none.

import Ast from "../syntax/ast"
import Model from "../catalog/builtin_model"
import Data from "check_tables"
import Suggest from "suggest"
import Types from "types"

## The tables of check_tables.agc, built once per run. A key is the receiver kind and the name, `String.size`.
export struct Tables
  modules: Map[String, String]
  aliases: Map[String, String]
  foreign_names: Map[String, String]
  foreign_methods: Map[String, List[String]]
  kind_methods: Map[String, String]
end

## The tables of this run.
export def tables() -> Tables
  return Tables(
    modules: Data.method_modules(),
    aliases: Data.method_aliases(),
    foreign_names: Data.foreign_names(),
    foreign_methods: Data.foreign_methods(),
    kind_methods: Data.foreign_kind_methods(),
  )
end

## The help of a type mismatch: how to convert the actual type into the expected one (conversion-help).
export def conversion(expected: Types.Type, actual: Types.Type) -> String
  if Types.is(actual, "Result") and Types.same(Types.item(actual), expected)
    return (
      "this is #{Types.to_text(actual)}; unwrap it with a ! form (#{unwrap_form(expected)}), " +
      "with Result.unwrap!(...), or with try inside a function that returns Result"
    )
  end
  return convert_help(expected, actual)
end

## The help for a name another language has but Agentica does not, or "".
export def foreign(tables: Tables, name: String) -> String
  found = tables.foreign_names.get(name)
  if found.ok?
    return found.unwrap!
  end
  return ""
end

## The "did you mean" help for the closest of the candidates and the shared names, or "".
export def near(name: String, candidates: List[String], shared: List[String]) -> String
  case Suggest.did_you_mean_among(name, candidates, shared)
    Ast.Optional.Present(text) -> return text
    Ast.Optional.Absent -> return ""
  end
end

## The field names alone, as "fields: a, b".
export def field_list(fields: List[Model.Named]) -> String
  names = fields.map do |field: Model.Named| field.name end
  return "fields: #{names.join(", ")}"
end

## The help of a missing or unknown field: a guess if one is close, then the field names.
export def field_help(name: String, fields: List[Model.Named]) -> String
  names = fields.map do |field: Model.Named| field.name end
  all = field_list(fields)
  guess = near(name, names, [])
  if guess == ""
    return all
  end
  return "#{guess} #{all}"
end

# What a failed unwrap suggests, by the type that was expected.
def unwrap_form(expected: Types.Type) -> String
  if Types.is(expected, "Int")
    return "s.to_i!"
  elsif Types.is(expected, "Float")
    return "s.to_f!"
  elsif Types.is(expected, "String")
    return "gets!"
  end
  return "such as s.to_i!"
end

def convert_help(expected: Types.Type, actual: Types.Type) -> String
  if Types.is(expected, "String") and Types.is(actual, "Int")
    return "convert it with String.from_int(...)"
  elsif Types.is(expected, "String") and Types.is(actual, "Float")
    return "convert it with String.from_float(...)"
  elsif Types.is(expected, "Int") and Types.is(actual, "String")
    return "convert it with String.to_int!(...)"
  elsif Types.is(expected, "Float") and Types.is(actual, "String")
    return "convert it with String.to_float!(...)"
  elsif Types.is(expected, "Float") and Types.is(actual, "Int")
    return "convert it with Float.from_int(...)"
  elsif Types.is(expected, "Result") and !Types.is(actual, "Result")
    if Types.is(Types.item(expected), "Void")
      return "give a Result with ok() or error(\"message\")"
    end
    return "give a Result with ok(...) or error(\"message\")"
  elsif Types.is(expected, "Int") and Types.is(actual, "Float")
    return "convert it with Float.to_int!(...), which truncates"
  end
  return ""
end

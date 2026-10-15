## The builtin catalog (src/builtins.rkt, src/builtin-types.rkt): every builtin function with its signature, the builtin records and enums, and the lookups the linker and the checker make. One Catalog is built per run from the generated rows of builtins_data.agc; every lookup is a Map or Set access.

import "builtin_model" as Model
import "builtins_data" as Data
import "types" as Types

## A module only std/ may call: the std module that wraps it and the alias its help shows.
export struct StdOnly
  std_path: String
  alias: String
end

## The lookup tables of the catalog. entries holds the first form of each builtin (its alternatives are inside it). public_names are the names a program may call, sorted: all but those of the std-only modules. bare_names are the builtins written as a plain name (puts, ok). reserved is the set of type names no declaration may take.
export struct Catalog
  entries: Map[String, Model.Builtin]
  public_names: List[String]
  bare_names: Set[String]
  records: Map[String, List[Model.Named]]
  enums: Map[String, Model.EnumDef]
  opaque: Set[String]
  handles: Set[String]
  reserved: Set[String]
  std_only: Map[String, StdOnly]
end

## The catalog of this run.
export def catalog() -> Catalog
  entries = entry_table()
  std_only = std_only_table()
  names = entries.keys
  return Catalog(
    entries: entries,
    public_names: public_names(names, std_only),
    bare_names: bare_names(names),
    records: record_table(),
    enums: enum_table(),
    opaque: Set.new(Data.opaque_types()),
    handles: Set.new(Data.handle_types()),
    reserved: Set.new(Data.reserved_type_names()),
    std_only: std_only
  )
end

## The builtin of that name, or an error when there is none (builtin-ref without an arity).
export def lookup(catalog: Catalog, name: String) -> Result[Model.Builtin]
  return catalog.entries.get(name)
end

## The form of a builtin that takes that many arguments, or an error when none does.
export def form_for(entry: Model.Builtin, arity: Int) -> Result[Model.Builtin]
  if entry.parameters.size == arity
    return ok(entry)
  end
  for alternative in entry.alternatives
    if alternative.parameters.size == arity
      return ok(alternative)
    end
  end
  return error("no form with that arity")
end

## The form of the builtin name that takes that many arguments (builtin-ref with an arity).
export def ref(catalog: Catalog, name: String, arity: Int) -> Result[Model.Builtin]
  entry = try lookup(catalog, name)
  return form_for(entry, arity)
end

## True for a name inside a std-only module, such as HttpWire.client.
export def std_only_name?(catalog: Catalog, name: String) -> Bool
  return catalog.std_only.has_key?(module_of(name))
end

## The signature of every form of a builtin, one per line: name(param: Type, ...) -> Result.
export def signature(entry: Model.Builtin) -> String
  forms = [entry].concat(entry.alternatives)
  return forms.map do |form: Model.Builtin| form_signature(form) end.join("\n")
end

## The signature of one form.
export def form_signature(form: Model.Builtin) -> String
  parameters = form.parameters.map do |parameter: Model.Named| parameter.name + ": " + Types.to_text(parameter.type) end
  return form.name + "(" + parameters.join(", ") + ") -> " + Types.to_text(form.result)
end

# The part of a builtin name before its first dot: the module.
def module_of(name: String) -> String
  dot = name.index_of(".")
  if dot.ok?
    return name.slice(0, dot.unwrap!)
  end
  return ""
end

def entry_table() -> Map[String, Model.Builtin]
  found: Map[String, Model.Builtin] = {}
  for row in Data.builtin_rows()
    found = found.put(row.name, row)
  end
  return found
end

def record_table() -> Map[String, List[Model.Named]]
  found: Map[String, List[Model.Named]] = {}
  for record in Data.records()
    found = found.put(record.name, record.fields)
  end
  return found
end

def enum_table() -> Map[String, Model.EnumDef]
  found: Map[String, Model.EnumDef] = {}
  for definition in Data.enums()
    found = found.put(definition.name, definition)
  end
  return found
end

def std_only_table() -> Map[String, StdOnly]
  found: Map[String, StdOnly] = {}
  imports = Data.std_only_imports()
  for name in imports.keys
    found = found.put(name, StdOnly(std_path: imports[name][0], alias: imports[name][1]))
  end
  return found
end

# Map.keys is in insertion order and the rows are sorted by name, so the lists stay sorted.
def public_names(names: List[String], std_only: Map[String, StdOnly]) -> List[String]
  return names.filter do |name: String| !std_only.has_key?(module_of(name)) end
end

def bare_names(names: List[String]) -> Set[String]
  return Set.new(names.filter do |name: String| !name.contains?(".") end)
end

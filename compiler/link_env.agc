## What the linker reads from outside the program being linked: the environment variables that place pkg/ libraries, the std/ sources folder, and the fixed name tables.

import "module_names" as Tables

## The environment variables the pkg/ search reads (src/modules.rkt, library-roots). An unset variable is "".
export struct Env
  agentica_path: String
  xdg_data_home: String
  home: String
end

## The inputs of one link: where the std/ sources are (a stdlib/ folder), the environment, and the name tables as sets.
export struct Settings
  stdlib: String
  env: Env
  reserved: Set[String]
  bare_builtins: Set[String]
  builtin_enums: Set[String]
  std_only: Map[String, List[String]]
end

## The environment of this process.
export def process_env() -> Env
  return Env(agentica_path: variable("AGENTICA_PATH"), xdg_data_home: variable("XDG_DATA_HOME"), home: variable("HOME"))
end

## Settings for a stdlib/ folder and an environment.
export def settings(stdlib: String, env: Env) -> Settings
  return Settings(stdlib: stdlib, env: env, reserved: Set.new(Tables.reserved_type_names()), bare_builtins: Set.new(Tables.bare_builtin_names()), builtin_enums: Set.new(Tables.builtin_enum_names()), std_only: Tables.std_only_imports())
end

def variable(name: String) -> String
  value = System.env(name)
  if value.ok?
    return value.unwrap!
  end
  return ""
end

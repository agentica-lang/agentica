## What the linker reads from outside the program being linked: the environment variables that place pkg/ libraries,
## the std/ sources folder, and the builtin catalog with its name tables.

import Builtins from "builtins"

## The environment variables the pkg/ search reads (src/modules.rkt, library-roots). An unset variable is "".
export struct Env
  agentica_path: String
  xdg_data_home: String
  home: String
end

## The inputs of one link: where the std/ sources are (a stdlib/ folder), the environment, and the builtin catalog
## (reserved type names, bare builtins, builtin enums and std-only modules).
export struct Settings
  stdlib: String
  env: Env
  catalog: Builtins.Catalog
end

## The environment of this process.
export def process_env() -> Env
  return Env(
    agentica_path: variable("AGENTICA_PATH"),
    xdg_data_home: variable("XDG_DATA_HOME"),
    home: variable("HOME"),
  )
end

## Settings for a stdlib/ folder and an environment.
export def settings(stdlib: String, env: Env) -> Settings
  return Settings(stdlib: stdlib, env: env, catalog: Builtins.catalog())
end

## The deadline, in milliseconds, of every file system call of the linker.
export def io_timeout() -> Int
  return 10000
end

def variable(name: String) -> String
  value = System.env(name)
  if value.ok?
    return value.unwrap!
  end
  return ""
end

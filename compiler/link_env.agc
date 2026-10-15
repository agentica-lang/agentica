## What the front end reads from outside the program it compiles: the environment variables that place pkg/ libraries,
## where the std/ sources are, the Agentica version the .agcb header names, and the builtin catalog with its name
## tables.

import Builtins from "builtins"

## The environment variables the pkg/ search reads (src/modules.rkt, library-roots). An unset variable is "".
export struct Env
  agentica_path: String
  xdg_data_home: String
  home: String
end

## Where the std/ sources come from: the files of a stdlib/ folder (an ordinary run of the front end, with `--stdlib`),
## or the copy the binary carries, read with FrontEnd.std_source (docs/future/35-self-hosting.md, 35.3).
export enum StdProvider
  Folder(String)
  Embedded
end

## The inputs of one compile: where the std/ sources are, the environment, the Agentica version that the header of
## the .agcb file names (the writer's input; the linker and the checker do not read it), and the builtin catalog
## (reserved type names, bare builtins, builtin enums and std-only modules).
export struct Settings
  std: StdProvider
  env: Env
  version: String
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

## Settings for a stdlib/ folder and an environment. The version is "": a program that writes .agcb files sets it
## with `with(version: ...)`, and the writer refuses an empty one.
export def settings(stdlib: String, env: Env) -> Settings
  return Settings(std: StdProvider.Folder(stdlib), env: env, version: "", catalog: Builtins.catalog())
end

## Settings for the std/ sources of the binary (FrontEnd.std_source), with the version the headers name.
export def embedded_settings(env: Env, version: String) -> Settings
  return Settings(std: StdProvider.Embedded, env: env, version: version, catalog: Builtins.catalog())
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

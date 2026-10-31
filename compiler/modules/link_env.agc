## What the front end reads from outside the program it compiles: the environment variables that place pkg/ libraries
## and the package cache, where the std/ sources are, the Agentica version the .agcb header names, the path of the
## running binary, and the Workspace (workspace.agc) that reads files. Nothing here reads the machine: io/host.agc does
## and passes it in.

import Workspace from "workspace"

## The environment variables the pkg/ search and the package cache read, and the system: whether the host is Windows,
## and `os`, the name System.os gives (it picks the native library of a package). An unset variable is "".
## `local_app_data` is the user data folder of Windows, where XDG_DATA_HOME, XDG_CACHE_HOME and HOME are not read.
## `windows` is `os == "windows"`; whoever builds an Env sets both to agree.
export struct Env
  agentica_path: String
  xdg_data_home: String
  xdg_cache_home: String
  home: String
  local_app_data: String
  windows: Bool
  os: String
end

## Where the std/ sources come from: the files of a stdlib/ folder (an ordinary run of the front end, with `--stdlib`),
## or the copy the binary carries, read with FrontEnd.std_source (docs/future/35-self-hosting.md, 35.3).
export enum StdProvider
  Folder(String)
  Embedded
end

## The inputs of one compile: where the std/ sources are, whether this binary carries compiled BDD programs, the
## environment, the workspace that reads files, the Agentica version that the header of the .agcb file names (the
## writer's input; the linker and the checker do not read it), the path of the `agentica` binary that runs the front
## end ("" when the front end is run as an ordinary program with `agentica run`; a command that starts the binary
## again, as `test` does, takes it from here).
export struct Settings
  std: StdProvider
  embedded_bdd: Bool
  env: Env
  workspace: Workspace.Workspace
  version: String
  self_path: String
end

## Settings for a stdlib/ folder and an environment. The version is "": a program that writes .agcb files sets it
## with `with(version: ...)`, and the writer refuses an empty one.
export def settings(workspace: Workspace.Workspace, stdlib: String, env: Env) -> Settings
  return Settings(
    std: StdProvider.Folder(stdlib),
    embedded_bdd: false,
    env: env,
    workspace: workspace,
    version: "",
    self_path: "",
  )
end

## Settings for the std/ sources of the binary (FrontEnd.std_source), with the version the headers name and whether
## it carries the compiled BDD programs.
export def embedded_settings(workspace: Workspace.Workspace, env: Env, version: String, embedded_bdd: Bool) -> Settings
  return Settings(
    std: StdProvider.Embedded,
    embedded_bdd: embedded_bdd,
    env: env,
    workspace: workspace,
    version: version,
    self_path: "",
  )
end

## The port of the front end to the outside world: the few things the core stages (syntax, modules, check, catalog,
## lower, bytecode, diagnostics) need from the machine, as a record of function values. There are no interfaces: the
## core calls `workspace.read_text.call(path)`, and io/host.agc builds the record whose functions touch the disk. A
## test can build another one over an in-memory tree. Only io/ (and the driving adapters app/ and bdd/) call File,
## Dir, Path, System, Process or FrontEnd; tests/test_style_core_purity.py enforces it.
##
## The environment variables and the host are data, not functions: `Env` in link_env.agc holds them, read once by io/
## when the program starts and passed in with the settings.

import SourceFile from "../syntax/source_file"

## What a folder holds under one name, without following links: a regular file, a folder, a symbolic link, or
## anything else (a pipe, a socket, a device).
export enum EntryKind
  File
  Directory
  Link
  Other
end

## One name in a folder and what it is. The package hash (packages/package_hash.agc) lists folders with this.
export struct Entry
  name: String
  kind: EntryKind
end

## What the core asks of the machine. Each function takes a path as the front end got it and never raises: a failure
## is data (`Read.Unreadable`, a `Result` error, `false`). `list_folder` gives the entries of a folder in no
## particular order, and `read_bytes` the whole content of a file, for the hash of a package. A path given to the
## Workspace never ends with a separator, except a filesystem root.
export struct Workspace
  read_text: Fn[String, SourceFile.Read]
  file_exists: Fn[String, Bool]
  directory_exists: Fn[String, Bool]
  real_path: Fn[String, Result[String]]
  resolve_path: Fn[String, Result[String]]
  std_source: Fn[String, Result[String]]
  list_folder: Fn[String, Result[List[Entry]]]
  read_bytes: Fn[String, Result[List[Int]]]
end

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

## One downloaded native artifact the core asks the machine to verify from the cache alone: the cache root
## (PackageCache.root of the settings), the lock key of the package ("" for the project root), the library and
## the system, and the manifest row (the file and row key its failures point at, with the URL, SHA-256 and member).
## The machine never fetches: it answers the verified local path or a packed PKG- failure at file/key.
export struct NativeRequest
  cache_root: String
  package: String
  library: String
  system: String
  file: String
  key: String
  url: String
  sha256: String
  member: String
end

## The cache of checked modules (modules/check_cache.agc) as the core sees it. `on` says whether there is one; `read`
## gives the text of the entry kept for a module, by the key of its file (a path, or the `std/` name), and `write`
## replaces that entry and says whether it could. An entry is untrusted data: the core validates what it reads and
## treats anything it cannot use as a miss. The machine decides where entries live and whether it may use them
## (io/check_cache.agc).
export struct CheckCache
  on: Bool
  read: Fn[String, Result[String]]
  write: Fn[String, String, Bool]
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
  native_artifact: Fn[NativeRequest, Result[String]]
  check_cache: CheckCache
end

## The cache that holds nothing: the default of every workspace, so a stage that does not ask for the cache never sees
## one.
export def no_check_cache() -> CheckCache
  return CheckCache(on: false, read: &no_entry, write: &no_write)
end

def no_entry(key: String) -> Result[String]
  return error("there is no check cache")
end

def no_write(key: String, entry: String) -> Bool
  return false
end

## The adapter of the front end to this machine: the Workspace (modules/workspace.agc) whose functions read the disk
## and the std/ sources it is given, and the environment of the process. It is the only place that calls File, Path and
## System for the core stages; app/ and bdd/ are driving adapters and have their own I/O.

import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Workspace from "../modules/workspace"
import SourceReader from "source_reader"

# The deadline, in milliseconds, of a File.stat and of each call of a read.
STAT_TIMEOUT_MS = 10_000

CHUNK_BYTES = 262_144

## The workspace of this machine, with `std_source` as the reader of the std/ sources (`FrontEnd.std_source` in the
## front end, `Std.source` in a program that embeds the core as `std/internal/compiler`).
export def workspace_with(std_source: Fn[String, Result[String]]) -> Workspace.Workspace
  Workspace.Workspace(
    read_text: &SourceReader.read,
    file_exists: &file_exists,
    directory_exists: &directory_exists,
    real_path: &real_path,
    resolve_path: &resolve_path,
    std_source: std_source,
    list_folder: &list_folder,
    read_bytes: &read_bytes,
    read_prefix: &read_prefix,
    native_artifact: &no_native,
    native_build: &Workspace.no_build,
    check_cache: Workspace.no_check_cache(),
  )
end

## The workspace of this machine for a run with `--stdlib DIR` (the entry programs of the stages), which reads the std/
## sources from that folder and never asks the workspace for them.
export def workspace() -> Workspace.Workspace = workspace_with(&no_std_source)

## The environment of this process.
export def process_env() -> Env.Env
  os = System.os()
  Env.Env(
    agentica_path: variable("AGENTICA_PATH"),
    xdg_data_home: variable("XDG_DATA_HOME"),
    xdg_cache_home: variable("XDG_CACHE_HOME"),
    home: variable("HOME"),
    local_app_data: variable("LOCALAPPDATA"),
    windows: os == "windows",
    os: os,
  )
end

def no_std_source(name: String) -> Result[String] = error("this workspace carries no std sources")

def real_path(path: String) -> Result[String] = Path.real(path)

def resolve_path(path: String) -> Result[String] = Path.resolve(path)

def file_exists(path: String) -> Bool
  info = File.stat(path, STAT_TIMEOUT_MS)
  info.ok? and info.unwrap!.kind != "directory"
end

def directory_exists(path: String) -> Bool
  info = File.stat(path, STAT_TIMEOUT_MS)
  info.ok? and info.unwrap!.kind == "directory"
end

def list_folder(path: String) -> Result[List[Workspace.Entry]]
  names = Dir.list(path, STAT_TIMEOUT_MS)
  return error(names.message) if !names.ok?

  entries: List[Workspace.Entry] = []
  for name in names.unwrap!
    info = File.lstat(Paths.join(path, name), STAT_TIMEOUT_MS)
    return error(info.message) if !info.ok?

    entries = entries.push(Workspace.Entry(name: name, kind: entry_kind(info.unwrap!.kind)))
  end

  ok(entries)
end

def entry_kind(kind: String) -> Workspace.EntryKind
  case kind
    "directory" -> Workspace.EntryKind.Directory
    "file" -> Workspace.EntryKind.File
    "link" -> Workspace.EntryKind.Link
    _ -> Workspace.EntryKind.Other
  end
end

# The whole file, read in chunks of 256 KiB (File.read_bytes gives at most 1 MiB a call).
def read_bytes(path: String) -> Result[Bytes] = read_prefix(path, -1)

# At most the first `limit` bytes of the file (no limit when it is negative), read in chunks of 256 KiB.
def read_prefix(path: String, limit: Int) -> Result[Bytes]
  opened = File.open(path, "read", STAT_TIMEOUT_MS)
  return error(opened.message) if !opened.ok?

  handle = opened.unwrap!
  parts: List[Bytes] = []
  size = 0
  finished = false
  while !finished
    wanted = CHUNK_BYTES
    if limit >= 0 and limit - size < wanted
      wanted = limit - size
    end

    if wanted == 0
      finished = true
      next
    end

    got = File.read_bytes(handle, wanted, STAT_TIMEOUT_MS)
    if !got.ok?
      _ = File.close(handle, STAT_TIMEOUT_MS)
      return error(got.message)
    end

    finished = got.unwrap!.empty?
    size += got.unwrap!.size
    parts = parts.push(got.unwrap!)
  end

  _ = File.close(handle, STAT_TIMEOUT_MS)
  ok(Bytes.concat(parts))
end

# The verified local path of the downloaded member named by the request, from the cache alone and without
# any network use. The caller matched the manifest row against the lock; this only verifies the cache object.
def no_native(request: Workspace.NativeRequest) -> Result[String]
  error("native artifacts are not available in this workspace")
end

def variable(name: String) -> String
  value = System.env(name)
  return value.unwrap! if value.ok?

  ""
end

## The adapter of the front end to this machine: the Workspace (modules/workspace.agc) whose functions read the disk
## and the std/ sources it is given, and the environment of the process. It is the only place that calls File, Path and
## System for the core stages; app/ and bdd/ are driving adapters and have their own I/O.

import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Workspace from "../modules/workspace"
import SourceReader from "source_reader"

# The deadline, in milliseconds, of a File.stat and of each call of a read.
STAT_TIMEOUT_MS = 10000

CHUNK_BYTES = 262144

## The workspace of this machine, with `std_source` as the reader of the std/ sources (`FrontEnd.std_source` in the
## front end, `Std.source` in a program that embeds the core as `std/internal/compiler`).
export def workspace_with(std_source: Fn[String, Result[String]]) -> Workspace.Workspace
  return Workspace.Workspace(
    read_text: &SourceReader.read,
    file_exists: &file_exists,
    directory_exists: &directory_exists,
    real_path: &real_path,
    resolve_path: &resolve_path,
    std_source: std_source,
    list_folder: &list_folder,
    read_bytes: &read_bytes,
  )
end

## The workspace of this machine for a run with `--stdlib DIR` (the entry programs of the stages), which reads the std/
## sources from that folder and never asks the workspace for them.
export def workspace() -> Workspace.Workspace
  return workspace_with(&no_std_source)
end

## The environment of this process.
export def process_env() -> Env.Env
  return Env.Env(
    agentica_path: variable("AGENTICA_PATH"),
    xdg_data_home: variable("XDG_DATA_HOME"),
    xdg_cache_home: variable("XDG_CACHE_HOME"),
    home: variable("HOME"),
    local_app_data: variable("LOCALAPPDATA"),
    windows: System.os() == "windows",
  )
end

def no_std_source(name: String) -> Result[String]
  return error("this workspace carries no std sources")
end

def real_path(path: String) -> Result[String]
  return Path.real(path)
end

def resolve_path(path: String) -> Result[String]
  return Path.resolve(path)
end

def file_exists(path: String) -> Bool
  info = File.stat(path, STAT_TIMEOUT_MS)
  return info.ok? and info.unwrap!.kind != "directory"
end

def directory_exists(path: String) -> Bool
  info = File.stat(path, STAT_TIMEOUT_MS)
  return info.ok? and info.unwrap!.kind == "directory"
end

def list_folder(path: String) -> Result[List[Workspace.Entry]]
  names = Dir.list(path, STAT_TIMEOUT_MS)
  if !names.ok?
    return error(names.message)
  end
  entries: List[Workspace.Entry] = []
  for name in names.unwrap!
    info = File.lstat(Paths.join(path, name), STAT_TIMEOUT_MS)
    if !info.ok?
      return error(info.message)
    end
    entries = entries.push(Workspace.Entry(name: name, kind: entry_kind(info.unwrap!.kind)))
  end
  return ok(entries)
end

def entry_kind(kind: String) -> Workspace.EntryKind
  if kind == "directory"
    return Workspace.EntryKind.Directory
  elsif kind == "file"
    return Workspace.EntryKind.File
  elsif kind == "link"
    return Workspace.EntryKind.Link
  end
  return Workspace.EntryKind.Other
end

# The whole file, read in chunks of 256 KiB (File.read_bytes gives at most 1 MiB a call).
def read_bytes(path: String) -> Result[List[Int]]
  opened = File.open(path, "read", STAT_TIMEOUT_MS)
  if !opened.ok?
    return error(opened.message)
  end
  handle = opened.unwrap!
  data: List[Int] = []
  finished = false
  while !finished
    got = File.read_bytes(handle, CHUNK_BYTES, STAT_TIMEOUT_MS)
    if !got.ok?
      File.close(handle, STAT_TIMEOUT_MS)
      return error(got.message)
    end
    finished = got.unwrap!.size == 0
    data = data.concat(got.unwrap!)
  end
  File.close(handle, STAT_TIMEOUT_MS)
  return ok(data)
end

def variable(name: String) -> String
  value = System.env(name)
  if value.ok?
    return value.unwrap!
  end
  return ""
end

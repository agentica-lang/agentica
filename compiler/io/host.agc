## The adapter of the front end to this machine: the Workspace (modules/workspace.agc) whose functions read the disk
## and the binary, and the environment of the process. It is the only place that calls File, Path, System and
## FrontEnd for the core stages; app/ and bdd/ are driving adapters and have their own I/O.

import Env from "../modules/link_env"
import Workspace from "../modules/workspace"
import SourceReader from "source_reader"

# The deadline, in milliseconds, of a File.stat.
STAT_TIMEOUT_MS = 10000

## The workspace of this machine.
export def workspace() -> Workspace.Workspace
  return Workspace.Workspace(
    read_text: &SourceReader.read,
    file_exists: &file_exists,
    directory_exists: &directory_exists,
    real_path: &real_path,
    resolve_path: &resolve_path,
    std_source: &std_source,
  )
end

## The environment of this process.
export def process_env() -> Env.Env
  return Env.Env(
    agentica_path: variable("AGENTICA_PATH"),
    xdg_data_home: variable("XDG_DATA_HOME"),
    home: variable("HOME"),
    local_app_data: variable("LOCALAPPDATA"),
    windows: System.os() == "windows",
  )
end

def real_path(path: String) -> Result[String]
  return Path.real(path)
end

def resolve_path(path: String) -> Result[String]
  return Path.resolve(path)
end

def std_source(name: String) -> Result[String]
  return FrontEnd.std_source(name)
end

def file_exists(path: String) -> Bool
  info = File.stat(path, STAT_TIMEOUT_MS)
  return info.ok? and info.unwrap!.kind != "directory"
end

def directory_exists(path: String) -> Bool
  info = File.stat(path, STAT_TIMEOUT_MS)
  return info.ok? and info.unwrap!.kind == "directory"
end

def variable(name: String) -> String
  value = System.env(name)
  if value.ok?
    return value.unwrap!
  end
  return ""
end

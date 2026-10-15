## Finds the module an import names: a std/ module in the stdlib/ folder, a pkg/ library in the search roots, or a file next to the importing one. This is resolve-import of src/modules.rkt. A module is known by its key: the canonical path of a file, or std/NAME.agc for a standard module.

import Diag from "diagnostic"
import Paths from "import_path"
import Env from "link_env"
import Failure from "link_failure"

## True for the key of a standard module, which no canonical path can look like.
export def embedded?(key: String) -> Bool
  return !key.starts_with?("/")
end

## The file that holds a module, for reading: the file itself, or the file of a std/ module in the stdlib/ folder.
export def source_path(settings: Env.Settings, key: String) -> String
  if embedded?(key)
    return Paths.join(settings.stdlib, key.slice(4, key.length - 4))
  end
  return key
end

## The key of the module that the import path file (already ending in .agc) names, found from the module with key. root_dir is the folder of the root file, where agc_libs/ is searched first. A failure is CHECK-IMPORT-PATH or CHECK-IMPORT-IO at site.
export def resolve_import(settings: Env.Settings, root_dir: String, key: String, file: String, site: Failure.Site) -> Result[String]
  if file.starts_with?("std/")
    return standard(settings, file, site)
  elsif file.starts_with?("pkg/")
    return library(settings, root_dir, file, site)
  elsif embedded?(key)
    # A relative import of a standard module stays in std/.
    return resolve_import(settings, root_dir, key, key.slice(0, key.length - Paths.last_part(key).length) + file, site)
  end
  return relative(key, file, site)
end

def io_failure(site: Failure.Site, message: String) -> String
  return Failure.fail_at(site, "CHECK-IMPORT-IO", message, Diag.Help.NoHelp)
end

def file?(path: String) -> Bool
  info = File.stat(path, Env.io_timeout())
  return info.ok? and info.unwrap!.kind != "directory"
end

def directory?(path: String) -> Bool
  info = File.stat(path, Env.io_timeout())
  return info.ok? and info.unwrap!.kind == "directory"
end

# The registry of src/stdlib.rkt is the files of the stdlib/ folder (a test checks that they are the same list).
def standard(settings: Env.Settings, file: String, site: Failure.Site) -> Result[String]
  try Paths.validate_library_path(file, site)
  if !file?(source_path(settings, file))
    return error(io_failure(site, "unknown standard library module"))
  end
  return ok(file)
end

def library(settings: Env.Settings, root_dir: String, file: String, site: Failure.Site) -> Result[String]
  try Paths.validate_library_path(file, site)
  roots = try library_roots(settings, root_dir, site)
  rest = file.slice(4, file.length - 4)
  for root in roots
    candidate = Paths.join(root, rest)
    if file?(candidate)
      return contained(root, candidate, site)
    end
  end
  return error(io_failure(site, "cannot find library module"))
end

# The search roots of pkg/: agc_libs/ next to the root file, AGENTICA_PATH, the user data folder, then the system folders. Every AGENTICA_PATH entry must be absolute, whether or not it is used.
def library_roots(settings: Env.Settings, root_dir: String, site: Failure.Site) -> Result[List[String]]
  configured: List[String] = []
  for entry in settings.env.agentica_path.split(":")
    if entry == ""
      next
    end
    if !entry.starts_with?("/")
      return error(Failure.fail_at(site, "CHECK-IMPORT-PATH", "AGENTICA_PATH roots must be absolute", Diag.Help.NoHelp))
    end
    configured = configured.push(entry)
  end
  roots = [Paths.join(root_dir, "agc_libs")].concat(configured).concat(user_roots(settings.env))
  return ok(roots.concat(["/usr/local/share/agentica/lib", "/usr/share/agentica/lib"]))
end

# XDG_DATA_HOME when it is absolute, else ~/.local/share. An unset HOME leaves the user root out (Racket asks the system for the home folder there).
def user_roots(env: Env.Env) -> List[String]
  if env.xdg_data_home.starts_with?("/")
    return [Paths.join(env.xdg_data_home, "agentica/lib")]
  end
  if env.home == ""
    return []
  end
  return [Paths.join(env.home, ".local/share/agentica/lib")]
end

# Links are resolved before the check, so a link out of the root is refused.
def contained(root: String, candidate: String, site: Failure.Site) -> Result[String]
  base = Path.real(root)
  target = Path.real(candidate)
  if !base.ok? or !target.ok?
    return error(io_failure(site, "cannot resolve import"))
  end
  if !inside?(parts(base.unwrap!), parts(target.unwrap!))
    return error(Failure.fail_at(site, "CHECK-IMPORT-PATH", "library path escapes its root", Diag.Help.NoHelp))
  end
  return ok(target.unwrap!)
end

def parts(path: String) -> List[String]
  return path.split("/").filter do |part| part != "" end
end

def inside?(base: List[String], target: List[String]) -> Bool
  if target.size < base.size
    return false
  end
  for index in 0...base.size
    if base[index] != target[index]
      return false
    end
  end
  return true
end

# The file next to the importing one. Racket's normalize-path accepts a missing last part and refuses a missing folder (CHECK-IMPORT-IO "cannot resolve import"); a missing file is found by the read ("cannot read import"), which this reports at once.
def relative(key: String, file: String, site: Failure.Site) -> Result[String]
  if file.starts_with?("/") or file.contains?(String.from_code(0))
    return error(io_failure(site, "cannot resolve import"))
  end
  folder = Paths.directory_of(key)
  inner = Paths.directory_of(file)
  if inner != ""
    folder = Paths.join(folder, inner)
  end
  parent = Path.real(folder)
  if !parent.ok? or !directory?(parent.unwrap!)
    return error(io_failure(site, "cannot resolve import"))
  end
  target = Path.real(Paths.join(parent.unwrap!, Paths.last_part(file)))
  if !target.ok?
    return error(io_failure(site, "cannot read import"))
  end
  return ok(target.unwrap!)
end

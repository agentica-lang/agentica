## Finds the module an import names: a std/ module in the stdlib/ folder, a pkg/ library in the search roots, a module
## of a package in the cache (package_import.agc), or a file next to the importing one. A module is known by its key:
## the canonical path of a file, or std/NAME.agc for a standard module.

import Diag from "diagnostic"
import Probe from "file_probe"
import Paths from "import_path"
import Env from "link_env"
import Failure from "link_failure"
import Packages from "package_import"
import SourceFile from "source_file"
import {IO_TIMEOUT_MS} from "link_env"

## What a build gives the resolution besides the importing file: libs_dir, the folder whose agc_libs/ is searched first
## (the folder of the manifest when the project has one, else the folder of the root file), and the packages
## (package_import.agc).
export struct Build
  libs_dir: String
  scope: Packages.Scope
end

## The importing file: its key and the package it belongs to.
export struct Importer
  key: String
  origin: Packages.Origin
end

## The module an import names: its key, the package it belongs to, its stored name when it is not just the path from
## the root folder (a package file's is `key@version/path`), and the packages hashed so far.
export struct Resolution
  key: String
  origin: Packages.Origin
  name: String
  scope: Packages.Scope
end

## True for the key of a standard module, which no canonical path can look like.
export def embedded?(key: String) -> Bool
  return !Paths.rooted?(key)
end

## Reads the source of the module with this key: a file, or a std/ module from the provider of the settings (a
## stdlib/ folder, or the copy that the binary carries).
export def read_source(settings: Env.Settings, key: String) -> SourceFile.Read
  if !embedded?(key)
    return SourceFile.read(key, IO_TIMEOUT_MS)
  end
  case settings.std
    Env.StdProvider.Folder(folder) -> return SourceFile.read(Paths.join(folder, std_path(key)), IO_TIMEOUT_MS)
    Env.StdProvider.Embedded ->
      text = FrontEnd.std_source(std_path(key))
      if text.ok?
        return SourceFile.Read.Text(text.unwrap!)
      end
      return SourceFile.Read.Unreadable(text.message)
  end
end

## Finds the module that the import path file (already ending in .agc) names, from the importer. A failure is
## CHECK-IMPORT-PATH, CHECK-IMPORT-IO, CHECK-IMPORT-PACKAGE, CHECK-IMPORT-AMBIGUOUS or a PKG- failure at site.
export def resolve_import(
  settings: Env.Settings,
  build: Build,
  importer: Importer,
  file: String,
  site: Failure.Site,
) -> Result[Resolution]
  if file.starts_with?("std/")
    key = try standard(settings, file, site)
    return ok(plain(build, key))
  elsif file.starts_with?("pkg/")
    key = try library(settings, build.libs_dir, file, site)
    return ok(plain(build, key))
  elsif embedded?(importer.key)
    # A relative import of a standard module stays in std/.
    folder = importer.key.slice(0, importer.key.length - Paths.last_part(importer.key).length)
    return resolve_import(settings, build, importer, folder + file, site)
  end
  keys = Packages.allowed_keys(build.scope, importer.origin)
  if keys.size == 0
    return beside(build, importer, file, site)
  end
  case try Packages.match_import(keys, file, site)
    Packages.Match.Relative -> return beside(build, importer, file, site)
    Packages.Match.Package(key, rest) ->
      try Packages.check_ambiguity(Paths.directory_of(importer.key), key, file, site)
      located = try Packages.open_package(settings, build.scope, key, rest, site)
      scope = build.scope.with(verified: located.verified)
      return ok(Resolution(key: located.file, origin: located.origin, name: located.name, scope: scope))
  end
end

# A module of std/ or pkg/, which belongs to no package.
def plain(build: Build, key: String) -> Resolution
  return Resolution(key: key, origin: Packages.project_origin(), name: "", scope: build.scope)
end

# The file next to the importing one. A file of a package may not leave the package.
def beside(build: Build, importer: Importer, file: String, site: Failure.Site) -> Result[Resolution]
  name = ""
  if importer.origin.root != ""
    # The path written is checked before the file system is asked, so a ../ that leaves the package is
    # CHECK-IMPORT-PATH whether or not the file is there; the file found is checked too, since a link may lead out.
    written = Paths.folded(Paths.join(Paths.directory_of(importer.key), file))
    try Packages.stay_inside(importer.origin, written, site)
  end
  target = try relative(importer.key, file, site)
  if importer.origin.root != ""
    name = try Packages.stay_inside(importer.origin, target, site)
  end
  return ok(Resolution(key: target, origin: importer.origin, name: name, scope: build.scope))
end

# The path of the source of a std/ module under stdlib/: the key without its std/.
def std_path(key: String) -> String
  return key.slice(4, key.length - 4)
end

def io_failure(site: Failure.Site, message: String) -> String
  return Failure.fail_at(site, "CHECK-IMPORT-IO", message, Diag.Help.NoHelp)
end

# A std/ module exists when the provider has its source. The registry is stdlib/MODULES, which the
# binary embeds and which lists the files of the stdlib/ folder (a test checks that they are the same list).
def standard(settings: Env.Settings, file: String, site: Failure.Site) -> Result[String]
  try Paths.validate_library_path(file, site)
  # The files of std/prelude/ are the compiler prelude, which no program imports (prelude.agc).
  if file.starts_with?("std/prelude/") or !std_exists?(settings, file)
    return error(io_failure(site, "unknown standard library module"))
  end
  return ok(file)
end

def std_exists?(settings: Env.Settings, file: String) -> Bool
  case settings.std
    Env.StdProvider.Folder(folder) -> return Probe.file?(Paths.join(folder, std_path(file)))
    Env.StdProvider.Embedded -> return FrontEnd.std_source(std_path(file)).ok?
  end
end

def library(settings: Env.Settings, libs_dir: String, file: String, site: Failure.Site) -> Result[String]
  try Paths.validate_library_path(file, site)
  roots = try library_roots(settings, libs_dir, site)
  rest = file.slice(4, file.length - 4)
  for root in roots
    candidate = Paths.join(root, rest)
    if Probe.file?(candidate)
      return contained(root, candidate, site)
    end
  end
  return error(io_failure(site, "cannot find library module"))
end

# The search roots of pkg/: agc_libs/ next to the manifest, or to the root file when there is none, AGENTICA_PATH, the
# user data folder, then the system folders (none on Windows). Every AGENTICA_PATH entry must be absolute, whether or
# not it is used. The Windows rules of docs/grammar/05b-modules.md are all here: the ";" separator, drive and UNC
# roots, and %LOCALAPPDATA%.
def library_roots(settings: Env.Settings, libs_dir: String, site: Failure.Site) -> Result[List[String]]
  on_windows = Paths.windows?()
  separator = ":"
  if on_windows
    separator = ";"
  end
  configured: List[String] = []
  for entry in settings.env.agentica_path.split(separator)
    if entry == ""
      next
    end
    if !Paths.absolute?(entry, on_windows)
      return error(
        Failure.fail_at(site, "CHECK-IMPORT-PATH", "AGENTICA_PATH roots must be absolute", Diag.Help.NoHelp),
      )
    end
    configured = configured.push(entry)
  end
  roots = [Paths.join(libs_dir, "agc_libs")].concat(configured).concat(user_roots(settings.env, on_windows))
  if on_windows
    return ok(roots)
  end
  return ok(roots.concat(["/usr/local/share/agentica/lib", "/usr/share/agentica/lib"]))
end

# Elsewhere, XDG_DATA_HOME when it is absolute, else ~/.local/share; an unset HOME leaves the user root out (the
# system is not asked for the home folder). On Windows, %LOCALAPPDATA% when it is absolute, else no user root:
# XDG_DATA_HOME and HOME are not read there.
def user_roots(env: Env.Env, on_windows: Bool) -> List[String]
  if on_windows
    if Paths.absolute?(env.local_app_data, true)
      return [Paths.join(env.local_app_data, "agentica/lib")]
    end
    return []
  end
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
  if !Paths.inside?(base.unwrap!, target.unwrap!)
    return error(Failure.fail_at(site, "CHECK-IMPORT-PATH", "library path escapes its root", Diag.Help.NoHelp))
  end
  return ok(target.unwrap!)
end

# The file next to the importing one. A missing last part is accepted and a missing folder is refused
# (CHECK-IMPORT-IO "cannot resolve import"); a missing file is found by the read ("cannot read import"), which this
# reports at once.
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
  if !parent.ok? or !Probe.directory?(parent.unwrap!)
    return error(io_failure(site, "cannot resolve import"))
  end
  target = Path.real(Paths.join(parent.unwrap!, Paths.last_part(file)))
  if !target.ok?
    return error(io_failure(site, "cannot read import"))
  end
  return ok(target.unwrap!)
end

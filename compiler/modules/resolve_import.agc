## Finds the module an import names: a std/ module in the stdlib/ folder, a package of deps/ that the manifest
## declares as pkg/NAME/ (packages/package_import.agc), a pkg/ library in the search roots, or a file next to the
## importing one. A module is known by its key: the canonical path of a file, or std/NAME.agc for a standard module.

import Diag from "../diagnostics/diagnostic"
import Packages from "../packages/package_import"
import Source from "../syntax/source"
import SourceFile from "../syntax/source_file"
import Paths from "import_path"
import Env from "link_env"
import Failure from "link_failure"
import Workspace from "workspace"

# The std/ modules that only std/ may import, and the part of them that is the front end's own core (compiler/).
INTERNAL = "std/internal/"
INTERNAL_COMPILER = "std/internal/compiler/"

## What a build gives the resolution besides the importing file: libs_dir, the folder whose agc_libs/ is searched first
## (the folder of the manifest when the project has one, else the folder of the root file), and the packages
## (packages/package_import.agc).
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
## the root folder (a package file's is `pkg/name@version/path`), and the packages loaded so far.
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
  workspace = settings.workspace
  if !embedded?(key)
    return workspace.read_text.call(key)
  end

  case settings.std
    Env.StdProvider.Folder(folder) -> return workspace.read_text.call(std_file(folder, key))
    Env.StdProvider.Embedded ->
      text = workspace.std_source.call(std_path(key))
      if text.ok?
        return SourceFile.Read.Text(text.unwrap!)
      end

      return SourceFile.Read.Unreadable(text.message)
  end
end

## The folders that a `pkg/` import searches for a library, in order, for a build whose manifest (or root file) is in
## `libs_dir`: the bytecode cache lists them, to see a library appear in one. A relative AGENTICA_PATH entry is an
## error.
export def search_roots(settings: Env.Settings, libs_dir: String) -> Result[List[String]]
  here = Source.position(0, 1, 0)
  site = Failure.Site(file: libs_dir, span: Source.Span(start: here, stop: here))
  return library_roots(settings, libs_dir, site)
end

## Finds the module that the import path file (already ending in .agc) names, from the importer. A failure is
## CHECK-IMPORT-PATH, CHECK-IMPORT-IO, CHECK-IMPORT-PACKAGE or a PKG- failure at site.
export def resolve_import(
  settings: Env.Settings,
  build: Build,
  importer: Importer,
  file: String,
  site: Failure.Site,
) -> Result[Resolution]
  if file.starts_with?("std/")
    key = try standard_for(settings, file, site, embedded?(importer.key))
    return ok(plain(build, key))
  elsif file.starts_with?("pkg/")
    return pkg(settings, build, importer, file, site)
  elsif embedded?(importer.key)
    # A relative import of a standard module stays in std/, and may use ".." to go up inside it.
    folder = importer.key.slice(0, importer.key.length - Paths.last_part(importer.key).length)
    named = try Paths.inside_std(folder + file, site)
    return resolve_import(settings, build, importer, named, site)
  end

  return beside(settings.workspace, build, importer, file, site)
end

## The key of the std/ module that the import path `file` names, for a file that is not part of std/ (a program, or
## `agentica doc` and `outline`). A std/ module exists when the provider has its source. The registry is
## stdlib/MODULES, which the binary embeds and which lists the files of the stdlib/ folder (a test checks that they are
## the same list). The modules of std/internal/ are private to std/: this refuses them as it refuses a missing module.
export def standard(settings: Env.Settings, file: String, site: Failure.Site) -> Result[String]
  return standard_for(settings, file, site, false)
end

# `standard`, where `from_std` says the importing module is a std/ module, which may import std/internal/.
def standard_for(settings: Env.Settings, file: String, site: Failure.Site, from_std: Bool) -> Result[String]
  try Paths.validate_library_path(file, site)
  if file.starts_with?(INTERNAL) and !from_std
    return error(io_failure(site, "std/internal/ modules are private to the standard library"))
  end

  # The files of std/prelude/ are the compiler prelude, which no program imports (prelude_files.agc).
  if file.starts_with?("std/prelude/") or !std_exists?(settings, file)
    return error(io_failure(site, "unknown standard library module"))
  end

  return ok(file)
end

# The path of the source of a std/ module under stdlib/: the key without its std/.
def std_path(key: String) -> String
  return key.slice(4, key.length - 4)
end

# The file of the source of a std/ module in the folder of a run with `--stdlib DIR`. The core that std/analysis embeds
# as std/internal/compiler/X is the file compiler/X of the checkout, next to the stdlib/ folder.
def std_file(folder: String, key: String) -> String
  if key.starts_with?(INTERNAL_COMPILER)
    core = key.slice(INTERNAL_COMPILER.length, key.length - INTERNAL_COMPILER.length)
    return Paths.join(Paths.join(folder, "../compiler"), core)
  end

  return Paths.join(folder, std_path(key))
end

# A module of std/ or pkg/ libraries, which belongs to no package.
def plain(build: Build, key: String) -> Resolution
  return Resolution(key: key, origin: Packages.library_origin(), name: "", scope: build.scope)
end

# A pkg/ import: a package the importing manifest declares, which shadows the library roots for its name, else a
# library of the roots (for a file of the project).
def pkg(
  settings: Env.Settings,
  build: Build,
  importer: Importer,
  file: String,
  site: Failure.Site,
) -> Result[Resolution]
  try Paths.validate_library_path(file, site)
  case try Packages.match_import(build.scope, importer.origin, file, site)
    Packages.Match.Library ->
      key = try library(settings, build.libs_dir, file, site)
      return ok(plain(build, key))
    Packages.Match.Package(name, rest) ->
      located = try Packages.open_package(settings.workspace, build.scope, name, rest, site)
      scope = build.scope.with(opened: located.opened)
      return ok(Resolution(key: located.file, origin: located.origin, name: located.name, scope: scope))
  end
end

# The file next to the importing one. A file of a package may not leave the package.
def beside(
  workspace: Workspace.Workspace,
  build: Build,
  importer: Importer,
  file: String,
  site: Failure.Site,
) -> Result[Resolution]
  name = ""
  if importer.origin.root != ""
    # The path written is checked before the file system is asked, so a ../ that leaves the package is
    # CHECK-IMPORT-PATH whether or not the file is there; the file found is checked too, since a link may lead out.
    written = Paths.folded(Paths.join(Paths.directory_of(importer.key), file))
    try Packages.stay_inside(importer.origin, written, site)
  end

  target = try relative(workspace, importer.key, file, site)
  if importer.origin.root != ""
    name = try Packages.stay_inside(importer.origin, target, site)
  end

  origin = importer.origin
  if origin.root == ""
    origin = Packages.file_origin(workspace, build.scope, origin, target)
  end

  return ok(Resolution(key: target, origin: origin, name: name, scope: build.scope))
end

def io_failure(site: Failure.Site, message: String) -> String
  return Failure.fail_at(site, "CHECK-IMPORT-IO", message, Diag.Help.NoHelp)
end

def std_exists?(settings: Env.Settings, file: String) -> Bool
  case settings.std
    Env.StdProvider.Folder(folder) -> return settings.workspace.file_exists.call(std_file(folder, file))
    Env.StdProvider.Embedded -> return settings.workspace.std_source.call(std_path(file)).ok?
  end
end

def library(settings: Env.Settings, libs_dir: String, file: String, site: Failure.Site) -> Result[String]
  roots = try library_roots(settings, libs_dir, site)
  rest = file.slice(4, file.length - 4)
  for root in roots
    candidate = Paths.join(root, rest)
    if settings.workspace.file_exists.call(candidate)
      return contained(settings.workspace, root, candidate, site)
    end
  end

  return error(io_failure(site, "cannot find library module"))
end

# The search roots of pkg/: agc_libs/ next to the manifest, or to the root file when there is none, AGENTICA_PATH, the
# user data folder, then the system folders (none on Windows). Every AGENTICA_PATH entry must be absolute, whether or
# not it is used. The Windows rules of docs/grammar/05b-modules.md are all here: the ";" separator, drive and UNC
# roots, and %LOCALAPPDATA%.
def library_roots(settings: Env.Settings, libs_dir: String, site: Failure.Site) -> Result[List[String]]
  on_windows = settings.env.windows
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

  first = [Paths.join(libs_dir, "agc_libs")]
  roots = first.concat(configured).concat(user_roots(settings.env, on_windows))
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
def contained(workspace: Workspace.Workspace, root: String, candidate: String, site: Failure.Site) -> Result[String]
  base = workspace.real_path.call(root)
  target = workspace.real_path.call(candidate)
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
def relative(workspace: Workspace.Workspace, key: String, file: String, site: Failure.Site) -> Result[String]
  if file.starts_with?("/") or file.contains?(String.from_code(0))
    return error(io_failure(site, "cannot resolve import"))
  end

  folder = Paths.directory_of(key)
  inner = Paths.directory_of(file)
  if inner != ""
    folder = Paths.join(folder, inner)
  end

  parent = workspace.real_path.call(folder)
  if !parent.ok? or !workspace.directory_exists.call(parent.unwrap!)
    return error(io_failure(site, "cannot resolve import"))
  end

  target = workspace.real_path.call(Paths.join(parent.unwrap!, Paths.last_part(file)))
  if !target.ok?
    return error(io_failure(site, "cannot read import"))
  end

  return ok(target.unwrap!)
end

## Imports of packages (docs/grammar/05b-modules.md). `pkg/<name>/<module>` is a package import when
## <name> is declared by the manifest of the importing file: the manifest of the project for a file of the project, the
## manifest of the package for a file of a package. The files come from the vendored copy `agc_libs/<name>/` beside the
## manifest of the project when it is there (`agentica vendor`), else from the cache folder of the commit the lock
## names. The first time a build loads a package, the hash of its .agc files must be the hash in the lock; a vendored
## copy that differs is an error, never a fallback to the cache. Before any file is loaded, the manifests of the locked
## packages that are vendored or in the cache are checked against the lock (check_manifests). A name that the importing
## manifest does not declare is a library of the pkg/ roots (resolve_import.agc) for a file of the project; a file of a
## package may import only what its own manifest declares.

import Diag from "../diagnostics/diagnostic"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import GitSource from "git_source"
import Lock from "lock"
import Manifest from "manifest"
import PackageCache from "package_cache"
import PackageHash from "package_hash"
import Project from "project"

# The manifest of a package, in the folder that holds its files.
MANIFEST_FILE = "agentica.toml"

# The folder beside the manifest of the project that holds the vendored copies, one folder for each locked package.
VENDOR_FOLDER = "agc_libs"

## The package a file belongs to. package is its local name, root the real folder of its files in the cache and label
## `name@version`, which names each of its files in the program (`pkg/name@version/path`). All are "" for the files of
## the project.
export struct Origin
  package: String
  root: String
  label: String
end

## A package that the build has loaded and hashed: the same fields as its Origin, and the names its own manifest
## declares, which its files may import.
export struct Opened
  root: String
  label: String
  names: List[String]
end

## What a build knows when it resolves an import: the folder of the vendored copies ("" when the project has no
## manifest), the names the project declares, the lock, the names that the manifests of the locked packages declare (by
## package name; check_manifests reads them before any file is loaded), and the packages loaded so far (by name).
export struct Scope
  vendor: String
  direct: List[String]
  lock: Lock.Lock
  declared: Map[String, List[String]]
  opened: Map[String, Opened]
end

## How a `pkg/` import reads: a library of the pkg/ roots, or a package and the module inside it (a path with `.agc`).
export enum Match
  Library
  Package(String, String)
end

## A package file that was found. name is the stored name of the file.
export struct Located
  file: String
  origin: Origin
  name: String
  opened: Map[String, Opened]
end

# Where a locked package is read from: its folder, and whether that is the vendored copy. The folder is "" when the
# package is not vendored and the cache has no place (no HOME).
struct Source
  folder: String
  vendored: Bool
end

# What a package folder holds under the name of the manifest.
enum Shape
  Absent
  Regular
  Unsafe(String)
  Unlisted(String)
end

## The scope of a build of this project, before any package is loaded.
export def scope_of(project: Project.Project) -> Scope
  case project
    Project.Project.Bare ->
      return Scope(vendor: "", direct: [], lock: Lock.Lock(file: "", packages: []), declared: {}, opened: {})
    Project.Project.Declared(found) ->
      return Scope(
        vendor: Paths.join(found.dir, VENDOR_FOLDER),
        direct: Project.direct_names(project),
        lock: found.lock,
        declared: {},
        opened: {},
      )
  end
end

## The origin of a file of the project.
export def project_origin() -> Origin
  return Origin(package: "", root: "", label: "")
end

## Tells how the `pkg/` import path file (ending in .agc, a valid library path) reads. A declared name is a package,
## and it shadows the library roots for that name. An undeclared name is a library for a file of the project, and
## CHECK-IMPORT-PACKAGE for a file of a package, which reaches nothing its manifest does not declare. `pkg/name` alone,
## naming no module, is CHECK-IMPORT-PATH when `name` is declared.
export def match_import(scope: Scope, origin: Origin, file: String, site: Failure.Site) -> Result[Match]
  names = allowed_names(scope, origin)
  parts = file.split("/")
  if parts.size == 2
    stem = parts[1].slice(0, parts[1].length - 4)
    if declared?(names, stem)
      return error(refuse(site, "a package is imported by a module of it", "write pkg/#{stem}/ and a module name"))
    end
  elsif declared?(names, parts[1])
    return ok(Match.Package(parts[1], parts.drop(2).join("/")))
  end
  if origin.package != ""
    message = "a file of a package imports only the packages its agentica.toml declares"
    return error(missing(site, message, "declare #{parts[1]} in the agentica.toml of #{origin.package}"))
  end
  return ok(Match.Library)
end

## Finds the module rest of the package name: its vendored copy or the cache folder of the locked commit, hashed (and
## its manifest read) the first time it is used.
export def open_package(
  workspace: Workspace.Workspace,
  env: Env.Env,
  scope: Scope,
  name: String,
  rest: String,
  site: Failure.Site,
) -> Result[Located]
  opened = scope.opened
  if !opened.has_key?(name)
    locked = Lock.find(scope.lock, name)
    if !locked.ok?
      return error(missing(site, "#{name} is not in the lock", "the lock must list #{name}"))
    end
    loaded = try load(workspace, env, scope, locked.unwrap!, site)
    opened = opened.put(name, loaded)
  end
  package = opened[name]
  target = workspace.real_path.call(Paths.join(package.root, rest))
  if !target.ok? or !workspace.file_exists.call(target.unwrap!)
    return error(Failure.fail_at(site, "CHECK-IMPORT-IO", "cannot find package module", Diag.Help.NoHelp))
  end
  inner = try confined(package.root, target.unwrap!, site)
  return ok(
    Located(
      file: target.unwrap!,
      origin: Origin(package: name, root: package.root, label: package.label),
      name: stored_name(package.label, inner),
      opened: opened,
    ),
  )
end

## Checks that a file found by a relative import in a package stays in the package, and gives its stored name.
export def stay_inside(origin: Origin, file: String, site: Failure.Site) -> Result[String]
  inner = try confined(origin.root, file, site)
  return ok(stored_name(origin.label, inner))
end

## Checks the manifest of every package of the lock that is vendored or in the cache against the lock, before any file
## is loaded, so one name with two sources anywhere in the tree (PKG-SOURCE-CONFLICT), or a name the lock lacks
## (PKG-LOCK-STALE), is reported whether or not an import reaches that package. What cannot be looked at safely is left
## for the import that loads it: a package that is neither vendored nor in the cache, a folder that cannot be listed
## and a manifest that is not a regular file report their own diagnostic there (and nothing is read from them here). It
## gives the scope with the names that the manifests declare, so that loading a package does not list its folder
## again.
export def check_manifests(workspace: Workspace.Workspace, env: Env.Env, scope: Scope) -> Result[Scope]
  declared = scope.declared
  for locked in scope.lock.packages
    source = source_of(workspace, env, scope, locked)
    if source.folder == ""
      next
    end
    real = workspace.real_path.call(source.folder)
    if real.ok? and workspace.directory_exists.call(real.unwrap!)
      case shape_of(workspace, real.unwrap!)
        Shape.Absent -> declared = declared.put(locked.name, [])
        Shape.Regular ->
          names = try read_names(workspace, scope.lock, real.unwrap!)
          declared = declared.put(locked.name, names)
        Shape.Unsafe(_) -> next
        Shape.Unlisted(_) -> next
      end
    end
  end
  return ok(scope.with(declared: declared))
end

## Whether the `pkg/` import path file (ending in .agc) names a module of a locked package, such as `pkg/tools/x.agc`
## when `tools` is in the lock. For a name the importing manifest does not declare, the library search then skips
## `agc_libs/`, where `agentica vendor` put a copy of every locked package, so a vendored build reaches the same
## packages as a cache-only one.
export def locked_module?(scope: Scope, file: String) -> Bool
  parts = file.split("/")
  return parts.size > 2 and Lock.find(scope.lock, parts[1]).ok?
end

## The folder of the vendored copy of a locked package, `agc_libs/<name>` beside the manifest of the project.
export def vendored_folder(scope: Scope, name: String) -> String
  return Paths.join(scope.vendor, name)
end

# The vendored copy when the project folder has an entry of that name (a link or a file too: it is looked at without
# following, and then read, so a copy that cannot be read is an error and the cache is not used instead), else the
# cache folder of the commit.
def source_of(workspace: Workspace.Workspace, env: Env.Env, scope: Scope, locked: Lock.Locked) -> Source
  if scope.vendor != ""
    listed = workspace.list_folder.call(scope.vendor)
    if listed.ok? and listed.unwrap!.any? do |entry| entry.name == locked.name end
      return Source(folder: vendored_folder(scope, locked.name), vendored: true)
    end
  end
  cache = PackageCache.root(env)
  if cache == ""
    return Source(folder: "", vendored: false)
  end
  return Source(folder: PackageCache.folder(cache, locked.source, locked.commit), vendored: false)
end

# The name of a package file in the program and in the .agcb: it does not depend on the cache folder of the machine.
def stored_name(label: String, inner: String) -> String
  return "pkg/#{label}/#{inner}"
end

# The path of file from root, which is in it and in no hidden folder or agc_libs/ (those are not hashed, so not
# importable). A file that is outside is CHECK-IMPORT-PATH.
def confined(root: String, file: String, site: Failure.Site) -> Result[String]
  if !Paths.inside?(root, file)
    return error(refuse(site, "an import cannot leave its package", "keep the path inside the package"))
  end
  below = Paths.path_parts(file).drop(Paths.path_parts(root).size)
  folders = below.take(below.size - 1)
  hidden = folders.any? do |part| PackageHash.skipped_folder?(part, false) end
  if hidden or (folders.size > 0 and PackageHash.skipped_folder?(folders[0], true))
    return error(refuse(site, "a hidden folder or agc_libs of a package cannot be imported", "move the module"))
  end
  return ok(below.join("/"))
end

# The package from its vendored copy or the cache, with its hash checked against the lock and its manifest read.
def load(
  workspace: Workspace.Workspace,
  env: Env.Env,
  scope: Scope,
  locked: Lock.Locked,
  site: Failure.Site,
) -> Result[Opened]
  source = source_of(workspace, env, scope, locked)
  if source.folder == ""
    return error(missing(site, "there is no package cache folder: HOME is not set", "set HOME or XDG_CACHE_HOME"))
  end
  real = workspace.real_path.call(source.folder)
  if !real.ok? or !workspace.directory_exists.call(real.unwrap!)
    if source.vendored
      message = "the vendored copy #{source.folder} of #{locked.name} is not a folder"
      return error(missing(site, message, "run agentica vendor, or remove #{source.folder}"))
    end
    return error(missing(site, "#{locked.name} is not in the package cache", "put the package in #{source.folder}"))
  end
  try verify(workspace, locked, real.unwrap!, source, site)
  names = try names_of(workspace, scope, locked, real.unwrap!, site)
  label = "#{locked.name}@#{GitSource.version_label(locked.source, locked.commit)}"
  return ok(Opened(root: real.unwrap!, label: label, names: names))
end

def verify(
  workspace: Workspace.Workspace,
  locked: Lock.Locked,
  real: String,
  source: Source,
  site: Failure.Site,
) -> Result[Void]
  case PackageHash.hash_folder(workspace, real)
    PackageHash.Hashed.Link(path) ->
      return error(
        Failure.fail_at(site, "PKG-SYMLINK", "#{locked.name} has a symbolic link named #{path}", Diag.Help.NoHelp),
      )
    PackageHash.Hashed.Unreadable(message) ->
      return error(Failure.fail_at(site, "CHECK-IMPORT-IO", "cannot read the package: #{message}", Diag.Help.NoHelp))
    PackageHash.Hashed.Hash(hash) ->
      if hash != locked.hash
        where = "in the cache"
        help = "remove #{source.folder} and put the package back in the cache"
        if source.vendored
          where = "in agc_libs"
          help = "run agentica vendor to put the locked files back"
        end
        message = "the files of #{locked.name} #{where} are not the ones the lock names"
        return error(Failure.fail_at(site, "PKG-HASH-MISMATCH", message, Failure.hint(help)))
      end
      return ok()
  end
end

# Looks at the folder itself, without following links, before the manifest is opened: the manifest must be a regular
# file of the package. A link, a folder or a pipe under that name (in any case, for a case-insensitive file system)
# would let the build read a file outside the cache folder, or block on a device.
def shape_of(workspace: Workspace.Workspace, root: String) -> Shape
  entries = workspace.list_folder.call(root)
  if !entries.ok?
    return Shape.Unlisted(entries.message)
  end
  for entry in entries.unwrap!
    if PackageHash.fold(entry.name) == MANIFEST_FILE and !regular?(entry.kind)
      return Shape.Unsafe(entry.name)
    end
  end
  if workspace.file_exists.call(Paths.join(root, MANIFEST_FILE))
    return Shape.Regular
  end
  return Shape.Absent
end

def regular?(kind: Workspace.EntryKind) -> Bool
  case kind
    Workspace.EntryKind.File -> return true
    Workspace.EntryKind.Directory -> return false
    Workspace.EntryKind.Link -> return false
    Workspace.EntryKind.Other -> return false
  end
end

# The names the manifest of the package declares: those check_manifests read, else the manifest is looked at now.
def names_of(
  workspace: Workspace.Workspace,
  scope: Scope,
  locked: Lock.Locked,
  root: String,
  site: Failure.Site,
) -> Result[List[String]]
  if scope.declared.has_key?(locked.name)
    return ok(scope.declared[locked.name])
  end
  return declared_names(workspace, scope.lock, root, site)
end

# The names the manifest of the package declares, none when it has no manifest. Each must be in the lock with the same
# source (PKG-LOCK-STALE for a missing one, PKG-SOURCE-CONFLICT for another source). The manifest is not part of the
# hash, so what it can do is limited to this check: it picks among the names of the lock and cannot change one. A
# manifest that is not a regular file is PKG-SYMLINK at the import, as a link among the .agc files is.
def declared_names(
  workspace: Workspace.Workspace,
  lock: Lock.Lock,
  root: String,
  site: Failure.Site,
) -> Result[List[String]]
  case shape_of(workspace, root)
    Shape.Absent -> return ok([])
    Shape.Regular -> return read_names(workspace, lock, root)
    Shape.Unsafe(name) ->
      message = "#{name} in the package is not a regular file"
      return error(Failure.fail_at(site, "PKG-SYMLINK", message, Failure.hint("a manifest is a file of the package")))
    Shape.Unlisted(message) ->
      return error(Failure.fail_at(site, "CHECK-IMPORT-IO", "cannot read the package: #{message}", Diag.Help.NoHelp))
  end
end

def read_names(workspace: Workspace.Workspace, lock: Lock.Lock, root: String) -> Result[List[String]]
  manifest = try Manifest.read(workspace, Paths.join(root, MANIFEST_FILE))
  try Project.check_dependencies(lock, manifest, true)
  return ok(Manifest.names(manifest))
end

def declared?(names: List[String], name: String) -> Bool
  return names.any? do |declared| declared == name end
end

def missing(site: Failure.Site, message: String, help: String) -> String
  return Failure.fail_at(site, "CHECK-IMPORT-PACKAGE", message, Failure.hint(help))
end

def refuse(site: Failure.Site, message: String, help: String) -> String
  return Failure.fail_at(site, "CHECK-IMPORT-PATH", message, Failure.hint(help))
end

# The project's own names for a file of the project, else those of the manifest of the package it belongs to.
def allowed_names(scope: Scope, origin: Origin) -> List[String]
  if origin.package == ""
    return scope.direct
  elsif !scope.opened.has_key?(origin.package)
    return []
  end
  return scope.opened[origin.package].names
end

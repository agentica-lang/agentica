## Imports of packages (docs/future/45-packages.md, 45.3 and 45.8). An import is a package import only when its first
## parts are a key that the importing file may use: the manifest's [dependencies] for a file of the project, the
## `requires` of the lock for a file of a package. The files come from the cache folder of the commit the lock names,
## and the first time a build loads a package, the hash of its .agc files must be the hash in the lock.

import Diag from "diagnostic"
import Probe from "file_probe"
import Paths from "import_path"
import Env from "link_env"
import Failure from "link_failure"
import Lock from "lock"
import Manifest from "manifest"
import PackageCache from "package_cache"
import PackageHash from "package_hash"
import Project from "project"

## The package a file belongs to. package is its key, root the real folder of its files in the cache and label
## `key@version`, which starts the stored name of each of its files. All are "" for the files of the project.
export struct Origin
  package: String
  root: String
  label: String
end

## What a build knows when it resolves an import: the keys the project declares, the lock, and the packages hashed so
## far (key to folder).
export struct Scope
  direct: List[String]
  lock: Lock.Lock
  verified: Map[String, String]
end

## How an import path reads: a relative path, or a package and the module inside it (a path with `.agc`, no leading
## part).
export enum Match
  Relative
  Package(String, String)
end

## A package file that was found. name is the stored name of the file.
export struct Located
  file: String
  origin: Origin
  name: String
  verified: Map[String, String]
end

## The scope of a build of this project, before any package is loaded.
export def scope_of(project: Project.Project) -> Scope
  case project
    Project.Project.Bare -> return Scope(direct: [], lock: Lock.Lock(file: "", packages: []), verified: {})
    Project.Project.Declared(found) ->
      return Scope(direct: Project.direct_keys(project), lock: found.lock, verified: {})
  end
end

## The origin of a file of the project.
export def project_origin() -> Origin
  return Origin(package: "", root: "", label: "")
end

## The keys that a file of this origin may import as packages: the project's own for a file of the project, else the
## `requires` of the package it belongs to.
export def allowed_keys(scope: Scope, origin: Origin) -> List[String]
  if origin.package == ""
    return scope.direct
  end
  locked = Lock.find(scope.lock, origin.package)
  if !locked.ok?
    return []
  end
  return locked.unwrap!.requires.map do |required| required.key end
end

## Tells whether the import path file (ending in .agc) names a package of keys. A path in the form
## `github.com/owner/repo/` of a declared key, or `owner/repo` alone of a declared key, is CHECK-IMPORT-PATH: there is
## one way to write each.
export def match_import(keys: List[String], file: String, site: Failure.Site) -> Result[Match]
  declared = Set.new(keys)
  parts = file.split("/")
  count = Manifest.key_parts(parts[0])
  if parts.size < count
    return ok(Match.Relative)
  end
  if parts.size == count
    stem = file.slice(0, file.length - 4)
    if declared.include?(stem)
      return error(refuse(site, "a package is imported by a module of it", "write #{stem}/module, naming a module"))
    end
    return ok(Match.Relative)
  end
  key = parts.take(count).join("/")
  if declared.include?(key)
    rest = parts.drop(count).join("/")
    try Paths.validate_library_path(rest, site)
    return ok(Match.Package(key, rest))
  end
  github = parts.drop(1).take(2).join("/")
  if parts[0] == "github.com" and parts.size > 3 and declared.include?(github)
    return error(refuse(site, "a GitHub package has no host in its path", "write #{github}/... for GitHub"))
  end
  return ok(Match.Relative)
end

## CHECK-IMPORT-AMBIGUOUS when a file or a folder beside the importing file also matches the package import: nothing is
## chosen silently. folder is the folder of the importing file.
export def check_ambiguity(folder: String, key: String, file: String, site: Failure.Site) -> Result[Void]
  if Probe.file?(Paths.join(folder, file)) or Probe.directory?(Paths.join(folder, key))
    return error(
      Failure.fail_at(
        site,
        "CHECK-IMPORT-AMBIGUOUS",
        "the import names the package #{key} and a file or folder beside this file",
        Failure.hint("rename the file or folder, or the import"),
      ),
    )
  end
  return ok()
end

## Finds the module rest of the package key: the cache folder of the locked commit, hashed the first time it is used.
export def open_package(
  settings: Env.Settings,
  scope: Scope,
  key: String,
  rest: String,
  site: Failure.Site,
) -> Result[Located]
  locked = Lock.find(scope.lock, key)
  if !locked.ok?
    return error(missing(site, key, "#{key} is not in the lock"))
  end
  verified = scope.verified
  if !verified.has_key?(key)
    folder = try verify(settings, locked.unwrap!, site)
    verified = verified.put(key, folder)
  end
  root = verified[key]
  label = "#{key}@#{locked.unwrap!.version}"
  target = Path.real(Paths.join(root, rest))
  if !target.ok? or !Probe.file?(target.unwrap!)
    return error(Failure.fail_at(site, "CHECK-IMPORT-IO", "cannot find package module", Diag.Help.NoHelp))
  end
  inner = try confined(root, target.unwrap!, site)
  return ok(
    Located(
      file: target.unwrap!,
      origin: Origin(package: key, root: root, label: label),
      name: "#{label}/#{inner}",
      verified: verified,
    ),
  )
end

## Checks that a file found by a relative import in a package stays in the package, and gives its stored name.
export def stay_inside(origin: Origin, file: String, site: Failure.Site) -> Result[String]
  inner = try confined(origin.root, file, site)
  return ok("#{origin.label}/#{inner}")
end

# The path of file from root, which is in it and in no hidden folder or agc_libs/ (those are not hashed, so not
# importable). A file that is outside is CHECK-IMPORT-PATH.
def confined(root: String, file: String, site: Failure.Site) -> Result[String]
  if !Paths.inside?(root, file)
    return error(refuse(site, "an import cannot leave its package", "keep the path inside the package"))
  end
  below = Paths.path_parts(file).drop(Paths.path_parts(root).size)
  folders = below.take(below.size - 1)
  if folders.any? do |part| part.starts_with?(".") end or (folders.size > 0 and folders[0] == "agc_libs")
    return error(refuse(site, "a hidden folder or agc_libs of a package cannot be imported", "move the module"))
  end
  return ok(below.join("/"))
end

# The real folder of the package in the cache, with its hash checked against the lock.
def verify(settings: Env.Settings, locked: Lock.Locked, site: Failure.Site) -> Result[String]
  cache = PackageCache.root(settings.env, Paths.windows?())
  if cache == ""
    return error(missing(site, locked.name, "there is no package cache folder: HOME is not set"))
  end
  folder = PackageCache.folder(cache, locked.name, locked.commit)
  real = Path.real(folder)
  if !real.ok? or !Probe.directory?(real.unwrap!)
    return error(missing(site, locked.name, "#{locked.name} is not in the package cache"))
  end
  case PackageHash.hash_folder(real.unwrap!)
    PackageHash.Hashed.Link(path) ->
      return error(
        Failure.fail_at(site, "PKG-SYMLINK", "#{locked.name} has a symbolic link named #{path}", Diag.Help.NoHelp),
      )
    PackageHash.Hashed.Unreadable(message) ->
      return error(Failure.fail_at(site, "CHECK-IMPORT-IO", "cannot read the package: #{message}", Diag.Help.NoHelp))
    PackageHash.Hashed.Hash(hash) ->
      if hash != locked.hash
        return error(
          Failure.fail_at(
            site,
            "PKG-HASH-MISMATCH",
            "the files of #{locked.name} in the cache are not the ones the lock names",
            Failure.hint("remove #{folder} and run agentica install"),
          ),
        )
      end
      return ok(real.unwrap!)
  end
end

def missing(site: Failure.Site, key: String, message: String) -> String
  return Failure.fail_at(site, "CHECK-IMPORT-PACKAGE", message, Failure.hint("run agentica install"))
end

def refuse(site: Failure.Site, message: String, help: String) -> String
  return Failure.fail_at(site, "CHECK-IMPORT-PATH", message, Failure.hint(help))
end

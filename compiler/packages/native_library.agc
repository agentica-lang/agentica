## The native libraries of a package (docs/grammar/05b-modules.md): `[native.NAME]` in its manifest says where the
## library that `extern "NAME"` means is on each system, either a file in the package's native/ folder (hashed with the
## package, so the lock covers it) or a name for the system loader. A file is turned into its absolute path, which the
## VM opens as it opens any absolute library; never a search. Only the entry of this system is looked at, and only when
## a file of the package uses the library, so a package works on the systems it names and is refused on the others
## where it is used. This does no I/O of its own: it asks the Workspace.

import Paths from "../modules/import_path"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import Manifest from "manifest"
import PackageHash from "package_hash"
import Reader from "toml_read"

## What `extern "name"` means in a file of the package: the absolute path of a file of the package, a name for the
## system loader, or the packed failure to report when the file uses it.
export enum Target
  File(String)
  System(String)
  Unusable(String)
end

## What a manifest's [native] table means on one system: the target of each library it declares, and what the bytecode
## cache must watch because the program opens it. For a package that is the folder itself (the cache digests the
## names of its native/ files, so an added file is seen), every file of native/ (a library may load others), and the
## manifest when the package hash covers it. For the project it is only the declared files for this system: its
## manifest is in the cache key already, and its folder is not walked. watched is empty when there is nothing to open.
export struct Found
  targets: Map[String, Target]
  watched: List[String]
end

## The libraries a manifest declares, for the system `os` ("linux", "macos" or "windows"). `root` is the real folder of
## the package (or of the project), which holds the files. `package` is false for the project, whose files are not
## hashed; `member` is true for a workspace member, whose are not either.
export def resolve(
  workspace: Workspace.Workspace,
  manifest: Manifest.Manifest,
  root: String,
  os: String,
  package: Bool,
  member: Bool,
) -> Found
  targets: Map[String, Target] = {}
  for library in manifest.natives
    targets = targets.put(library.name, target_of(workspace, manifest, library, root, os))
  end
  if !package
    return Found(targets: targets, watched: files(targets))
  end
  names = PackageHash.native_files(workspace, root)
  hashed = !member and PackageHash.manifest_hashed?(workspace, root, names)
  if names.size == 0 and !hashed and manifest.natives.size == 0
    return Found(targets: targets, watched: [])
  end
  watched = [root].concat(names.map do |path: String| Paths.join(root, path) end)
  if hashed
    watched = watched.push(manifest.file)
  end
  return Found(targets: targets, watched: watched)
end

# The files that the targets name.
def files(targets: Map[String, Target]) -> List[String]
  found: List[String] = []
  for name in targets.keys
    case targets[name]
      Target.File(path) -> found = found.push(path)
      Target.System(_) -> next
      Target.Unusable(_) -> next
    end
  end
  return found
end

def target_of(
  workspace: Workspace.Workspace,
  manifest: Manifest.Manifest,
  library: Manifest.NativeLibrary,
  root: String,
  os: String,
) -> Target
  here = Reader.child("native", library.name)
  for place in library.places
    if place.system != os
      next
    end
    if place.file == ""
      return Target.System(place.name)
    end
    path = Paths.join(root, place.file)
    if workspace.file_exists.call(path)
      return Target.File(path)
    end
    key = Reader.child(Reader.child(here, os), "file")
    message = "the native file #{place.file} is not in the package"
    return Target.Unusable(
      Failure.fail_key(manifest.file, key, "PKG-NATIVE-MISSING", message, Failure.hint("put the file in the package")),
    )
  end
  message = "the library #{library.name} is not declared for #{os}"
  help = "add [#{here}.#{os}] to the manifest of the package"
  return Target.Unusable(
    Failure.fail_key(manifest.file, here, "PKG-NATIVE-PLATFORM", message, Failure.hint(help)),
  )
end

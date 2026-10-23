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
import Reader from "toml_read"

## What `extern "name"` means in a file of the package: the absolute path of a file of the package, a name for the
## system loader, or the packed failure to report when the file uses it.
export enum Target
  File(String)
  System(String)
  Unusable(String)
end

## The target of each library the manifest declares, for the system `os` ("linux", "macos" or "windows"). `root` is the
## real folder of the package, which holds the files.
export def resolve(
  workspace: Workspace.Workspace,
  manifest: Manifest.Manifest,
  root: String,
  os: String,
) -> Map[String, Target]
  found: Map[String, Target] = {}
  for library in manifest.natives
    found = found.put(library.name, target_of(workspace, manifest, library, root, os))
  end
  return found
end

## The files of the package among the targets: what the bytecode cache watches.
export def files(targets: Map[String, Target]) -> List[String]
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

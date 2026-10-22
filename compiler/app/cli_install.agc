## `agentica install`: fills the package cache from agentica.lock (docs/future/45-packages.md, 45.9). The project is
## the one of the working folder, found as a build finds it (the nearest agentica.toml going up), and the lock is read
## as a build reads it, so a manifest that asks for more than the lock holds is PKG-LOCK-STALE. The lock is never
## written. A package that is in the cache with the locked hash is left alone and git does not run for it; the others
## are fetched (io/package_fetch.agc), one after the other, and the first failure stops the command. When all are in
## the cache, the manifest of each package is checked against the lock, as a build checks it.

import Front from "../analysis/front"
import PackageFetch from "../io/package_fetch"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import GitSource from "../packages/git_source"
import Lock from "../packages/lock"
import PackageCache from "../packages/package_cache"
import PackageImport from "../packages/package_import"
import Project from "../packages/project"
import Reader from "../packages/toml_read"
import Reply from "cli_reply"

# The manifest the command looks for, as in packages/project.agc.
MANIFEST_FILE = "agentica.toml"

## Runs `install` in the working folder. `style` is the output style of the options: with `json` a success prints
## `{"ok":true}`, as `check` does.
export def run(settings: Env.Settings, style: String) -> Reply.Answer
  cwd = Path.cwd()
  if !cwd.ok?
    return Reply.Answer.Printed(Reply.failed(2, "agentica: cannot read the working folder\n"))
  end
  real = settings.workspace.real_path.call(cwd.unwrap!)
  dir = cwd.unwrap!
  if real.ok?
    dir = real.unwrap!
  end
  installed = install(settings, dir)
  if !installed.ok?
    return Reply.Answer.Rejected(Front.link_problem(Failure.unpack_failure(installed.message)))
  end
  if style == "json"
    return Reply.Answer.Printed(Reply.printed("{\"ok\":true}\n"))
  end
  return Reply.Answer.Printed(Reply.printed(installed.unwrap!))
end

# The lines of the answer, or a packed failure.
def install(settings: Env.Settings, dir: String) -> Result[String]
  workspace = settings.workspace
  project = try Project.find(workspace, dir)
  case project
    Project.Project.Bare ->
      file = Paths.join(dir, MANIFEST_FILE)
      message = "there is no #{MANIFEST_FILE} in this folder or above"
      help = Failure.hint("write #{MANIFEST_FILE} in the folder of the project, with a [dependencies] table")
      return error(Failure.fail_file(file, "PKG-MANIFEST-MISSING", message, help))
    Project.Project.Declared(found) ->
      lines = try fill_all(settings, found.lock)
      try PackageImport.check_manifests(workspace, settings.env, PackageImport.scope_of(project))
      return ok(lines)
  end
end

# Fills the cache with every package of the lock, in the order of the file.
def fill_all(settings: Env.Settings, lock: Lock.Lock) -> Result[String]
  if lock.packages.size == 0
    return ok("nothing to install\n")
  end
  cache = PackageCache.root(settings.env)
  if cache == ""
    message = "there is no package cache folder: HOME is not set"
    return error(Failure.fail_file(lock.file, "PKG-FETCH", message, Failure.hint("set HOME or XDG_CACHE_HOME")))
  end
  lines: List[String] = []
  for index in 0...lock.packages.size
    locked = lock.packages[index]
    place = PackageFetch.Place(file: lock.file, entry: Reader.item("package", index))
    filled = try PackageFetch.fill(settings.workspace, cache, place, locked)
    label = "#{locked.name}@#{GitSource.version_label(locked.source, locked.commit)}"
    case filled
      PackageFetch.Filled.Fetched -> lines = lines.push("fetched #{label}")
      PackageFetch.Filled.Present -> lines = lines.push("in the cache #{label}")
    end
  end
  return ok("#{lines.join("\n")}\n")
end

## `agentica install`: fills the package cache from agentica.lock (docs/future/45-packages.md, 45.9). The project is
## the one of the working folder, found as a build finds it (the nearest agentica.toml going up), and the lock is read
## as a build reads it, so a manifest that asks for more than the lock holds is PKG-LOCK-STALE. The lock is never
## written. A package that is in the cache with the locked hash is left alone and git does not run for it; the others
## are fetched (io/package_fetch.agc), one after the other, and the first failure stops the command. When all are in
## the cache, the manifest of each package is checked against the lock, as a build checks it (the cache's, not a
## vendored copy's: `install` is about the cache).

import PackageFetch from "../io/package_fetch"
import Env from "../modules/link_env"
import GitSource from "../packages/git_source"
import Lock from "../packages/lock"
import PackageImport from "../packages/package_import"
import Project from "../packages/project"
import Reader from "../packages/toml_read"
import CliProject from "cli_project"
import Reply from "cli_reply"

## Runs `install` in the working folder. `style` is the output style of the options: with `json` a success prints
## `{"ok":true}`, as `check` does.
export def run(settings: Env.Settings, style: String) -> Reply.Answer
  return CliProject.run(style, settings.workspace) do |dir: String| install(settings, dir) end
end

## Fills the cache with every package of the lock, in the order of the file. The lines say `fetched` or `in the cache`
## for each package.
export def fill_all(settings: Env.Settings, lock: Lock.Lock) -> Result[String]
  if lock.packages.size == 0
    return ok("nothing to install\n")
  end
  cache = try PackageFetch.cache_root(settings.env, lock.file)
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

# The lines of the answer, or a packed failure.
def install(settings: Env.Settings, dir: String) -> Result[String]
  workspace = settings.workspace
  project = try Project.find(workspace, dir)
  case project
    Project.Project.Bare -> return error(CliProject.missing_manifest(dir))
    Project.Project.Declared(found) ->
      lines = try fill_all(settings, found.lock)
      try PackageImport.check_manifests(workspace, settings.env, PackageImport.scope_of(project).with(vendor: ""))
      return ok(lines)
  end
end

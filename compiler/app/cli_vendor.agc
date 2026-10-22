## `agentica vendor`: copies the locked packages into `agc_libs/<name>/` beside agentica.toml
## (docs/future/45-packages.md, 45.9). It first fills the cache as `install` does (git runs only for a package the
## cache lacks), checks the manifests of the packages, and then writes each package from the cache. A build reads a
## vendored copy before the cache and hashes it against the lock. The lock is never written, and nothing in agc_libs/
## is touched except the folders of the locked packages.

import PackageFetch from "../io/package_fetch"
import PackageVendor from "../io/package_vendor"
import Env from "../modules/link_env"
import GitSource from "../packages/git_source"
import PackageCache from "../packages/package_cache"
import PackageImport from "../packages/package_import"
import Project from "../packages/project"
import Reader from "../packages/toml_read"
import CliInstall from "cli_install"
import CliProject from "cli_project"
import Reply from "cli_reply"

## Runs `vendor` in the working folder. `style` is the output style of the options: with `json` a success prints
## `{"ok":true}`, as `check` does.
export def run(settings: Env.Settings, style: String) -> Reply.Answer
  return CliProject.run(style, settings.workspace) do |dir: String| vendor(settings, dir) end
end

# The lines of the answer, or a packed failure.
def vendor(settings: Env.Settings, dir: String) -> Result[String]
  workspace = settings.workspace
  project = try Project.find(workspace, dir)
  case project
    Project.Project.Bare -> return error(CliProject.missing_manifest(dir))
    Project.Project.Declared(found) ->
      if found.lock.packages.size == 0
        return ok("nothing to vendor\n")
      end
      try CliInstall.fill_all(settings, found.lock)
      scope = PackageImport.scope_of(project)
      try PackageImport.check_manifests(workspace, settings.env, scope.with(vendor: ""))
      return copy_all(settings, found, scope.vendor)
  end
end

# Writes every package of the lock, in the order of the file; the first failure stops the command.
def copy_all(settings: Env.Settings, found: Project.Found, libs: String) -> Result[String]
  cache = try PackageFetch.cache_root(settings.env, found.lock.file)
  lines: List[String] = []
  for index in 0...found.lock.packages.size
    locked = found.lock.packages[index]
    place = PackageFetch.Place(file: found.lock.file, entry: Reader.item("package", index))
    folder = PackageCache.folder(cache, locked.source, locked.commit)
    source = settings.workspace.real_path.call(folder)
    if !source.ok?
      return error(PackageFetch.fail(place, "PKG-FETCH", "", "cannot read #{folder}", source.message))
    end
    try PackageVendor.put(settings.workspace, libs, source.unwrap!, place, locked)
    lines = lines.push("vendored #{locked.name}@#{GitSource.version_label(locked.source, locked.commit)}")
  end
  return ok("#{lines.join("\n")}\n")
end

## `agentica add NAME URL --tag TAG` (or `--ref COMMIT`) and `agentica update [NAME]` (docs/future/45-packages.md,
## 45.9). Both work on the project of the working folder, resolve its packages (io/package_resolve.agc: git runs for
## the pins that are new or asked to move), fill the cache and write agentica.lock. `add` also puts the dependency in
## agentica.toml, with one line added and nothing else changed (packages/manifest_edit.agc). The lock is written first:
## a lock with more packages than the manifest needs is still good, while a manifest that names a package the lock
## lacks is PKG-LOCK-STALE. Nothing is written when anything before fails.

import PackageResolve from "../io/package_resolve"
import SaveFile from "../io/save_file"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import GitSource from "../packages/git_source"
import Lock from "../packages/lock"
import Manifest from "../packages/manifest"
import ManifestEdit from "../packages/manifest_edit"
import Project from "../packages/project"
import Reader from "../packages/toml_read"
import CliProject from "cli_project"
import Reply from "cli_reply"
import Texts from "cli_text"

# The deadline of the write of a file, in milliseconds.
WRITE_TIMEOUT_MS = 60_000

# What `add` was asked: the local name and where the package comes from.
struct Request
  name: String
  source: GitSource.Source
end

## Runs `add`. `words` are the ones after the command: NAME URL and `--tag TAG` or `--ref COMMIT`.
export def add(settings: Env.Settings, style: String, words: List[String]) -> Reply.Answer
  asked = request_of(words)
  if !asked.ok?
    return Reply.Answer.Printed(Reply.failed(2, asked.message))
  end
  return CliProject.run(style, settings.workspace) do |dir: String| add_to(settings, dir, asked.unwrap!) end
end

## Runs `update`. `words` are the ones after the command: none for every package, or the name of a dependency.
export def update(settings: Env.Settings, style: String, words: List[String]) -> Reply.Answer
  if words.size > 1
    return Reply.Answer.Printed(Reply.failed(2, Texts.usage_text()))
  end
  name = ""
  if words.size == 1
    name = words[0]
  end
  return CliProject.run(style, settings.workspace) do |dir: String| update_in(settings, dir, name) end
end

# NAME URL --tag TAG, or --ref COMMIT. A word that is not a good name, URL, tag or commit is refused here, before the
# project is read, with the reason of the rule that the manifest applies. The commit is the whole id: git fetches no
# abbreviation.
def request_of(words: List[String]) -> Result[Request]
  if words.size != 4 or (words[2] != "--tag" and words[2] != "--ref")
    return error(Texts.usage_text())
  end
  tag = ""
  ref = ""
  problem = GitSource.name_problem(words[0])
  if problem == ""
    problem = GitSource.git_problem(words[1])
  end
  if problem == "" and words[2] == "--tag"
    tag = words[3]
    problem = GitSource.tag_problem(tag)
  elsif problem == ""
    ref = words[3]
    problem = GitSource.ref_problem(ref)
    if problem == "" and ref.length != 40 and ref.length != 64
      problem = "add needs the whole commit: 40 (or 64) lowercase hex digits"
    end
  end
  if problem != ""
    return error("agentica: #{problem}\n")
  end
  return ok(Request(name: words[0], source: GitSource.Source(git: words[1], tag: tag, ref: ref)))
end

def add_to(settings: Env.Settings, dir: String, request: Request) -> Result[String]
  project = try Project.find_to_write(settings.workspace, dir)
  case project
    Project.Project.Bare -> return error(CliProject.missing_manifest(dir))
    Project.Project.Declared(found) -> return add_in(settings, found, request)
  end
end

def add_in(settings: Env.Settings, found: Project.Found, request: Request) -> Result[String]
  file = found.manifest.file
  if found.manifest.dependencies.any? do |dependency| dependency.name == request.name end
    message = "#{request.name} is already a dependency"
    help = Failure.hint("change its tag or ref in #{file} and run `agentica update #{request.name}`")
    return error(Failure.fail_key(file, "dependencies.#{request.name}", "PKG-DEPENDENCY-EXISTS", message, help))
  end
  text = try Reader.read_text(settings.workspace, Reader.Reading(file: file, code: "PKG-MANIFEST-INVALID"))
  edited = ManifestEdit.add_dependency(text, request.name, request.source)
  manifest = try added_manifest(found.manifest, edited, request)
  packages = try PackageResolve.resolve(settings, manifest, found.lock, PackageResolve.Refresh(all: false, name: ""))
  try save(found.lock.file, Lock.encode(packages))
  try save(file, edited)
  return ok(report(found.lock, packages))
end

# The manifest as the edit made it, which must be the old one and one more dependency: an odd layout (the table written
# as `dependencies = { ... }`, say) can make the edit fail to parse or land elsewhere, and nothing is saved then.
def added_manifest(old: Manifest.Manifest, edited: String, request: Request) -> Result[Manifest.Manifest]
  parsed = Manifest.parse(old.file, edited)
  if parsed.ok? and one_more?(old, parsed.unwrap!, request)
    return ok(parsed.unwrap!)
  end
  message = "cannot add #{request.name} to #{old.file}"
  help = Failure.hint("write the line by hand: #{request.name} = { git = \"...\", tag = \"...\" } in [dependencies]")
  return error(Failure.fail_key(old.file, "dependencies", "PKG-MANIFEST-EDIT", message, help))
end

def one_more?(old: Manifest.Manifest, manifest: Manifest.Manifest, request: Request) -> Bool
  entry = Manifest.find(manifest, request.name)
  if manifest.dependencies.size != old.dependencies.size + 1 or !entry.ok?
    return false
  end
  return GitSource.same?(entry.unwrap!.source, request.source)
end

def update_in(settings: Env.Settings, dir: String, name: String) -> Result[String]
  project = try Project.find_to_write(settings.workspace, dir)
  case project
    Project.Project.Bare -> return error(CliProject.missing_manifest(dir))
    Project.Project.Declared(found) -> return update_found(settings, found, name)
  end
end

def update_found(settings: Env.Settings, found: Project.Found, name: String) -> Result[String]
  manifest = found.manifest
  if name != "" and !Manifest.find(manifest, name).ok?
    message = "#{name} is not a dependency of #{manifest.file}"
    help = Failure.hint("only a dependency of the project can be updated by name; `agentica update` does them all")
    return error(Failure.fail_file(manifest.file, "PKG-DEPENDENCY-UNKNOWN", message, help))
  end
  refresh = PackageResolve.Refresh(all: name == "", name: name)
  packages = try PackageResolve.resolve(settings, manifest, found.lock, refresh)
  # A project with no dependency and no lock stays as it is: nothing asks for a lock.
  if packages.size > 0 or settings.workspace.file_exists.call(found.lock.file)
    try save(found.lock.file, Lock.encode(packages))
  end
  return ok(report(found.lock, packages))
end

# Writes the whole file. It is small and written in one call; a file that cannot be written is PKG-WRITE.
def save(file: String, text: String) -> Result[Void]
  written = SaveFile.bytes(file, String.to_bytes(text), WRITE_TIMEOUT_MS)
  if !written.ok?
    message = "cannot write #{file}"
    return error(Failure.fail_file(file, "PKG-WRITE", message, Failure.hint(written.message)))
  end
  return ok()
end

# What changed in the lock, one line each in the order of the new lock: added, updated (another commit or pin),
# removed. Nothing changed is said once.
def report(old: Lock.Lock, packages: List[Lock.Locked]) -> String
  lines: List[String] = []
  ordered = packages.sort_by do |item| item.name end
  for locked in ordered
    label = "#{locked.name}@#{GitSource.version_label(locked.source, locked.commit)}"
    before = Lock.find(old, locked.name)
    if !before.ok?
      lines = lines.push("added #{label}")
    elsif before.unwrap!.commit != locked.commit or !GitSource.same?(before.unwrap!.source, locked.source)
      lines = lines.push("updated #{label}")
    end
  end
  kept = Set.new(packages.map do |locked| locked.name end)
  for locked in old.packages
    if !kept.include?(locked.name)
      lines = lines.push("removed #{locked.name}")
    end
  end
  if lines.size == 0
    return "nothing to update\n"
  end
  return "#{lines.join("\n")}\n"
end

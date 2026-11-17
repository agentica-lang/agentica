## `agentica native source NAME`: the source key of the native module NAME of the project in the working folder (the
## nearest agentica.toml going up), the native API this Agentica builds with, and, when the module has a `prebuilt`
## table, the URL of the file of each target with that key and API (packages/native_prebuilt.agc). A package author's
## release workflow runs it to name the files it uploads, and the key goes into the manifest. The key is computed from
## the files of native/ that the hash of the package covers, so it is the same in the author's folder and in a copy
## fetched into deps/. A file over the size limit of a fetched package is PKG-NATIVE-BUILD at `native.NAME.build`.

import Paths from "../modules/import_path"
import Failure from "../modules/link_failure"
import Env from "../modules/link_env"
import Workspace from "../modules/workspace"
import Manifest from "../packages/manifest"
import NativePrebuilt from "../packages/native_prebuilt"
import PackageHash from "../packages/package_hash"
import Project from "../packages/project"
import Reader from "../packages/toml_read"
import Front from "../analysis/front"
import BuildMachine from "../io/native_build"
import CliProject from "cli_project"
import Reply from "cli_reply"

## The usage of the command, for a call with other words.
USAGE = "usage: agentica native source NAME\n"

## What the command prints: the source key, the native API and the URL of each target ({} with no prebuilt table).
struct Answer
  source: String
  api: String
  urls: Map[String, String]
end

## Runs `native` with the words after it. `style` is the output style of the options: with `json` the answer is one
## JSON object.
def run(settings: Env.Settings, style: String, words: List[String]) -> Reply.Answer
  return Reply.Answer.Printed(Reply.failed(2, USAGE)) if words.size != 2 or words[0] != "source"

  cwd = Path.cwd()
  return Reply.Answer.Printed(Reply.failed(2, "agentica: cannot read the working folder\n")) if !cwd.ok?

  dir = cwd.unwrap!
  real = settings.workspace.real_path.call(dir)
  if real.ok?
    dir = real.unwrap!
  end

  found = source(settings, dir, words[1])
  return Reply.Answer.Rejected(Front.link_problem(Failure.unpack_failure(found.message))) if !found.ok?

  Reply.Answer.Printed(Reply.printed(text(found.unwrap!, style)))
end

private

def source(settings: Env.Settings, dir: String, name: String) -> Result[Answer]
  project = try Project.find_to_write(settings.workspace, dir, settings.version)
  found: Optional[Project.Found] = none
  case project
    Project.Project.Bare -> return error(CliProject.missing_manifest(dir))
    Project.Project.Declared(declared) -> found = some(declared)
  end

  root = found.unwrap!.dir
  manifest = found.unwrap!.manifest
  library = try module_of(manifest, name)
  build = library.build.unwrap!
  key = Reader.child(Reader.child("native", name), "build")
  files = try native_files(settings.workspace, root, manifest.file, key)
  digests: List[String] = []
  for path in files
    read = settings.workspace.read_prefix.call(Paths.join(root, path), PackageHash.MAX_FILE_BYTES + 1)
    return error(refused(manifest.file, key, "cannot read #{path}: #{read.message}")) if !read.ok?

    if read.unwrap!.size > PackageHash.MAX_FILE_BYTES
      message = "#{path} is over #{PackageHash.MAX_FILE_BYTES} bytes, the most a file of a fetched package holds"
      return error(refused(manifest.file, key, message))
    end

    digests = digests.push(OpenSSL.Digest.sha256_hexdigest(read.unwrap!))
  end

  api = BuildMachine.native_api()
  key_hex = NativePrebuilt.source_key(NativePrebuilt.source_text(name, build, files, digests))
  urls: Map[String, String] = {}
  case library.prebuilt
    some(prebuilt) ->
      for target in NativePrebuilt.TARGETS
        urls = urls.put(target, NativePrebuilt.url_for(prebuilt, name, api, key_hex, target))
      end

    none -> urls = urls
  end

  ok(Answer(source: key_hex, api: api, urls: urls))
end

# The module NAME of the manifest, which has a `build` table.
def module_of(manifest: Manifest.Manifest, name: String) -> Result[Manifest.NativeLibrary]
  for library in manifest.natives
    if library.name == name
      return ok(library) if library.build.some?

      at = Reader.child("native", name)
      help = Failure.hint("a source key is for a module that builds: add a build table")
      return error(Failure.fail_key(manifest.file, at, "PKG-NATIVE-MISSING", "#{name} has no build table", help))
    end
  end

  message = "#{name} is not a native module of this project"
  help = Failure.hint("write [native.#{name}] with a build table in agentica.toml")
  error(Failure.fail_key(manifest.file, Reader.child("native", name), "PKG-NATIVE-MISSING", message, help))
end

# The files of native/ that the hash of the package covers, in its order.
def native_files(workspace: Workspace.Workspace, root: String, file: String, key: String) -> Result[List[String]]
  case PackageHash.covered_files(workspace, root)
    PackageHash.Listing.Files(paths) -> ok(paths.select do |path: String| PackageHash.native_path?(path) end)
    PackageHash.Listing.Stopped(reason) ->
      message = "cannot read the package"
      case reason
        PackageHash.Hashed.Link(path) -> message = "#{path} in the package is a symbolic link"
        PackageHash.Hashed.Unreadable(why) -> message = "cannot read the package: #{why}"
        PackageHash.Hashed.Hash(_) -> message = message
      end

      error(refused(file, key, message))
  end
end

def refused(file: String, key: String, message: String) -> String
  Failure.fail_key(file, key, "PKG-NATIVE-BUILD", message, Failure.hint("put the files of the module in native/"))
end

def text(answer: Answer, style: String) -> String
  if style == "json"
    fields: Map[String, JSON.Value] = {}
    for target in answer.urls.keys
      fields = fields.put(target, JSON.from(answer.urls[target]))
    end

    urls = JSON.object(fields)
    document = JSON.object({"source": JSON.from(answer.source), "api": JSON.from(answer.api), "urls": urls})
    return "#{JSON.encode(document)}\n"
  end

  lines = ["source #{answer.source}", "api #{answer.api}"]
  for target in NativePrebuilt.TARGETS
    if answer.urls.has_key?(target)
      lines = lines.push("#{target} #{answer.urls[target]}")
    end
  end

  "#{lines.join("\n")}\n"
end

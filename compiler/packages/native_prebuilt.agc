## Prebuilt native modules (docs/grammar/05b-modules.md): the `prebuilt` key of `[native.NAME]`, beside `build`, which
## names one library file per release target that the package author built from that `build`, and the project's
## `[native_policy]`, which says which modules always build from source and which never do. This holds the pure parts:
## the checks of both tables, the URL of a target, the source key that ties the files to the code they were built
## from, and the rules of the download (io/native_prebuilt.agc): the size cap, where a redirect may lead and the
## cache entry. A failure is the reading's code at the key path (toml_read.agc).
##
## The source key is the first 16 hex digits of the SHA-256 of `source_text`: the library, its `build` table and the
## files of native/ that the hash of the package covers, with the digest of each (a CRLF read as LF, so a checkout
## that turns LF into CRLF keys alike). The compiler, the header and the system are left out, so one key names the code
## for every target, and a manifest that only changes its `prebuilt` table keeps it. Every file of native/ is in the
## key of every module, since a source may include any of them: a package that wants a module keyed alone keeps one
## module per package.

import Paths from "../modules/import_path"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import NativeArtifact from "native_artifact"
import NativeBuild from "native_build"
import GitSource from "git_source"
import PackageHash from "package_hash"
import Toml from "std/toml"
import Reader from "toml_read"

## The five release targets, in the order the files list them.
TARGETS = ["linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64", "windows-x86_64"]
## The length of a source key in lowercase hex digits.
SOURCE_LENGTH = 16
## The table name of the policy, which only the project's manifest may write.
POLICY_KEY = "native_policy"
## The most bytes of one prebuilt file, the bodies of its redirects included.
FILE_MAX_BYTES = 67_108_864
## The hosts other than the one of the URL that a redirect may lead to: where GitHub serves release assets.
REDIRECT_HOSTS = ["objects.githubusercontent.com", "release-assets.githubusercontent.com"]
## The folder of the package cache that holds the prebuilt files, one entry per SHA-256.
CACHE_FOLDER = "native-prebuilt"
## The ways a policy can send a module: always build it from source, or never.
MODE_BUILD = "build"
MODE_PREBUILT_ONLY = "prebuilt_only"

## The files of one library for each target: a URL template, the source key and the native API the files were built
## with, and the SHA-256 of each target's file (64 lowercase hex digits), by target in the order of the file.
struct Prebuilt
  url: String
  source: String
  api: String
  sha256: Map[String, String]
end

## A list of module names, or every module.
struct Choice
  all: Bool
  names: List[String]
end

## `[native_policy]` of the project: the modules that always build from source, and those that never build (names
## without repeats); `written` is whether the manifest has the table, even an empty one.
struct Policy
  build: Choice
  prebuilt_only: Choice
  written: Bool
end

## The policy of a manifest without `[native_policy]`: nothing is forced.
def no_policy() -> Policy
  Policy(build: Choice(all: false, names: []), prebuilt_only: Choice(all: false, names: []), written: false)
end

## Reads `prebuilt = { url, source, api, sha256 = { TARGET = "..." } }` at `path` (`native.NAME.prebuilt`). Every key
## is required; `sha256` names at least one of TARGETS.
def parse(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[Prebuilt]
  entries = try Reader.table(reading, value, path)
  try Reader.known_keys(reading, entries, PREBUILT_KEYS, path)
  for key in PREBUILT_KEYS
    if !entries.has_key?(key)
      return error(Reader.fail_help(reading, path, "missing key #{key}", "write url, source, api and sha256"))
    end
  end

  url_path = Reader.child(path, "url")
  url = try Reader.text(reading, entries["url"], url_path)
  problem = url_problem(url)
  return error(Reader.fail_help(reading, url_path, "not a prebuilt URL", problem)) if problem != ""

  source_path = Reader.child(path, "source")
  source = try Reader.text(reading, entries["source"], source_path)
  if !source_key?(source)
    help = "write the #{SOURCE_LENGTH} lowercase hex digits that agentica native source NAME prints"
    return error(Reader.fail_help(reading, source_path, "not a source key", help))
  end

  api_path = Reader.child(path, "api")
  api = try Reader.text(reading, entries["api"], api_path)
  if !api_version?(api)
    help = "write the native API the files were built with, MAJOR.MINOR with no leading zero, as"
    help = "#{help} agentica native source NAME prints it"
    return error(Reader.fail_help(reading, api_path, "not a native API version", help))
  end

  sha256 = try digests(reading, entries["sha256"], Reader.child(path, "sha256"))
  ok(Prebuilt(url: url, source: source, api: api, sha256: sha256))
end

## The URL of the file of `target`, from the template of `prebuilt` with this library, native API and source key.
def url_for(prebuilt: Prebuilt, name: String, api: String, source: String, target: String) -> String
  expand(prebuilt.url, name, api, source, target)
end

## Whether a redirect of the download of `url` may lead to `next`: the same host, or one of REDIRECT_HOSTS.
def redirect_allowed?(url: String, next: String) -> Bool
  host = NativeArtifact.host_of(next)
  host != "" and (host == NativeArtifact.host_of(url) or REDIRECT_HOSTS.include?(host))
end

## The file name of the library in a cache entry on the system of `target`: library.so, library.dylib or
## library.dll. The entry is keyed by the SHA-256 alone, so two modules that name one file share it.
def file_name(target: String) -> String = "library#{extension(target)}"

## The cache entry of the file with the SHA-256 `sha`: `<cache>/native-prebuilt/<sha>`, holding the library and its
## receipt.
def entry_of(cache_root: String, sha: String) -> String = Paths.join(Paths.join(cache_root, CACHE_FOLDER), sha)

## Whether a VM of the native API `vm_api` loads files built with `api`: the same major and a minor up to its own.
def api_loads?(api: String, vm_api: String) -> Bool
  return false if !api_version?(api) or !api_version?(vm_api)

  files = api.split(".")
  own = vm_api.split(".")
  files[0] == own[0] and files[1].to_i! <= own[1].to_i!
end

## Why a module has no prebuilt file to use on `target` with the native API `vm_api` of this binary, or "" when it
## has: `sha256` and `api` are its table's ({} with no table), and `fresh` says that its sources still give the
## table's source key. `target` is "" on a system that is none of TARGETS.
def missing_reason(sha256: Map[String, String], api: String, fresh: Bool, target: String, vm_api: String) -> String
  return "it has no prebuilt table" if sha256.size == 0

  return "this system is none of the release targets" if target == ""

  return "the table has no file for #{target}" if !sha256.has_key?(target)

  return "the files need native API #{api} and this Agentica has #{vm_api}" if !api_loads?(api, vm_api)

  return "the sources of native/ are not the ones the files were built from" if !fresh

  ""
end

## Whether `choice` names the module `name`.
def chosen?(choice: Choice, name: String) -> Bool = choice.all or choice.names.include?(name)

## The way of the module `name` under `policy`: MODE_BUILD, MODE_PREBUILT_ONLY, or "" when the policy does not name it.
def mode_of(policy: Policy, name: String) -> String
  return MODE_BUILD if chosen?(policy.build, name)

  return MODE_PREBUILT_ONLY if chosen?(policy.prebuilt_only, name)

  ""
end

## The way of the module `name` under the first of `layers` that names it ("" when none does): the command line, then
## the environment, then the manifest.
def mode_in(layers: List[Policy], name: String) -> String
  for layer in layers
    mode = mode_of(layer, name)
    return mode if mode != ""
  end

  ""
end

## The policy of the command line or the environment: `build` and `prebuilt_only` are each "" (none), "all" or module
## names joined by commas. A bad name, or a module in both, is the plain text of the error.
def layer_of(build: String, prebuilt_only: String) -> Result[Policy]
  built = try choice_text(build)
  only = try choice_text(prebuilt_only)
  return error(BOTH_HELP) if (built.all and (only.all or only.names.size > 0)) or (only.all and built.names.size > 0)

  for name in only.names
    return error("#{name}: #{BOTH_HELP}") if built.names.include?(name)
  end

  ok(Policy(build: built, prebuilt_only: only, written: build != "" or prebuilt_only != ""))
end

## The text of the layers that Settings.native_policy keeps for the bytecode cache key and the builder: one line each,
## `build=X;prebuilt_only=Y`; "" when no layer names anything.
def layers_text(layers: List[Policy]) -> String
  return "" if !layers.any? do |layer: Policy| layer.written end

  lines = layers.map do |layer: Policy|
    "build=#{choice_line(layer.build)};prebuilt_only=#{choice_line(layer.prebuilt_only)}"
  end

  lines.join("\n")
end

## The layers that `layers_text` wrote (none for "", and a line that does not read is no layer).
def layers_of(text: String) -> List[Policy]
  return [] if text == ""

  found: List[Policy] = []
  for line in text.split("\n")
    parts = line.split(";")
    if parts.size == 2 and parts[0].start_with?("build=") and parts[1].start_with?("prebuilt_only=")
      layer = layer_of(parts[0].slice(6, parts[0].length - 6), parts[1].slice(14, parts[1].length - 14))
      if layer.ok?
        found = found.push(layer.unwrap!)
      end
    end
  end

  found
end

## The module names that `policy` names, in its order, without `all`.
def names_in(policy: Policy) -> List[String] = policy.build.names.concat(policy.prebuilt_only.names)

## The text the source key covers: the format, the library, its `build` table as written and, for each file of
## native/ that the package hash covers (`files`, relative paths in bytewise order), its SHA-256 in hex (`digests`, at
## the same index).
def source_text(library: String, build: NativeBuild.Build, files: List[String], digests: List[String]) -> String
  lines = [SOURCE_FORMAT, "library #{library}"]
  lines = lines.concat(build.sources.map do |source: String| "source #{source}" end)
  lines = lines.concat(build.defines.map do |define: String| "define #{define}" end)
  lines = lines.concat(build.libs.map do |lib: String| "lib #{lib}" end)
  for index in 0...files.size
    lines = lines.push("file #{digests[index]} #{files[index]}")
  end

  lines.join("\n")
end

## The native API of the text of agentica_native.h: MAJOR.MINOR from its AN_API_MAJOR and AN_API_MINOR defines, ""
## when it lacks one.
def header_api(header: String) -> String
  major = ""
  minor = ""
  for line in header.split("\n")
    words = line.split(" ").select do |word: String| word != "" end
    if words.size == 3 and words[0] == "#define" and words[1] == "AN_API_MAJOR"
      major = words[2]
    elsif words.size == 3 and words[0] == "#define" and words[1] == "AN_API_MINOR"
      minor = words[2]
    end
  end

  return "" if major == "" or minor == ""

  "#{major}.#{minor}"
end

## The source key of the library `name` with the `build` table, from the files of native/ in the package folder `root`
## that the package hash covers, read within the limits of a fetched package. A failure is PKG-NATIVE-BUILD at
## `native.NAME.build` of the manifest `file`.
def source_of(
  workspace: Workspace.Workspace,
  root: String,
  file: String,
  name: String,
  build: NativeBuild.Build,
) -> Result[String]
  key = Reader.child(Reader.child("native", name), "build")
  paths: List[String] = []
  case PackageHash.covered_files(workspace, root)
    PackageHash.Listing.Files(found) -> paths = found.select do |path: String| PackageHash.native_path?(path) end
    PackageHash.Listing.Stopped(reason) -> return error(refused(file, key, stopped(reason)))
  end

  digests: List[String] = []
  total = 0
  for path in paths
    read = workspace.read_prefix.call(Paths.join(root, path), PackageHash.MAX_FILE_BYTES + 1)
    return error(refused(file, key, "cannot read #{path}: #{read.message}")) if !read.ok?

    total += read.unwrap!.size
    if read.unwrap!.size > PackageHash.MAX_FILE_BYTES or total > PackageHash.MAX_TOTAL_BYTES
      limits = "#{PackageHash.MAX_FILE_BYTES} bytes a file and #{PackageHash.MAX_TOTAL_BYTES} in all"
      message = "the files of native/ are over the limits of a fetched package (#{limits}), at #{path}"
      return error(refused(file, key, message))
    end

    digests = digests.push(OpenSSL.Digest.sha256_hexdigest(lf_only(read.unwrap!)))
  end

  ok(source_key(source_text(name, build, paths, digests)))
end

## The source key of a source text.
def source_key(text: String) -> String = OpenSSL.Digest.sha256_hexdigest(text.bytes).slice(0, SOURCE_LENGTH)

## Reads `[native_policy]` of the parsed manifest: `build` and `prebuilt_only`, each `"all"` or a list of module names.
## A module in both, or `"all"` in one and anything in the other, is refused at `prebuilt_only`.
def policy_of(reading: Reader.Reading, root: Map[String, Toml.Value]) -> Result[Policy]
  return ok(no_policy()) if !root.has_key?(POLICY_KEY)

  entries = try Reader.table(reading, root[POLICY_KEY], POLICY_KEY)
  try Reader.known_keys(reading, entries, POLICY_KEYS, POLICY_KEY)
  build = try choice_of(reading, entries, "build", [])
  prebuilt_only = try choice_of(reading, entries, "prebuilt_only", build.names)
  only_any = prebuilt_only.all or prebuilt_only.names.size > 0
  if (build.all and only_any) or (prebuilt_only.all and build.names.size > 0)
    here = Reader.child(POLICY_KEY, "prebuilt_only")
    return error(Reader.fail_help(reading, here, BOTH, BOTH_HELP))
  end

  ok(Policy(build: build, prebuilt_only: prebuilt_only, written: true))
end

private

# The keys of a prebuilt table and of the policy, the placeholders of a URL template and the format of the source text.
PREBUILT_KEYS = ["url", "source", "api", "sha256"]
POLICY_KEYS = ["build", "prebuilt_only"]
PLACEHOLDERS = ["name", "api", "target", "ext", "source"]
SOURCE_FORMAT = "agentica native source 1"
# The values a template is tried with: an https template stays one whatever the values are.
SAMPLE_SOURCE = "0123456789abcdef"
SAMPLE_API = "1.0"
# The failure of a module named in both lists of the policy.
BOTH = "a module both builds and does not"
BOTH_HELP = "a module either always builds or never builds: name it in one of build and prebuilt_only"

# A choice of the command line or the environment: "", "all" or names joined by commas.
def choice_text(text: String) -> Result[Choice]
  return ok(Choice(all: false, names: [])) if text == ""

  return ok(Choice(all: true, names: [])) if text == "all"

  names: List[String] = []
  for name in text.split(",")
    problem = GitSource.name_problem(name)
    return error("#{name}: #{problem}") if problem != ""

    if !names.include?(name)
      names = names.push(name)
    end
  end

  ok(Choice(all: false, names: names))
end

def choice_line(choice: Choice) -> String
  return "all" if choice.all

  choice.names.join(",")
end

# Why the URL template is not usable, or "": an https URL (or http to 127.0.0.1 or [::1]) once expanded, with
# `{target}` and only the known placeholders.
def url_problem(url: String) -> String
  names = "{name}, {api}, {target}, {ext} and {source}"
  parts = url.split("{")
  return "a } has no { before it: the placeholders are #{names}" if parts[0].include?("}")

  found_target = false
  for part in parts.drop(1)
    close = part.index_of("}")
    return "a { has no } after it: the placeholders are #{names}" if close.none?

    name = part.slice(0, close.unwrap!)
    return "{#{name}} is not a placeholder: write #{names}" if !PLACEHOLDERS.include?(name)

    after = part.slice(close.unwrap! + 1, part.length - close.unwrap! - 1)
    return "a } has no { before it: the placeholders are #{names}" if after.include?("}")

    if name == "target"
      found_target = true
    end
  end

  return "the URL names no {target}, so every target would get one file" if !found_target

  for target in TARGETS
    if !NativeArtifact.url_allowed?(expand(url, "name", SAMPLE_API, SAMPLE_SOURCE, target))
      return "the URL is not an https URL (or an http URL to 127.0.0.1 or [::1])"
    end
  end

  ""
end

def expand(url: String, name: String, api: String, source: String, target: String) -> String
  named = url.replace("{name}", name).replace("{api}", api).replace("{source}", source)
  named.replace("{ext}", extension(target)).replace("{target}", target)
end

# The file extension of a library on the system of a target.
def extension(target: String) -> String
  return ".dll" if target.start_with?("windows-")

  return ".dylib" if target.start_with?("macos-")

  ".so"
end

def source_key?(text: String) -> Bool = text.length == SOURCE_LENGTH and hex?(text)

def hex?(text: String) -> Bool = text.split("").all? do |char: String| "0123456789abcdef".include?(char) end

# MAJOR.MINOR, each one or more digits.
def api_version?(text: String) -> Bool
  parts = text.split(".")
  return false if parts.size != 2

  parts.all? do |part: String| number?(part) end
end

# One to four digits, with no leading zero.
def number?(text: String) -> Bool
  return false if text.length > 1 and text.start_with?("0")

  text.length > 0 and text.length <= 4 and text.split("").all? do |char: String| "0123456789".include?(char) end
end

# The bytes with each CRLF read as LF; bytes that are not UTF-8 text stay as they are.
def lf_only(bytes: Bytes) -> Bytes
  text = String.from_bytes(bytes)
  return bytes if !text.ok? or !text.unwrap!.include?("\r\n")

  text.unwrap!.replace("\r\n", "\n").bytes
end

def stopped(reason: PackageHash.Hashed) -> String
  case reason
    PackageHash.Hashed.Link(path) -> "#{path} in the package is a symbolic link"
    PackageHash.Hashed.Unreadable(why) -> "cannot read the package: #{why}"
    PackageHash.Hashed.Hash(_) -> "cannot read the package"
  end
end

def refused(file: String, key: String, message: String) -> String
  Failure.fail_key(file, key, "PKG-NATIVE-BUILD", message, Failure.hint("put the files of the module in native/"))
end

# `sha256 = { TARGET = "..." }`: at least one of TARGETS, each a SHA-256 in 64 lowercase hex digits.
def digests(reading: Reader.Reading, value: Toml.Value, path: String) -> Result[Map[String, String]]
  entries = try Reader.table(reading, value, path)
  if entries.size == 0
    return error(Reader.fail_help(reading, path, "no target", "write the sha256 of the file of at least one target"))
  end

  found: Map[String, String] = {}
  for target in entries.keys
    here = Reader.child(path, target)
    if !TARGETS.include?(target)
      return error(Reader.fail_help(reading, here, "not a target", "write #{TARGETS.join(", ")}"))
    end

    sha = try Reader.text(reading, entries[target], here)
    if !NativeArtifact.valid_sha?(sha)
      return error(Reader.fail_help(reading, here, "not a sha256", "the sha256 is 64 lowercase hex digits"))
    end

    found = found.put(target, sha)
  end

  ok(found)
end

# One list of the policy: "all", or a list of module names, none of them in `taken` (the names of the other list).
def choice_of(
  reading: Reader.Reading,
  entries: Map[String, Toml.Value],
  key: String,
  taken: List[String],
) -> Result[Choice]
  return ok(Choice(all: false, names: [])) if !entries.has_key?(key)

  here = Reader.child(POLICY_KEY, key)
  case entries[key]
    Toml.Value.Str(text) ->
      return ok(Choice(all: true, names: [])) if text == "all"

      help = "write \"all\" or a list of module names, such as [\"db_sqlite\"]"
      error(Reader.fail_help(reading, here, "not a list of modules", help))
    _ -> names_of(reading, entries[key], here, taken)
  end
end

def names_of(reading: Reader.Reading, value: Toml.Value, here: String, taken: List[String]) -> Result[Choice]
  items = try Reader.array(reading, value, here)
  names: List[String] = []
  for index in 0...items.size
    at = Reader.item(here, index)
    name = try Reader.text(reading, items[index], at)
    problem = GitSource.name_problem(name)
    return error(Reader.fail_help(reading, at, "not a module name", problem)) if problem != ""

    return error(Reader.fail_help(reading, at, BOTH, BOTH_HELP)) if taken.include?(name)

    if !names.include?(name)
      names = names.push(name)
    end
  end

  ok(Choice(all: false, names: names))
end

## Prebuilt native modules (docs/grammar/05b-modules.md): the `prebuilt` key of `[native.NAME]`, beside `build`, which
## names one library file per release target that the package author built from that `build`, and the project's
## `[native_policy]`, which says which modules always build from source and which never do. This holds the pure parts:
## the checks of both tables, the URL of a target, and the source key that ties the files to the code they were built
## from. A failure is the reading's code at the key path (toml_read.agc).
##
## The source key is the first 16 hex digits of the SHA-256 of `source_text`: the library, its `build` table and the
## files of native/ that the hash of the package covers, with the digest of each. The compiler, the header and the
## system are left out, so one key names the code for every target, and a manifest that only changes its `prebuilt`
## table keeps it.

import NativeArtifact from "native_artifact"
import NativeBuild from "native_build"
import GitSource from "git_source"
import Toml from "std/toml"
import Reader from "toml_read"

## The five release targets, in the order the files list them.
TARGETS = ["linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64", "windows-x86_64"]
## The length of a source key in lowercase hex digits.
SOURCE_LENGTH = 16
## The table name of the policy, which only the project's manifest may write.
POLICY_KEY = "native_policy"

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

## `[native_policy]` of the project: the modules that always build from source, and those that never build.
struct Policy
  build: Choice
  prebuilt_only: Choice
end

## The policy of a manifest without `[native_policy]`: nothing is forced.
def no_policy() -> Policy = Policy(build: Choice(all: false, names: []), prebuilt_only: Choice(all: false, names: []))

## Whether the manifest wrote a `[native_policy]` that asks anything.
def any?(policy: Policy) -> Bool
  policy.build.all or policy.build.names.size > 0 or policy.prebuilt_only.all or policy.prebuilt_only.names.size > 0
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
    help = "write the native API the files were built with, MAJOR.MINOR, as agentica native source NAME prints it"
    return error(Reader.fail_help(reading, api_path, "not a native API version", help))
  end

  sha256 = try digests(reading, entries["sha256"], Reader.child(path, "sha256"))
  ok(Prebuilt(url: url, source: source, api: api, sha256: sha256))
end

## The URL of the file of `target`, from the template of `prebuilt` with this library, native API and source key.
def url_for(prebuilt: Prebuilt, name: String, api: String, source: String, target: String) -> String
  expand(prebuilt.url, name, api, source, target)
end

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

## The source key of a source text.
def source_key(text: String) -> String = OpenSSL.Digest.sha256_hexdigest(text.bytes).slice(0, SOURCE_LENGTH)

## Reads `[native_policy]` of the parsed manifest: `build` and `prebuilt_only`, each `"all"` or a list of module names.
## A module in both, or `"all"` in one and anything in the other, is refused at `prebuilt_only`.
def policy_of(reading: Reader.Reading, root: Map[String, Toml.Value]) -> Result[Policy]
  return ok(no_policy()) if !root.has_key?(POLICY_KEY)

  entries = try Reader.table(reading, root[POLICY_KEY], POLICY_KEY)
  try Reader.known_keys(reading, entries, POLICY_KEYS, POLICY_KEY)
  build = try choice_of(reading, entries, "build")
  prebuilt_only = try choice_of(reading, entries, "prebuilt_only")
  here = Reader.child(POLICY_KEY, "prebuilt_only")
  help = "a module either always builds or never builds: name it in one of build and prebuilt_only"
  only_any = prebuilt_only.all or prebuilt_only.names.size > 0
  if (build.all and only_any) or (prebuilt_only.all and build.names.size > 0)
    return error(Reader.fail_help(reading, here, "a module both builds and does not", help))
  end

  for index in 0...prebuilt_only.names.size
    if build.names.include?(prebuilt_only.names[index])
      return error(Reader.fail_help(reading, Reader.item(here, index), "a module both builds and does not", help))
    end
  end

  ok(Policy(build: build, prebuilt_only: prebuilt_only))
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

# One to four digits.
def number?(text: String) -> Bool
  text.length > 0 and text.length <= 4 and text.split("").all? do |char: String| "0123456789".include?(char) end
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

# One list of the policy: "all", or a list of module names.
def choice_of(reading: Reader.Reading, entries: Map[String, Toml.Value], key: String) -> Result[Choice]
  none_chosen = Choice(all: false, names: [])
  return ok(none_chosen) if !entries.has_key?(key)

  here = Reader.child(POLICY_KEY, key)
  help = "write \"all\" or a list of module names, such as [\"db_sqlite\"]"
  case entries[key]
    Toml.Value.Str(text) ->
      return ok(Choice(all: true, names: [])) if text == "all"

      return error(Reader.fail_help(reading, here, "not a list of modules", help))
    _ -> none_chosen = none_chosen
  end

  items = try Reader.array(reading, entries[key], here)
  names: List[String] = []
  for index in 0...items.size
    at = Reader.item(here, index)
    name = try Reader.text(reading, items[index], at)
    problem = GitSource.name_problem(name)
    return error(Reader.fail_help(reading, at, "not a module name", problem)) if problem != ""

    names = names.push(name)
  end

  ok(Choice(all: false, names: names))
end

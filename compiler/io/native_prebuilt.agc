## Downloads the prebuilt native modules of the host target for `install`, `add` and `update`
## (docs/grammar/05b-modules.md), over the rules of packages/native_prebuilt.agc. A run never downloads. For the
## project and every package of the lock, fetched ones too, each module with a `prebuilt` file for this target goes
## into the package cache as `native-prebuilt/<sha256>/`, which holds the library and a `receipt` with its SHA-256, so
## a file that two packages name is stored once. A module is skipped, and builds from source on first use, when the
## policy builds it, the table has no file for this target, the files need a newer native API than this binary, or the
## package's sources no longer hash to the table's source key.
##
## The download is the one of io/native_artifact.agc: https (or http to a loopback literal), one deadline, at most
## 64 MiB, and redirects only to the host of the URL or to GitHub's release asset hosts. A file that is not the one
## its sha256 names is PKG-HASH-MISMATCH; any other failure of the download is a PKG-FETCH warning, and the module
## builds from source. For a module that the policy makes prebuilt-only, both are errors. Under --deny-net or
## --sandbox nothing is downloaded: a prebuilt-only module that is not in the cache is PKG-NATIVE-DENIED.
##
## An entry is made in a new private folder and renamed into place in one no-replace step, so concurrent installs keep
## the first. The library is code that a run loads: an entry or folder that is not private to this user, or a library
## that does not match its receipt, is PKG-NATIVE-BUILD (cache_files.agc, private_kind).

import Diag from "../diagnostics/diagnostic"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import Workspace from "../modules/workspace"
import Lock from "../packages/lock"
import Manifest from "../packages/manifest"
import Members from "../packages/members"
import NativeArtifact from "../packages/native_artifact"
import NativePrebuilt from "../packages/native_prebuilt"
import PackageCache from "../packages/package_cache"
import Project from "../packages/project"
import Reader from "../packages/toml_read"
import CacheFiles from "cache_files"
import Engine from "native_artifact"

## How a pass may download: `net_denied` under --deny-net or --sandbox, and `warned`, which gets each packed warning
## (app/ prints it in the form the options ask for).
struct Fetching
  net_denied: Bool
  warned: Fn[String, Void]
end

## What the prebuilt cache holds for a module at its first use: the verified library, none (why, and whether `install`
## would download one), or the packed PKG-NATIVE-BUILD of an entry that cannot be trusted.
enum Lookup
  Found(String)
  Missing(String, Bool)
  Broken(String)
end

## The native API of the header this binary carries, MAJOR.MINOR ("" when it carries none): what a build compiles
## against, and the newest a module may need.
def native_api() -> String
  case FrontEnd.std_source(HEADER)
    ok(text) -> NativePrebuilt.header_api(text)
    error(_) -> ""
  end
end

## The prebuilt library of the module of `request` for this target, from the cache alone: the receipt and the SHA-256
## of the file are checked again, and an entry or folder that is not private to the user is Broken.
def lookup(request: Workspace.BuildRequest) -> Lookup
  target = host_target()
  sha256 = request.prebuilt_sha256
  reason = NativePrebuilt.missing_reason(sha256, request.prebuilt_api, request.prebuilt_fresh, target, native_api())
  return Lookup.Missing(reason, false) if reason != ""

  return Lookup.Missing("there is no package cache: HOME is not set", false) if request.cache_root == ""

  sha = sha256[target]
  entry = NativePrebuilt.entry_of(request.cache_root, sha)
  return Lookup.Missing("its prebuilt file was not downloaded", true) if !File.lstat(entry, FILE_TIMEOUT_MS).ok?

  key = Reader.child(Reader.child("native", request.library), "prebuilt")
  context = NativeArtifact.Context(file: request.file, key: key)
  user = own_user(context)
  return Lookup.Broken(user.message) if !user.ok?

  base = Paths.join(request.cache_root, NativePrebuilt.CACHE_FOLDER)
  if !CacheFiles.private_kind(base, "directory", user.unwrap!).ok?
    message = "the prebuilt cache is not private to this user"
    return Lookup.Broken(cache_failure(context, message, "remove the folder #{base}"))
  end

  library_file = NativePrebuilt.file_name(target)
  checked = verified(entry, library_file, sha, user.unwrap!, context)
  return Lookup.Broken(checked.message) if !checked.ok?

  Lookup.Found(Paths.join(entry, library_file))
end

## The release target of this binary, one of NativePrebuilt.TARGETS, or "" on any other system.
def host_target() -> String
  case FrontEnd.std_source(TARGET_SOURCE)
    ok(text) ->
      return text if NativePrebuilt.TARGETS.include?(text)

      ""
    error(_) -> ""
  end
end

## Fetches the prebuilt files of this target for the project of `manifest` (its workspace `members`) and for each of
## `packages`, whose files are in the package cache when they are fetched. The lines say `fetched prebuilt NAME` or
## `prebuilt NAME in the cache`; the first error stops the pass.
def fetch_all(
  settings: Env.Settings,
  manifest: Manifest.Manifest,
  members: Members.Members,
  packages: List[Lock.Locked],
  fetching: Fetching,
) -> Result[List[String]]
  modules = try modules_of(settings, manifest, members, packages)
  layers = NativePrebuilt.layers_of(settings.native_policy).push(manifest.policy)
  warn_unknown(manifest.file, layers, modules, fetching)
  wanted = modules.select do |module| module.library.prebuilt.some? end
  return ok([]) if wanted.size == 0

  target = host_target()
  if target == ""
    reason = "this system is none of the release targets"
    only = wanted.select do |module|
      NativePrebuilt.mode_in(layers, module.library.name) == NativePrebuilt.MODE_PREBUILT_ONLY
    end

    return ok(only.map do |module| unavailable(module.library.name, reason) end)
  end

  cache = PackageCache.root(settings.env)
  if cache == ""
    message = "there is no place for the prebuilt native modules: HOME is not set"
    return error(Failure.fail_file(manifest.file, "PKG-FETCH", message, Failure.hint("set HOME or XDG_CACHE_HOME")))
  end

  pass = Pass(
    workspace: settings.workspace,
    cache: cache,
    target: target,
    api: native_api(),
    layers: layers,
    fetching: fetching,
  )

  lines: List[String] = []
  for module in wanted
    line = try fetch_one(pass, module)
    if line != ""
      lines = lines.push(line)
    end
  end

  ok(lines)
end

private

# The std/ sources that hold the release target of the binary (vm/agentica.c) and its native header.
TARGET_SOURCE = "internal/native/target"
HEADER = "internal/native/agentica_native.h"
DOWNLOAD_FOLDER = "download"
# The deadline of one file, and of each step of the cache.
FETCH_TIMEOUT_MS = 300_000
FILE_TIMEOUT_MS = 30_000
TEMP_TRIES = 5

# What every module of a pass shares.
struct Pass
  workspace: Workspace.Workspace
  cache: String
  target: String
  api: String
  layers: List[NativePrebuilt.Policy]
  fetching: Fetching
end

# A module that builds: the folder of its package, the manifest that declares it and the library.
struct Module
  root: String
  file: String
  library: Manifest.NativeLibrary
end

# The modules with a `build` table, of the project first and then of each package in the order of `packages`. A
# package whose manifest is not there has none.
def modules_of(
  settings: Env.Settings,
  manifest: Manifest.Manifest,
  members: Members.Members,
  packages: List[Lock.Locked],
) -> Result[List[Module]]
  dir = Paths.directory_of(manifest.file)
  found = buildable(dir, manifest)
  for locked in packages
    folder = Project.folder_of(dir, members, locked)
    if !Lock.in_place?(locked)
      cache = PackageCache.root(settings.env)
      next if cache == ""

      folder = PackageCache.folder(cache, locked.source, locked.commit)
    end

    file = Paths.join(folder, Project.MANIFEST_FILE)
    if settings.workspace.file_exists.call(file)
      declared = try Manifest.read(settings.workspace, file)
      found = found.concat(buildable(folder, declared))
    end
  end

  ok(found)
end

def buildable(root: String, manifest: Manifest.Manifest) -> List[Module]
  usable = manifest.natives.select do |library| library.build.some? end
  usable.map do |library| Module(root: root, file: manifest.file, library: library) end
end

# A warning for each module that a layer of the policy names and no package has, at the manifest's key for its own
# policy and at the manifest file for the command line and the environment (the last layer is the manifest's).
def warn_unknown(file: String, layers: List[NativePrebuilt.Policy], modules: List[Module], fetching: Fetching) -> Void
  known = modules.map do |module| module.library.name end
  for index in 0...layers.size
    layer = layers[index]
    unknown = NativePrebuilt.names_in(layer).select do |name: String| !known.include?(name) end
    for name in unknown
      message = "the native policy names #{name}, which is no native module of the project or its packages"
      help = Failure.hint("check the name, or remove it from the policy")
      if index == layers.size - 1
        key = Reader.child(NativePrebuilt.POLICY_KEY, "build")
        if !layer.build.names.include?(name)
          key = Reader.child(NativePrebuilt.POLICY_KEY, "prebuilt_only")
        end

        fetching.warned.call(Failure.fail_key(file, key, "PKG-NATIVE-MISSING", message, help))
      else
        fetching.warned.call(Failure.fail_file(file, "PKG-NATIVE-MISSING", message, help))
      end
    end
  end
end

# The line of one module ("" when it is skipped or only warned about), or the error that stops the pass.
def fetch_one(pass: Pass, module: Module) -> Result[String]
  library = module.library
  name = library.name
  prebuilt = library.prebuilt.unwrap!
  mode = NativePrebuilt.mode_in(pass.layers, name)
  return ok("") if mode == NativePrebuilt.MODE_BUILD

  only = mode == NativePrebuilt.MODE_PREBUILT_ONLY
  skipped = skip_reason(pass, module)
  if skipped != ""
    return ok("") if !only

    return ok(unavailable(name, skipped))
  end

  key = Reader.child(Reader.child("native", name), "prebuilt")
  context = NativeArtifact.Context(file: module.file, key: key)
  sha = prebuilt.sha256[pass.target]
  user = try own_user(context)
  base = Paths.join(pass.cache, NativePrebuilt.CACHE_FOLDER)
  try private_base(pass.cache, base, user, context)
  CacheFiles.sweep_folders(base)
  entry = NativePrebuilt.entry_of(pass.cache, sha)
  library_file = NativePrebuilt.file_name(pass.target)
  if File.lstat(entry, FILE_TIMEOUT_MS).ok?
    try verified(entry, library_file, sha, user, context)
    return ok("prebuilt #{name} in the cache")
  end

  if pass.fetching.net_denied
    return ok("") if !only

    message = "prebuilt #{name} cannot be downloaded under --deny-net or --sandbox"
    help = Failure.hint("run the command without them, or take #{name} out of native_policy.prebuilt_only")
    return error(Failure.fail_key(module.file, key, "PKG-NATIVE-DENIED", message, help))
  end

  url = NativePrebuilt.url_for(prebuilt, name, prebuilt.api, prebuilt.source, pass.target)
  case download_entry(base, entry, library_file, url, sha, pass.target, user, context)
    ok(_) -> ok("fetched prebuilt #{name}")
    error(e) ->
      failure = Failure.unpack_failure(e.message)
      return error(e.message) if failure.diagnostic.code != "PKG-FETCH" or only

      message = "prebuilt #{name} not fetched: #{failure.diagnostic.message}; it builds from source instead"
      warning = Failure.fail_key(module.file, failure.key_path, "PKG-FETCH", message, Diag.Help.NoHelp)
      pass.fetching.warned.call(warning)
      ok("")
  end
end

# Why the module has no prebuilt file for this pass, or "" (NativePrebuilt.missing_reason).
def skip_reason(pass: Pass, module: Module) -> String
  library = module.library
  prebuilt = library.prebuilt.unwrap!
  current = NativePrebuilt.source_of(pass.workspace, module.root, module.file, library.name, library.build.unwrap!)
  fresh = current.ok? and current.unwrap! == prebuilt.source
  NativePrebuilt.missing_reason(prebuilt.sha256, prebuilt.api, fresh, pass.target, pass.api)
end

# The line of a prebuilt-only module that has no file to download.
def unavailable(name: String, reason: String) -> String
  "prebuilt #{name} not available: #{reason}; it is prebuilt-only, so its first use fails"
end

# Downloads the file into a new private folder beside the entries, checks it and renames the folder into place. A
# concurrent install that renamed first is kept (and verified), and this folder is removed.
def download_entry(
  base: String,
  entry: String,
  library_file: String,
  url: String,
  sha: String,
  target: String,
  user: Int,
  context: NativeArtifact.Context,
) -> Result[Void]
  temporary = try make_temp(base, context)
  made = fill(temporary, library_file, url, sha, target, context)
  if !made.ok?
    _ = Path.remove(temporary, FILE_TIMEOUT_MS)
    return made
  end

  if !Path.rename(temporary, entry, FILE_TIMEOUT_MS).ok?
    _ = Path.remove(temporary, FILE_TIMEOUT_MS)
    try verified(entry, library_file, sha, user, context)
  end

  ok()
end

# The library and its receipt in `folder`; the bodies of the redirects stay in a folder of their own, removed after.
def fill(
  folder: String,
  library_file: String,
  url: String,
  sha: String,
  target: String,
  context: NativeArtifact.Context,
) -> Result[Void]
  hops = Paths.join(folder, DOWNLOAD_FOLDER)
  if !Dir.mkdir_private(hops, FILE_TIMEOUT_MS).ok?
    return error(cache_failure(context, "cannot write the prebuilt cache", ""))
  end

  deadline = Time.monotonic_ms() + FETCH_TIMEOUT_MS
  allowed = ->(next_url) { NativePrebuilt.redirect_allowed?(url, next_url) }
  dest = try Engine.download(url, hops, NativePrebuilt.FILE_MAX_BYTES, deadline, context, allowed)
  digest = File.sha256(dest, FILE_TIMEOUT_MS)
  return error(cache_failure(context, "cannot read the downloaded file", "")) if !digest.ok?

  if OpenSSL.Digest.hexencode(digest.unwrap!) != sha
    key = Reader.child(Reader.child(context.key, "sha256"), target)
    message = "the downloaded file is not the one its sha256 names"
    help = Failure.hint("the package must publish the file it names, or name the file it publishes")
    return error(Failure.fail_key(context.file, key, "PKG-HASH-MISMATCH", message, help))
  end

  library = Paths.join(folder, library_file)
  if !Path.rename(dest, library, FILE_TIMEOUT_MS).ok? or !Path.remove(hops, FILE_TIMEOUT_MS).ok?
    return error(cache_failure(context, "cannot write the prebuilt cache", ""))
  end

  if !CacheFiles.write_private(Paths.join(folder, CacheFiles.RECEIPT), sha.bytes).ok?
    return error(cache_failure(context, "cannot write the prebuilt cache", ""))
  end

  ok()
end

# The library of an entry that exists: a regular file in a folder, both private to this user, that matches its
# receipt and the sha256 of the table.
def verified(
  entry: String,
  library_file: String,
  sha: String,
  user: Int,
  context: NativeArtifact.Context,
) -> Result[Void]
  library = Paths.join(entry, library_file)
  help = "remove the folder #{entry} to download it again"
  problem = CacheFiles.entry_problem(entry, library, user, true)
  if problem == CacheFiles.ENTRY_NOT_PRIVATE
    return error(cache_failure(context, "the prebuilt cache entry is not private to this user", help))
  end

  receipt = File.read_text(Paths.join(entry, CacheFiles.RECEIPT), FILE_TIMEOUT_MS)
  if problem != "" or !receipt.ok? or receipt.unwrap!.strip != sha
    return error(cache_failure(context, "the prebuilt cache entry is not the one its receipt names", help))
  end

  ok()
end

def own_user(context: NativeArtifact.Context) -> Result[Int]
  case CacheFiles.own_user()
    ok(user) -> ok(user)
    error(message) -> error(cache_failure(context, "cannot use the prebuilt cache: #{message}", ""))
  end
end

# Makes the folders of the package cache and the `native-prebuilt` folder private to this user, or checks it.
def private_base(cache: String, base: String, user: Int, context: NativeArtifact.Context) -> Result[Void]
  make_folders(cache)
  made = CacheFiles.private_folder(base, user)
  if !made.ok?
    return error(cache_failure(context, "cannot use the prebuilt cache: #{made.message}", "remove the folder #{base}"))
  end

  ok()
end

# The folder and those above it that are missing, with the default mode; a failure shows when the folder is used.
def make_folders(path: String) -> Void
  return if path == "" or File.lstat(path, FILE_TIMEOUT_MS).ok?

  above = Paths.directory_of(path)
  if above != path
    make_folders(above)
  end

  _ = Dir.mkdir(path, FILE_TIMEOUT_MS)
end

# A new private folder in `base` that only this download uses.
def make_temp(base: String, context: NativeArtifact.Context) -> Result[String]
  failure = "no free name"
  for attempt in 0...TEMP_TRIES
    name = Paths.join(base, ".tmp-#{System.pid()}-#{attempt}-#{Random.int(0, 999999999)}")
    case Dir.mkdir_private(name, FILE_TIMEOUT_MS)
      ok(_) -> return ok(name)
      error(message) -> failure = "#{message}"
    end
  end

  error(cache_failure(context, "cannot make a folder in the prebuilt cache: #{failure}", ""))
end

def cache_failure(context: NativeArtifact.Context, message: String, help: String) -> String
  return Failure.fail_key(context.file, context.key, "PKG-NATIVE-BUILD", message, Diag.Help.NoHelp) if help == ""

  Failure.fail_key(context.file, context.key, "PKG-NATIVE-BUILD", message, Failure.hint(help))
end

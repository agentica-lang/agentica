## The download and member-cache engine for native artifacts (docs/grammar/05b-modules.md, docs/future/45-packages.md
## 45.10): `fetch` and `cached` over the data rules of packages/native_artifact.agc. `fetch` returns the verified local
## path of the selected member, downloading the archive once per SHA-256 and extracting each member into its own
## immutable object; `cached` answers from the cache alone and never touches the network. Every failure is a packed
## failure at the caller's file and key (link_failure.agc, fail_key): precise key paths, generic messages that never
## echo URLs, queries or secrets. Redirects stay in this module: at most five hops of 301/302/303/307/308 with exactly
## one Location each, relative targets resolved against the current URL, no https downgrade, http only to a loopback
## literal, one global deadline and 256 MiB of bodies across all hops. The archive hash is checked before anything is
## read from it; only plain, gzipped TAR and ZIP archives are supported, and a member object (payload plus receipt)
## is published by one no-replace rename, so concurrent publishers never overwrite each other.

import Archive from "std/archive"
import HTTP from "std/http"
import Diag from "../diagnostics/diagnostic"
import Paths from "../modules/import_path"
import Env from "../modules/link_env"
import Failure from "../modules/link_failure"
import PackageCache from "../packages/package_cache"
import NativeArtifact from "../packages/native_artifact"
import Reader from "../packages/toml_read"

# Tries for a fresh private name, as in package_fetch.agc.
TEMP_TRIES = 5

# What the cache holds for one member: its verified payload path, nothing yet, or a packed failure for corrupt data.
enum Probe
  Present(String)
  Missing
  Broken(String)
end

# What the cache holds for one archive: ready to extract, nothing yet, or a packed failure for corrupt data.
enum ArchiveSeen
  Ready
  Absent
  Broken(String)
end

## The folder of the package cache, or the failure for `file` when the environment leaves no place for it.
export def cache_root(env: Env.Env, file: String) -> Result[String]
  cache = PackageCache.root(env)
  if cache == ""
    message = "there is no place for the native artifact cache: HOME is not set"
    return error(Failure.fail_file(file, "PKG-FETCH", message, Failure.hint("set HOME or XDG_CACHE_HOME")))
  end
  return ok(cache)
end

## The verified local path of the selected member: the cache hit when it is valid, else the archive (downloaded and
## hashed first when missing) with the member extracted from it into its own object. Concurrent publishers of one
## archive or one member keep the winner after verifying it; nothing cached is ever overwritten.
export def fetch(
  cache_root: String,
  source: NativeArtifact.Source,
  context: NativeArtifact.Context,
  timeout_ms: Int,
) -> Result[String]
  deadline = try checked_deadline(timeout_ms, context)
  root = try checked_root(cache_root, context)
  sha = try checked_sha(source.sha256, context)
  canonical = try checked_member(source.member, context)
  url = try checked_url(source.url, context)
  digest = NativeArtifact.member_digest_hex(canonical)
  case probe_member(root, sha, canonical, digest, deadline, context)
    Probe.Present(path) -> return ok(path)
    Probe.Broken(packed) -> return error(packed)
    Probe.Missing ->
      case archive_state(NativeArtifact.archive_path(root, sha), sha, deadline, context)
        ArchiveSeen.Ready -> return publish_member(root, sha, canonical, digest, deadline, context)
        ArchiveSeen.Absent ->
          try download_archive(root, sha, url, deadline, context)
          return publish_member(root, sha, canonical, digest, deadline, context)
        ArchiveSeen.Broken(packed) -> return error(packed)
      end
  end
end

## The verified local path of the selected member from the cache alone, without any network use: a valid member
## object, or a member extracted from a valid cached archive. A corrupt receipt, member or archive
## is PKG-HASH-MISMATCH;
## nothing usable is PKG-NATIVE-MISSING.
export def cached(
  cache_root: String,
  sha: String,
  member: String,
  context: NativeArtifact.Context,
  timeout_ms: Int,
) -> Result[String]
  deadline = try checked_deadline(timeout_ms, context)
  root = try checked_root(cache_root, context)
  valid = try checked_sha(sha, context)
  canonical = try checked_member(member, context)
  digest = NativeArtifact.member_digest_hex(canonical)
  case probe_member(root, valid, canonical, digest, deadline, context)
    Probe.Present(path) -> return ok(path)
    Probe.Broken(packed) -> return error(packed)
    Probe.Missing ->
      case archive_state(NativeArtifact.archive_path(root, valid), valid, deadline, context)
        ArchiveSeen.Ready -> return publish_member(root, valid, canonical, digest, deadline, context)
        ArchiveSeen.Absent ->
          hint = "fetch the archive first"
          return error(fail(context, "PKG-NATIVE-MISSING", "member", "the cache holds no file for the member", hint))
        ArchiveSeen.Broken(packed) -> return error(packed)
      end
  end
end

def fail(context: NativeArtifact.Context, code: String, key: String, message: String, help: String) -> String
  path = context.key
  if key != ""
    path = Reader.child(context.key, key)
  end
  if help == ""
    return Failure.fail_key(context.file, path, code, message, Diag.Help.NoHelp)
  end
  return Failure.fail_key(context.file, path, code, message, Failure.hint(help))
end

def checked_deadline(timeout_ms: Int, context: NativeArtifact.Context) -> Result[Int]
  if timeout_ms <= 0 or timeout_ms > NativeArtifact.MAX_TIMEOUT_MS
    return error(fail(context, "PKG-FETCH", "", "the timeout must be 1..86400000 milliseconds", ""))
  end
  now = Time.monotonic_ms()
  if now > NativeArtifact.MAX_CLOCK - timeout_ms
    return error(fail(context, "PKG-FETCH", "", "the clock is too far ahead for the timeout", ""))
  end
  return ok(now + timeout_ms)
end

def checked_root(cache_root: String, context: NativeArtifact.Context) -> Result[String]
  if cache_root == ""
    message = "there is no place for the native artifact cache"
    return error(fail(context, "PKG-FETCH", "", message, "set HOME or XDG_CACHE_HOME"))
  end
  return ok(cache_root)
end

def checked_sha(sha: String, context: NativeArtifact.Context) -> Result[String]
  if !NativeArtifact.valid_sha?(sha)
    message = "the sha256 is not 64 lowercase hex digits"
    return error(fail(context, "PKG-HASH-MISMATCH", "sha256", message, "write the 64 digits of the SHA-256"))
  end
  return ok(sha)
end

def checked_member(member: String, context: NativeArtifact.Context) -> Result[String]
  case NativeArtifact.canonical_member(member)
    ok(canonical) -> return ok(canonical)
    error(_) ->
      message = "the member is not a safe relative path"
      return error(fail(context, "PKG-FETCH", "member", message, "name a file of the archive"))
  end
end

def checked_url(url: String, context: NativeArtifact.Context) -> Result[String]
  if !NativeArtifact.url_allowed?(url)
    message = "the url is not an https URL (or an http URL to 127.0.0.1 or [::1])"
    return error(fail(context, "PKG-FETCH", "url", message, ""))
  end
  return ok(url)
end

def time_left(deadline: Int, context: NativeArtifact.Context) -> Result[Int]
  left = deadline - Time.monotonic_ms()
  if left <= 0
    return error(fail(context, "PKG-FETCH", "", "the operation timed out", ""))
  end
  return ok(left)
end

def is_dir?(path: String, ms: Int) -> Bool
  case File.stat(path, ms)
    ok(info) -> return info.kind == "directory"
    error(_) -> return false
  end
end

def probe_member(
  root: String,
  sha: String,
  canonical: String,
  digest: String,
  deadline: Int,
  context: NativeArtifact.Context,
) -> Probe
  left = deadline - Time.monotonic_ms()
  if left <= 0
    return Probe.Broken(fail(context, "PKG-FETCH", "", "the operation timed out", ""))
  end
  payload = NativeArtifact.payload_path(root, sha, digest, canonical)
  receipt = NativeArtifact.receipt_path(root, sha, digest)
  if !is_dir?(NativeArtifact.member_dir(root, sha, digest), left)
    return Probe.Missing
  end
  left = deadline - Time.monotonic_ms()
  if left <= 0
    return Probe.Broken(fail(context, "PKG-FETCH", "", "the operation timed out", ""))
  end
  case File.read_text(receipt, left)
    ok(text) ->
      left = deadline - Time.monotonic_ms()
      if left <= 0
        return Probe.Broken(fail(context, "PKG-FETCH", "", "the operation timed out", ""))
      end
      case File.sha256(payload, left)
        ok(found) ->
          if text.trim == NativeArtifact.hex_of(found)
            return Probe.Present(payload)
          end
          message = "the cached file is not the one its receipt names"
          return Probe.Broken(fail(context, "PKG-HASH-MISMATCH", "member", message, ""))
        error(_) ->
          message = "the cached file cannot be read"
          return Probe.Broken(fail(context, "PKG-HASH-MISMATCH", "member", message, ""))
      end
    error(_) ->
      message = "the cached receipt cannot be read"
      return Probe.Broken(fail(context, "PKG-HASH-MISMATCH", "member", message, ""))
  end
end

def archive_state(
  archive: String,
  sha: String,
  deadline: Int,
  context: NativeArtifact.Context,
) -> ArchiveSeen
  left = deadline - Time.monotonic_ms()
  if left <= 0
    return ArchiveSeen.Broken(fail(context, "PKG-FETCH", "", "the operation timed out", ""))
  end
  case File.stat(archive, left)
    ok(info) ->
      if info.kind != "file"
        message = "the cached archive is not a regular file"
        return ArchiveSeen.Broken(fail(context, "PKG-HASH-MISMATCH", "sha256", message, ""))
      end
      left = deadline - Time.monotonic_ms()
      if left <= 0
        return ArchiveSeen.Broken(fail(context, "PKG-FETCH", "", "the operation timed out", ""))
      end
      case File.sha256(archive, left)
        ok(found) ->
          if NativeArtifact.hex_of(found) == sha
            return ArchiveSeen.Ready
          end
          message = "the cached archive is not the one its sha256 names"
          return ArchiveSeen.Broken(fail(context, "PKG-HASH-MISMATCH", "sha256", message, ""))
        error(_) ->
          message = "the cached archive cannot be read"
          return ArchiveSeen.Broken(fail(context, "PKG-FETCH", "sha256", message, ""))
      end
    error(_) -> return ArchiveSeen.Absent
  end
end

def open_pool(deadline: Int, context: NativeArtifact.Context) -> Result[HttpClient]
  left = try time_left(deadline, context)
  options = HttpClientOptions(
    timeout_ms: left,
    idle_timeout_ms: 30000,
    max_connections: 1,
    max_body_bytes: 1048576,
    ca_file: "",
  )
  case HTTP.client(options)
    ok(pool) -> return ok(pool)
    error(_) -> return error(fail(context, "PKG-FETCH", "url", "cannot open the download client", ""))
  end
end

# Downloads the archive at `url` with at most five redirect hops, hashes the final bytes and publishes them as the
# archive of `sha`. Bodies of every hop count against 256 MiB; each hop writes a fresh private file that is kept on
# failure. A concurrent winner is verified and kept, never replaced.
def download_archive(
  root: String,
  sha: String,
  url: String,
  deadline: Int,
  context: NativeArtifact.Context,
) -> Result[String]
  pool = try open_pool(deadline, context)
  base = NativeArtifact.native_base(root)
  try make_parents(base, deadline, context)
  current = url
  consumed = 0
  redirects = 0
  seen: Map[String, Bool] = {}
  seen = seen.put(url, true)
  while true
    left = deadline - Time.monotonic_ms()
    if left <= 0
      HTTP.close_client(pool)
      return error(fail(context, "PKG-FETCH", "", "the operation timed out", ""))
    end
    budgeted = NativeArtifact.hop_budget(consumed, NativeArtifact.TOTAL_BODY_BYTES)
    if !budgeted.ok?
      HTTP.close_client(pool)
      return error(fail(context, "PKG-FETCH", "url", "the download is larger than 256 MiB", ""))
    end
    remaining = budgeted.unwrap!
    dest = Paths.join(base, ".dl-#{System.pid()}-#{Random.int(0, 999999999)}-#{redirects}")
    options = HTTP.DownloadOptions(timeout_ms: left, max_total_bytes: remaining)
    case HTTP.download(pool, current, dest, options)
      error(_) ->
        HTTP.close_client(pool)
        return error(fail(context, "PKG-FETCH", "url", "cannot download the file", ""))
      ok(got) ->
        consumed = consumed + got.bytes_written
        if NativeArtifact.redirect_status?(got.status)
          case follow_redirect(current, got.headers, seen, redirects, context)
            ok(next_url) ->
              seen = seen.put(next_url, true)
              current = next_url
              redirects = redirects + 1
            error(packed) ->
              HTTP.close_client(pool)
              return error(packed)
          end
        else
          if got.status != 200
            HTTP.close_client(pool)
            message = "the server answered with status #{got.status}"
            return error(fail(context, "PKG-FETCH", "url", message, ""))
          end
          case File.sha256(dest, deadline - Time.monotonic_ms())
            ok(found) ->
              if NativeArtifact.hex_of(found) != sha
                HTTP.close_client(pool)
                message = "the file is not the one its sha256 names"
                return error(fail(context, "PKG-HASH-MISMATCH", "sha256", message, ""))
              end
              placed = publish_file(dest, NativeArtifact.archive_path(root, sha), sha, deadline, context)
              HTTP.close_client(pool)
              return placed
            error(_) ->
              HTTP.close_client(pool)
              return error(fail(context, "PKG-FETCH", "sha256", "cannot hash the download", ""))
          end
        end
    end
  end
  HTTP.close_client(pool)
  return error(fail(context, "PKG-FETCH", "url", "cannot download the file", ""))
end

def follow_redirect(
  current: String,
  headers: List[Header],
  seen: Map[String, Bool],
  redirects: Int,
  context: NativeArtifact.Context,
) -> Result[String]
  locations = HTTP.header_values(headers, "location")
  if locations.size != 1
    return error(fail(context, "PKG-FETCH", "url", "the redirect holds no single location", ""))
  end
  next_url = ""
  case NativeArtifact.resolve_location(current, locations[0])
    ok(found) -> next_url = found
    error(_) -> return error(fail(context, "PKG-FETCH", "url", "the redirect location is not usable", ""))
  end
  if NativeArtifact.downgrade?(current, next_url)
    return error(fail(context, "PKG-FETCH", "url", "the redirect leaves https for http", ""))
  end
  if !NativeArtifact.url_allowed?(next_url)
    return error(fail(context, "PKG-FETCH", "url", "the redirect target is not an allowed URL", ""))
  end
  if seen.has_key?(next_url)
    return error(fail(context, "PKG-FETCH", "url", "the redirects loop", ""))
  end
  if redirects >= NativeArtifact.MAX_REDIRECTS
    return error(fail(context, "PKG-FETCH", "url", "too many redirects", ""))
  end
  return ok(next_url)
end

# Moves the verified file at `tmp` to `target`, which must not exist yet. A concurrent winner is hashed and kept when
# it names `sha`; a file that names anything else is PKG-HASH-MISMATCH, never replaced.
def publish_file(
  tmp: String,
  target: String,
  sha: String,
  deadline: Int,
  context: NativeArtifact.Context,
) -> Result[String]
  try make_parents(Paths.directory_of(target), deadline, context)
  left = try time_left(deadline, context)
  case Path.rename(tmp, target, left)
    ok(_) -> return ok(target)
    error(_) ->
      left = deadline - Time.monotonic_ms()
      if left <= 0
        return error(fail(context, "PKG-FETCH", "", "the operation timed out", ""))
      end
      case File.sha256(target, left)
        ok(found) ->
          if NativeArtifact.hex_of(found) == sha
            return ok(target)
          end
          message = "the cached archive is not the one its sha256 names"
          return error(fail(context, "PKG-HASH-MISMATCH", "sha256", message, ""))
        error(_) ->
          message = "the cached archive cannot be read"
          return error(fail(context, "PKG-FETCH", "sha256", message, ""))
      end
  end
end

# Extracts the member from a valid cached archive into its own object: a private temporary folder holding
# `payload/<member>` and `receipt`, renamed into place in one no-replace step. A concurrent winner is verified and
# kept; a file the archive lacks is PKG-NATIVE-MISSING, anything else unreadable about it PKG-NATIVE-ARCHIVE.
def publish_member(
  root: String,
  sha: String,
  canonical: String,
  digest: String,
  deadline: Int,
  context: NativeArtifact.Context,
) -> Result[String]
  archive = NativeArtifact.archive_path(root, sha)
  left = try time_left(deadline, context)
  case File.sha256(archive, left)
    ok(found) ->
      if NativeArtifact.hex_of(found) != sha
        message = "the cached archive is not the one its sha256 names"
        return error(fail(context, "PKG-HASH-MISMATCH", "sha256", message, ""))
      end
    error(_) -> return error(fail(context, "PKG-FETCH", "sha256", "the cached archive cannot be read", ""))
  end
  parent = Paths.join(Paths.join(NativeArtifact.native_base(root), sha), "m")
  try make_parents(parent, deadline, context)
  tmp = try make_temp(parent, deadline, context)
  dest = Paths.join(tmp, "payload")
  left = try time_left(deadline, context)
  options = Archive.Options(timeout_ms: left, max_output_bytes: NativeArtifact.MEMBER_MAX_BYTES)
  extracted = extract_member(archive, canonical, dest, options, deadline)
  if !extracted.ok?
    message = Result.message(extracted)
    if String.contains?(message, "member not found")
      hint = "name a file the archive holds"
      return error(fail(context, "PKG-NATIVE-MISSING", "member", "the archive holds no file for the member", hint))
    end
    if String.contains?(message, "timed out")
      return error(fail(context, "PKG-FETCH", "", "the operation timed out", ""))
    end
    help = "only plain, gzipped TAR and ZIP archives are supported"
    return error(fail(context, "PKG-NATIVE-ARCHIVE", "member", "the file is not a supported archive", help))
  end
  payload = Paths.join(dest, canonical)
  left = try time_left(deadline, context)
  found = File.sha256(payload, left)
  if !found.ok?
    return error(fail(context, "PKG-NATIVE-ARCHIVE", "member", "the file is not a supported archive", ""))
  end
  receipt = Paths.join(tmp, "receipt")
  left = try time_left(deadline, context)
  wrote = File.write_text(receipt, NativeArtifact.hex_of(found.unwrap!), left)
  if !wrote.ok?
    return error(fail(context, "PKG-FETCH", "member", "the cache cannot be written", ""))
  end
  target = NativeArtifact.member_dir(root, sha, digest)
  left = try time_left(deadline, context)
  case Path.rename(tmp, target, left)
    ok(_) -> return ok(Paths.join(Paths.join(target, "payload"), canonical))
    error(_) ->
      case probe_member(root, sha, canonical, digest, deadline, context)
        Probe.Present(path) -> return ok(path)
        Probe.Missing -> return error(fail(context, "PKG-FETCH", "member", "the cache cannot be written", ""))
        Probe.Broken(packed) -> return error(packed)
      end
  end
end

# Extracts one member from a validated archive, routed by its bounded file magic: a ZIP local header goes to
# `extract_zip`, anything else keeps the TAR and gzip path. The URL and its suffix never decide the format. The
# extractor timeout is recomputed from the original absolute deadline after the sniff, so the probe never extends
# the global budget; an expired deadline refuses before either extractor with the usual timeout failure.
def extract_member(
  archive: String,
  canonical: String,
  dest: String,
  options: Archive.Options,
  deadline: Int,
) -> Result[List[Int]]
  zipped = zip_magic?(archive, deadline)
  left = deadline - Time.monotonic_ms()
  if left <= 0
    return error("the operation timed out")
  end
  fresh = Archive.Options(timeout_ms: left, max_output_bytes: options.max_output_bytes)
  if zipped
    return Archive.extract_zip(archive, [canonical], dest, fresh)
  end
  return Archive.extract_tar(archive, [canonical], dest, fresh)
end

# True when the file at `archive` opens with the ZIP local header (`PK\x03\x04`). Anything unreadable or short
# answers false, so the caller keeps the TAR path and reports its error.
def zip_magic?(archive: String, deadline: Int) -> Bool
  left = deadline - Time.monotonic_ms()
  if left <= 0
    return false
  end
  case File.open(archive, "read", left)
    ok(handle) ->
      left = deadline - Time.monotonic_ms()
      if left <= 0
        close_quiet(handle, deadline)
        return false
      end
      case File.read_bytes(handle, 4, left)
        ok(first) ->
          close_quiet(handle, deadline)
          if first.size < 4
            return false
          end
          return first[0] == 80 and first[1] == 75 and first[2] == 3 and first[3] == 4
        error(_) ->
          close_quiet(handle, deadline)
          return false
      end
    error(_) -> return false
  end
end

# Closes a sniff handle on the capped cleanup budget, never failing the caller.
def close_quiet(handle: FileHandle, deadline: Int) -> Void
  left = deadline - Time.monotonic_ms()
  budget = 5000
  if left > 0 and left < budget
    budget = left
  end
  case File.close(handle, budget)
    ok(_) -> return
    error(_) -> return
  end
end

# Every folder of `path`, made deepest last; one that is already a real folder is kept as is. A failure to agree on a
# folder is PKG-FETCH at the caller's key.
def make_parents(path: String, deadline: Int, context: NativeArtifact.Context) -> Result[Void]
  left = try time_left(deadline, context)
  info = File.stat(path, left)
  if info.ok?
    if info.unwrap!.kind == "directory"
      return ok()
    end
    return error(fail(context, "PKG-FETCH", "", "the cache holds a file where a folder goes", ""))
  end
  parent = Paths.directory_of(path)
  if parent != "" and parent != path
    try make_parents(parent, deadline, context)
  end
  left = deadline - Time.monotonic_ms()
  if left <= 0
    return error(fail(context, "PKG-FETCH", "", "the operation timed out", ""))
  end
  case Dir.mkdir(path, left)
    ok(_) -> return ok()
    error(_) ->
      # A concurrent fetch may have made it first: keep the winner when it is a real folder.
      fresh = deadline - Time.monotonic_ms()
      if fresh <= 0
        return error(fail(context, "PKG-FETCH", "", "the operation timed out", ""))
      end
      if is_dir?(path, fresh)
        return ok()
      end
      message = "the cache folder cannot be made"
      return error(fail(context, "PKG-FETCH", "", message, ""))
  end
end

# A new private folder under `parent` that only this process uses, as in package_fetch.agc.
def make_temp(parent: String, deadline: Int, context: NativeArtifact.Context) -> Result[String]
  left = try time_left(deadline, context)
  failure = "no free name"
  for attempt in 0...TEMP_TRIES
    left = deadline - Time.monotonic_ms()
    if left <= 0
      return error(fail(context, "PKG-FETCH", "", "the operation timed out", ""))
    end
    name = Paths.join(parent, ".tmp-#{System.pid()}-#{attempt}-#{Random.int(0, 999999999)}")
    case Dir.mkdir_private(name, left)
      ok(_) -> return ok(name)
      error(message) -> failure = message
    end
  end
  return error(fail(context, "PKG-FETCH", "", "cannot make a folder in the cache: #{failure}", ""))
end

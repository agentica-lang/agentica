## The data and path rules of the native artifact cache (docs/grammar/05b-modules.md, docs/future/45-packages.md
## 45.10): what a source row holds (the URL of the archive, its expected SHA-256, the member to use), where an archive
## and each selected member live under the cache root, and the pure checks on source rows and redirect targets. This
## module never touches the machine: the engine in io/native_artifact.agc does the downloads, the hashes and the
## renames, and packs every failure with the file and key the caller names. Cache objects are immutable and
## content-addressed: one archive as `<root>/native/<sha>/archive`, and each member as
## `<root>/native/<sha>/m/<digest>/` holding `payload/<member>` with a `receipt` of the SHA-256 of the member, where
## `<digest>` is the hex SHA-256 of the canonical member bytes. Several aliases that name one SHA with different
## members live side by side as disjoint objects; nothing cached is ever overwritten or mutated in place.

import Paths from "../modules/import_path"

## The most redirects one fetch follows, each with a fresh private file.
export MAX_REDIRECTS = 5
## The most archive bytes one fetch writes across all hops, bodies of redirects included.
export TOTAL_BODY_BYTES = 268435456
## The most extracted bytes of one member, as in std/archive.
export MEMBER_MAX_BYTES = 268435456
## The longest member path in bytes, as in std/archive.
export NAME_LIMIT_BYTES = 1024
## The length of a SHA-256 in lowercase hex digits.
export SHA_HEX_LENGTH = 64
## The widest timeout the engine takes, in milliseconds, as in std/http and std/archive.
export MAX_TIMEOUT_MS = 86400000
## The largest clock reading the engine adds a timeout to.
export MAX_CLOCK = 9223372036854775807

## One artifact row: the URL of the archive, its expected SHA-256 (64 lowercase hex digits), and the member to use
## from it (a relative TAR or ZIP member path, kept in archive spelling after one optional leading "./").
export struct Source
  url: String
  sha256: String
  member: String
end

## Where a row was written: the file and the dotted key path its failures point at (a manifest or lock entry today, a
## caller key until the manifest and lock rows land).
export struct Context
  file: String
  key: String
end

# One parsed URL: the lowercased scheme, the authority as written, the lowercased host without brackets, and the
# request target (the path, always starting with "/", with the query when there is one).
struct Parts
  scheme: String
  authority: String
  host: String
  target: String
end

# The request target split at its first "?": the path and the query with its mark, or the whole target and "".
struct Halves
  before: String
  after: String
end

# The host without brackets and the port text, checked the way std/http checks them.
struct HostPort
  host: String
  port: String
end

## The two hex digits of each digest byte, in lowercase.
export def hex_of(bytes: List[Int]) -> String
  digits = "0123456789abcdef"
  return bytes.map do |byte: Int|
    "#{digits.slice(byte.shift_right(4), 1)}#{digits.slice(byte.bit_and(15), 1)}"
  end.join("")
end

## Whether the hash names 32 bytes in 64 lowercase hex digits. The archive check compares it after the download, so a
## row with a short, long or uppercase hash fails here, before any network use.
export def valid_sha?(sha: String) -> Bool
  if sha.length != SHA_HEX_LENGTH
    return false
  end
  for c in String.split(sha, "")
    code = String.code(c)
    digit = code >= 48 and code <= 57
    lower = code >= 97 and code <= 102
    if not digit and not lower
      return false
    end
  end
  return true
end

## The member with one leading "./" stripped, when it is a safe relative path of at most 1024 bytes: no absolute
## path, drive letter, UNC share, backslash, colon or NUL byte, and no empty, "." or ".." segment. The spelling after
## the strip is canonical: "./lib.so" and "lib.so" name one member.
export def canonical_member(member: String) -> Result[String]
  if member == ""
    return error("a member must not be empty")
  end
  if String.to_bytes(member).size > NAME_LIMIT_BYTES
    return error("a member is longer than 1024 bytes")
  end
  path = member
  if String.starts_with?(path, "./")
    path = String.slice(path, 2, String.length(path) - 2)
  end
  if path == "" or path == "."
    return error("a member must name a file, not the root")
  end
  if String.starts_with?(path, "/")
    return error("a member must be a relative path")
  end
  for b in String.to_bytes(path)
    if b == 0
      return error("a member must not hold a NUL byte")
    end
    if b == 92 or b == 58
      return error("a member must not hold a backslash or a colon")
    end
  end
  for seg in String.split(path, "/")
    if seg == "" or seg == "." or seg == ".."
      return error("a member must be a safe relative path")
    end
  end
  return ok(path)
end

## The hex SHA-256 of the canonical member UTF-8 bytes: the key of its cache object. The hex of the pathname would
## leak the member spelling into folder names and vary in length; the digest is fixed width and opaque.
export def member_digest_hex(canonical: String) -> String
  return hex_of(Crypto.sha256(String.to_bytes(canonical)))
end

## The folder that holds the native artifacts: `<root>/native`, beside the package folders, never inside one, so the
## package hash never sees them.
export def native_base(cache_root: String) -> String
  return Paths.join(cache_root, "native")
end

## Where the archive with this SHA-256 lives: `<root>/native/<sha>/archive`.
export def archive_path(cache_root: String, sha: String) -> String
  return Paths.join(Paths.join(native_base(cache_root), sha), "archive")
end

## Where the object of one member lives: `<root>/native/<sha>/m/<digest>`.
export def member_dir(cache_root: String, sha: String, digest: String) -> String
  return Paths.join(Paths.join(Paths.join(native_base(cache_root), sha), "m"), digest)
end

## Where the extracted member of a member object lives: `<...>/payload/<member>`, in archive spelling, so the shared
## library keeps its file extension for the system loader.
export def payload_path(cache_root: String, sha: String, digest: String, canonical: String) -> String
  return Paths.join(Paths.join(member_dir(cache_root, sha, digest), "payload"), canonical)
end

## Where the receipt of a member object lives: `<...>/receipt`, holding the hex SHA-256 of the member bytes.
export def receipt_path(cache_root: String, sha: String, digest: String) -> String
  return Paths.join(member_dir(cache_root, sha, digest), "receipt")
end

## Whether the URL may be fetched: https anywhere, or http to a loopback literal (127.0.0.1 or [::1]) for hermetic
## tests. Anything with user info, a fragment or a control character is refused, as is anything but http(s); the host,
## port and bracket rules are std/http's, which rechecks before it sends.
export def url_allowed?(url: String) -> Bool
  parsed = parse_url(url)
  if !parsed.ok?
    return false
  end
  parts = parsed.unwrap!
  if parts.scheme == "https"
    return true
  end
  if parts.scheme == "http" and (parts.host == "127.0.0.1" or parts.host == "::1")
    return true
  end
  return false
end

## Whether following `next` from `current` drops from https to http. Both URLs passed `url_allowed?` first; an
## unparsable one never downgrades, it is refused elsewhere.
export def downgrade?(current: String, next: String) -> Bool
  current_parts = parse_url(current)
  next_parts = parse_url(next)
  if !current_parts.ok? or !next_parts.ok?
    return false
  end
  return current_parts.unwrap!.scheme == "https" and next_parts.unwrap!.scheme == "http"
end

## The body budget left for the next hop of a fetch: `total` minus the bytes every hop wrote so far. A hop needs
## a positive budget before it sends anything, so a fetch that already wrote `total` bytes stops without further
## I/O. The engine passes TOTAL_BODY_BYTES; tests pass tiny totals to prove the arithmetic without huge fixtures.
export def hop_budget(consumed: Int, total: Int) -> Result[Int]
  if total <= 0 or consumed < 0
    return error("the budget is not usable")
  end
  remaining = total - consumed
  if remaining <= 0
    return error("the budget is spent")
  end
  return ok(remaining)
end

## Whether the status is a redirect the engine follows with a GET: 301, 302, 303, 307 or 308, each with exactly one
## Location header.
export def redirect_status?(status: Int) -> Bool
  return status == 301 or status == 302 or status == 303 or status == 307 or status == 308
end

## The redirect target of `location` against `current`: an absolute URL passes through, a scheme-relative
## `//host/path` takes the scheme of `current`, an absolute path keeps the scheme and authority of `current`,
## anything else merges with the folder of the current target. A fragment is dropped
## (it is never sent); dot segments resolve lexically, and climbing past the root is refused. Errors are plain text
## for the engine to pack with the caller's file and key, without the secrets a Location may carry.
export def resolve_location(current: String, location: String) -> Result[String]
  bare = String.slice(location, 0, first_index(location, "#"))
  if bare == ""
    return error("the redirect holds no usable location")
  end
  for b in String.to_bytes(bare)
    if b < 32 or b == 127
      return error("the redirect holds no usable location")
    end
  end
  if has_scheme?(bare)
    checked = try parse_url(bare)
    return ok(canonical_url(checked))
  end
  parsed = try parse_url(current)
  if String.starts_with?(bare, "//")
    checked = try parse_url(scheme_relative_url(parsed.scheme, bare))
    return ok(canonical_url(checked))
  end
  if String.starts_with?(bare, "/")
    merged = split_query(bare)
    return ok("#{parsed.scheme}://#{parsed.authority}#{merged.before}#{merged.after}")
  end
  merged = split_query(bare)
  folder = current_folder(parsed.target)
  raw = split_query("#{folder}#{merged.before}")
  fixed = try normalize_path(raw.before)
  return ok("#{parsed.scheme}://#{parsed.authority}#{fixed}#{raw.after}")
end

# A scheme-relative target (`//host/path`) with the scheme of the current URL, for the normal URL policy to judge.
def scheme_relative_url(scheme: String, bare: String) -> String
  return "#{scheme}:#{bare}"
end

# Whether the text starts with a scheme (`name://` of letters, digits, "+" "-" and ".").
def has_scheme?(text: String) -> Bool
  stop = first_index(text, "://")
  if stop == 0 or stop == String.length(text)
    return false
  end
  for c in String.split(String.slice(text, 0, stop), "")
    code = String.code(c)
    letter = (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
    rest = (code >= 48 and code <= 57) or code == 43 or code == 45 or code == 46
    if not letter and not rest
      return false
    end
  end
  return stop < String.length(text) - 3
end

def split_query(target: String) -> Halves
  stop = first_index(target, "?")
  if stop == String.length(target)
    return Halves(before: target, after: "")
  end
  return Halves(before: String.slice(target, 0, stop), after: String.slice(target, stop, String.length(target) - stop))
end

def current_folder(target: String) -> String
  bare = split_query(target).before
  parts = String.split(bare, "/")
  if parts.size <= 1
    return "/"
  end
  kept = parts.take(parts.size - 1)
  return kept.join("/") + "/"
end

def normalize_path(path: String) -> Result[String]
  kept: List[String] = []
  for seg in String.split(path, "/")
    if seg == "" or seg == "."
      next
    end
    if seg == ".."
      if kept.size == 0
        return error("the redirect climbs past the root")
      end
      kept = kept.take(kept.size - 1)
      next
    end
    kept = kept.push(seg)
  end
  return ok("/" + kept.join("/"))
end

def canonical_url(parts: Parts) -> String
  return "#{parts.scheme}://#{parts.authority}#{parts.target}"
end

def first_index(text: String, part: String) -> Int
  return Result.unwrap_or(String.index_of(text, part), String.length(text))
end

def parse_url(url: String) -> Result[Parts]
  for b in String.to_bytes(url)
    if b < 32 or b == 127
      return error("the URL holds a control character")
    end
  end
  stop = first_index(url, "://")
  if stop == String.length(url)
    return error("the URL must start with http:// or https://")
  end
  scheme = String.downcase(String.slice(url, 0, stop))
  if scheme != "http" and scheme != "https"
    return error("the URL must start with http:// or https://")
  end
  rest = String.slice(url, stop + 3, String.length(url) - stop - 3)
  if String.contains?(rest, "#")
    return error("the URL must not hold a fragment")
  end
  slash = first_index(rest, "/")
  query = first_index(rest, "?")
  if query < slash
    slash = query
  end
  authority = String.slice(rest, 0, slash)
  target = String.slice(rest, slash, String.length(rest) - slash)
  if not String.starts_with?(target, "/")
    target = "/#{target}"
  end
  if String.contains?(authority, "@")
    return error("the URL must not hold user info")
  end
  for b in String.to_bytes(authority)
    if b < 33 or b > 126
      return error("the URL holds a bad authority")
    end
  end
  parsed = try split_authority(authority)
  if parsed.host == ""
    return error("the URL must hold a host")
  end
  return ok(Parts(scheme: scheme, authority: authority, host: parsed.host, target: target))
end

def split_authority(authority: String) -> Result[HostPort]
  if String.starts_with?(authority, "[")
    close = first_index(authority, "]")
    if close == String.length(authority)
      return error("the URL holds a bad host")
    end
    host = String.slice(authority, 1, close - 1)
    if not String.contains?(host, ":")
      return error("the URL holds a bad host")
    end
    after = String.slice(authority, close + 1, String.length(authority) - close - 1)
    if after != "" and (after == ":" or not String.starts_with?(after, ":"))
      return error("the URL holds a bad port")
    end
    port = ""
    if after != ""
      port = String.slice(after, 1, String.length(after) - 1)
    end
    try check_port(port)
    return ok(HostPort(host: String.downcase(host), port: port))
  end
  if String.contains?(authority, ":")
    colon = first_index(authority, ":")
    host = String.slice(authority, 0, colon)
    port = String.slice(authority, colon + 1, String.length(authority) - colon - 1)
    if port == ""
      return error("the URL holds a bad port")
    end
    try check_port(port)
    return ok(HostPort(host: String.downcase(host), port: port))
  end
  return ok(HostPort(host: String.downcase(authority), port: ""))
end

def check_port(port: String) -> Result[Void]
  if port == ""
    return ok()
  end
  if port.length > 5
    return error("the URL holds a bad port")
  end
  for c in String.split(port, "")
    code = String.code(c)
    if code < 48 or code > 57
      return error("the URL holds a bad port")
    end
  end
  number = String.to_int!(port)
  if number < 1 or number > 65535
    return error("the URL holds a bad port")
  end
  return ok()
end

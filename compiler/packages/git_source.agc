## Where a package comes from (docs/grammar/05b-modules.md): a git URL and one pin, a tag or a commit (`ref`), or a
## local folder (`path`, only in the manifest of the root project). The manifest and the lock both write it, and the
## build compares the two. The rules of the three parts are here, so that
## a rule changes in one place. Every check returns "" when the text is fine, else a reason for the diagnostic.

# The characters of each part. A name is `[a-z][a-z0-9_-]*`; a host is lowercase because host names ignore case; an
# owner or a repository is as the host spells it, with the characters git hosts allow.
NAME_FIRST = Set.new("abcdefghijklmnopqrstuvwxyz".split(""))
NAME_REST = Set.new("abcdefghijklmnopqrstuvwxyz0123456789_-".split(""))
HOST_CHARACTERS = Set.new("abcdefghijklmnopqrstuvwxyz0123456789.-".split(""))
SEGMENT_CHARACTERS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".split(""))
TAG_CHARACTERS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-".split(""))
HEX = Set.new("0123456789abcdef".split(""))
# The names Windows keeps for devices, with or without an extension. The owner and the repository are folders of the
# cache, so such a name could not be made there.
WINDOWS_DEVICES = Set.new([
  "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2",
  "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
])

MAX_NAME = 64
MAX_TAG = 128
MIN_REF = 7
MAX_REF = 64
MAX_SUBDIR = 128
MAX_PATH = 1024
HTTPS = "https://"
# The first characters of a commit in the stored name of a file of a package that is pinned by a ref.
SHORT_COMMIT = 12

## A source: a git URL as written, exactly one of tag and ref ("" for the other), and the folder of the repository
## that is the package ("" for the repository itself); or a local folder, `path` as written, with every other field "".
export struct Source
  git: String
  subdir: String
  tag: String
  ref: String
  path: String
end

## Why text is not the local name of a package, or "". The name is the segment after `pkg/` in an import, so it is
## one lowercase letter followed by lowercase letters, digits, `_` and `-`, at most 64 characters.
export def name_problem(name: String) -> String
  letters = name.split("")
  return "a package name has 1 to #{MAX_NAME} characters" if letters.size == 0 or letters.size > MAX_NAME

  if !NAME_FIRST.include?(letters[0]) or !letters.all? do |letter| NAME_REST.include?(letter) end
    return "a package name starts with a lowercase letter and holds only lowercase letters, digits, _ and -"
  end

  ""
end

## Whether a name is a Windows device name (`con`, `nul`, `com1` and the others, in any case, with or without an
## extension), which cannot name a file there.
export def device_name?(name: String) -> Bool = WINDOWS_DEVICES.include?(name.split(".")[0].downcase)

## Why text is not the git URL of a package, or "". It is `https://host/owner/repo` or `https://host/owner/repo.git`:
## https only, a lowercase host with no port and no user name, and exactly an owner and a repository.
export def git_problem(url: String) -> String
  return "a git URL starts with #{HTTPS}" if !url.start_with?(HTTPS)

  parts = identity(url).slice(HTTPS.length, identity(url).length - HTTPS.length).split("/")
  return "a git URL is #{HTTPS}host/owner/repo" if parts.size != 3

  host = parts[0]
  if host == "" or host.start_with?(".") or host.end_with?(".") or host.include?("..")
    return "the host of a git URL is a lowercase name such as github.com"
  end

  if !host.split("").all? do |letter| HOST_CHARACTERS.include?(letter) end
    return "the host of a git URL is lowercase letters, digits, . and - (no port, no user name)"
  end

  for segment in [parts[1], parts[2]]
    if segment == "" or segment == "." or segment == ".." or segment.start_with?("-")
      return "the owner and the repository of a git URL are not empty, . or .. and do not start with -"
    end

    if !segment.split("").all? do |letter| SEGMENT_CHARACTERS.include?(letter) end
      return "the owner and the repository of a git URL hold only letters, digits, . _ and -"
    end

    if segment.end_with?(".") or WINDOWS_DEVICES.include?(segment.split(".")[0].downcase)
      return "the owner and the repository of a git URL do not end in . and are not a Windows device name such as con"
    end
  end

  ""
end

## Why text is not a tag, or "". A tag is a git tag name made of letters, digits and . _ + - , without a `/`, so that
## it can be a part of a stored file name; it does not start with `.` or `-`. At most 128 characters.
export def tag_problem(tag: String) -> String
  letters = tag.split("")
  return "a tag has 1 to #{MAX_TAG} characters" if letters.size == 0 or letters.size > MAX_TAG

  if letters[0] == "." or letters[0] == "-" or !letters.all? do |letter| TAG_CHARACTERS.include?(letter) end
    return "a tag holds letters, digits, . _ + and -, and does not start with . or -"
  end

  ""
end

## Why text is not a subdir, or "". A subdir is the folder of the repository that holds the package: a relative path of
## plain folder names joined by `/`, each with only letters, digits, `.`, `_` and `-`. No part is empty, hidden (so not
## `.` or `..`) or `agc_libs`, which the hash leaves out, and the parts are safe names for the cache folder (they do
## not end in `.` and are not Windows device names). It holds no `@`, so the cache can join the parts. At most 128
## characters: the cache folder `<commit>@<subdir>` is one path component, which a file system limits to 255 bytes, and
## a SHA-256 commit takes 64 of them.
export def subdir_problem(subdir: String) -> String
  return "a subdir has 1 to #{MAX_SUBDIR} characters" if subdir.length == 0 or subdir.length > MAX_SUBDIR

  for part in subdir.split("/")
    return "a subdir is folder names joined by /, with no empty part, no leading / and no final /" if part == ""

    return "a subdir has no hidden folder and no . or .. part" if part.start_with?(".")

    if !part.split("").all? do |letter| SEGMENT_CHARACTERS.include?(letter) end
      return "the folders of a subdir hold only letters, digits, . _ and -"
    end

    if part.end_with?(".") or WINDOWS_DEVICES.include?(part.split(".")[0].downcase)
      return "the folders of a subdir do not end in . and are not a Windows device name such as con"
    end

    return "a subdir has no agc_libs folder, which a package leaves out" if part.upcase.downcase == "agc_libs"
  end

  ""
end

## Why text is not the `path` of a dependency, or "". It is the folder of a package on this machine, relative to the
## folder of the root manifest or absolute: not empty, with no control character, at most 1024 characters.
export def path_problem(path: String) -> String
  has_control = path.split("").any? do |char: String| String.code(char) < 32 or String.code(char) == 127 end
  if path.length == 0 or path.length > MAX_PATH or has_control
    return "a path is a folder of 1 to #{MAX_PATH} characters, with no control character"
  end

  ""
end

## Whether the source is a local folder, read in place.
export def local?(source: Source) -> Bool = source.path != ""

## Why text is not a ref, or "". A ref is a commit: 7 to 64 lowercase hex digits (a prefix of the commit, or all of
## it).
export def ref_problem(ref: String) -> String
  letters = ref.split("")
  if letters.size < MIN_REF or letters.size > MAX_REF or !letters.all? do |letter| HEX.include?(letter) end
    return "a ref is #{MIN_REF} to #{MAX_REF} lowercase hex digits of a commit"
  end

  ""
end

## Why text is not a full commit, or "": 40 or 64 lowercase hex digits (SHA-1 or SHA-256 repositories).
export def commit_problem(commit: String) -> String
  letters = commit.split("")
  if (letters.size != 40 and letters.size != 64) or !letters.all? do |letter| HEX.include?(letter) end
    return "a commit is 40 or 64 lowercase hex digits"
  end

  ""
end

## The URL without a final `.git`: two spellings of one repository have one identity.
export def identity(url: String) -> String
  return url.slice(0, url.length - 4) if url.end_with?(".git")

  url
end

## Whether two sources are the same: the same repository, the same folder of it and the same pin, or the same path as
## written.
export def same?(left: Source, right: Source) -> Bool
  same_place = identity(left.git) == identity(right.git) and left.subdir == right.subdir
  same_place and left.tag == right.tag and left.ref == right.ref and left.path == right.path
end

## The pin as written: the tag, or the ref.
export def pin(source: Source) -> String
  return source.tag if source.tag != ""

  source.ref
end

## The part of a stored file name after `@`: the tag, or the first 12 characters of the commit, so that two machines
## that pin one commit with different refs store the same name.
export def version_label(source: Source, commit: String) -> String
  return source.tag if source.tag != ""

  commit.slice(0, SHORT_COMMIT)
end

## The cache path of the repository: `host/owner/repo`. The URL is valid (git_problem is "").
export def cache_path(url: String) -> String
  rest = identity(url)
  rest.slice(HTTPS.length, rest.length - HTTPS.length)
end

## The source as the text of a message: the URL, the folder when there is one, and the pin.
export def describe(source: Source) -> String
  return "the path #{source.path}" if source.path != ""

  place = source.git
  if source.subdir != ""
    place = "#{source.git} (folder #{source.subdir})"
  end

  return "#{place} at tag #{source.tag}" if source.tag != ""

  "#{place} at ref #{source.ref}"
end

## Where a package comes from (docs/grammar/05b-modules.md): a git URL and one pin, a tag or a commit (`ref`). The
## manifest and the lock both write it, and the build compares the two. The rules of the three parts are here, so that
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
HTTPS = "https://"
# The first characters of a commit in the stored name of a file of a package that is pinned by a ref.
SHORT_COMMIT = 12

## A git source: the URL as written, exactly one of tag and ref ("" for the other), and the folder of the repository
## that is the package ("" for the repository itself).
export struct Source
  git: String
  subdir: String
  tag: String
  ref: String
end

## Why text is not the local name of a package, or "". The name is the segment after `pkg/` in an import, so it is
## one lowercase letter followed by lowercase letters, digits, `_` and `-`, at most 64 characters.
export def name_problem(name: String) -> String
  letters = name.split("")
  if letters.size == 0 or letters.size > MAX_NAME
    return "a package name has 1 to #{MAX_NAME} characters"
  end

  if !NAME_FIRST.include?(letters[0]) or !letters.all? do |letter| NAME_REST.include?(letter) end
    return "a package name starts with a lowercase letter and holds only lowercase letters, digits, _ and -"
  end

  return ""
end

## Why text is not the git URL of a package, or "". It is `https://host/owner/repo` or `https://host/owner/repo.git`:
## https only, a lowercase host with no port and no user name, and exactly an owner and a repository.
export def git_problem(url: String) -> String
  if !url.starts_with?(HTTPS)
    return "a git URL starts with #{HTTPS}"
  end

  parts = identity(url).slice(HTTPS.length, identity(url).length - HTTPS.length).split("/")
  if parts.size != 3
    return "a git URL is #{HTTPS}host/owner/repo"
  end

  host = parts[0]
  if host == "" or host.starts_with?(".") or host.ends_with?(".") or host.contains?("..")
    return "the host of a git URL is a lowercase name such as github.com"
  end

  if !host.split("").all? do |letter| HOST_CHARACTERS.include?(letter) end
    return "the host of a git URL is lowercase letters, digits, . and - (no port, no user name)"
  end

  for segment in [parts[1], parts[2]]
    if segment == "" or segment == "." or segment == ".." or segment.starts_with?("-")
      return "the owner and the repository of a git URL are not empty, . or .. and do not start with -"
    end

    if !segment.split("").all? do |letter| SEGMENT_CHARACTERS.include?(letter) end
      return "the owner and the repository of a git URL hold only letters, digits, . _ and -"
    end

    if segment.ends_with?(".") or WINDOWS_DEVICES.include?(segment.split(".")[0].downcase)
      return "the owner and the repository of a git URL do not end in . and are not a Windows device name such as con"
    end
  end

  return ""
end

## Why text is not a tag, or "". A tag is a git tag name made of letters, digits and . _ + - , without a `/`, so that
## it can be a part of a stored file name; it does not start with `.` or `-`. At most 128 characters.
export def tag_problem(tag: String) -> String
  letters = tag.split("")
  if letters.size == 0 or letters.size > MAX_TAG
    return "a tag has 1 to #{MAX_TAG} characters"
  end

  if letters[0] == "." or letters[0] == "-" or !letters.all? do |letter| TAG_CHARACTERS.include?(letter) end
    return "a tag holds letters, digits, . _ + and -, and does not start with . or -"
  end

  return ""
end

## Why text is not a subdir, or "". A subdir is the folder of the repository that holds the package: a relative path of
## plain folder names joined by `/`, each with only letters, digits, `.`, `_` and `-`. No part is empty, hidden (so not
## `.` or `..`) or `agc_libs`, which the hash leaves out, and the parts are safe names for the cache folder (they do
## not end in `.` and are not Windows device names). It holds no `@`, so the cache can join the parts. At most 128
## characters: the cache folder `<commit>@<subdir>` is one path component, which a file system limits to 255 bytes, and
## a SHA-256 commit takes 64 of them.
export def subdir_problem(subdir: String) -> String
  if subdir.length == 0 or subdir.length > MAX_SUBDIR
    return "a subdir has 1 to #{MAX_SUBDIR} characters"
  end

  for part in subdir.split("/")
    if part == ""
      return "a subdir is folder names joined by /, with no empty part, no leading / and no final /"
    end

    if part.starts_with?(".")
      return "a subdir has no hidden folder and no . or .. part"
    end

    if !part.split("").all? do |letter| SEGMENT_CHARACTERS.include?(letter) end
      return "the folders of a subdir hold only letters, digits, . _ and -"
    end

    if part.ends_with?(".") or WINDOWS_DEVICES.include?(part.split(".")[0].downcase)
      return "the folders of a subdir do not end in . and are not a Windows device name such as con"
    end

    if part.upcase.downcase == "agc_libs"
      return "a subdir has no agc_libs folder, which a package leaves out"
    end
  end

  return ""
end

## Why text is not a ref, or "". A ref is a commit: 7 to 64 lowercase hex digits (a prefix of the commit, or all of
## it).
export def ref_problem(ref: String) -> String
  letters = ref.split("")
  if letters.size < MIN_REF or letters.size > MAX_REF or !letters.all? do |letter| HEX.include?(letter) end
    return "a ref is #{MIN_REF} to #{MAX_REF} lowercase hex digits of a commit"
  end

  return ""
end

## Why text is not a full commit, or "": 40 or 64 lowercase hex digits (SHA-1 or SHA-256 repositories).
export def commit_problem(commit: String) -> String
  letters = commit.split("")
  if (letters.size != 40 and letters.size != 64) or !letters.all? do |letter| HEX.include?(letter) end
    return "a commit is 40 or 64 lowercase hex digits"
  end

  return ""
end

## The URL without a final `.git`: two spellings of one repository have one identity.
export def identity(url: String) -> String
  if url.ends_with?(".git")
    return url.slice(0, url.length - 4)
  end

  return url
end

## Whether two sources are the same: the same repository, the same folder of it and the same pin.
export def same?(left: Source, right: Source) -> Bool
  same_place = identity(left.git) == identity(right.git) and left.subdir == right.subdir
  return same_place and left.tag == right.tag and left.ref == right.ref
end

## The pin as written: the tag, or the ref.
export def pin(source: Source) -> String
  if source.tag != ""
    return source.tag
  end

  return source.ref
end

## The part of a stored file name after `@`: the tag, or the first 12 characters of the commit, so that two machines
## that pin one commit with different refs store the same name.
export def version_label(source: Source, commit: String) -> String
  if source.tag != ""
    return source.tag
  end

  return commit.slice(0, SHORT_COMMIT)
end

## The cache path of the repository: `host/owner/repo`. The URL is valid (git_problem is "").
export def cache_path(url: String) -> String
  rest = identity(url)
  return rest.slice(HTTPS.length, rest.length - HTTPS.length)
end

## The source as the text of a message: the URL, the folder when there is one, and the pin.
export def describe(source: Source) -> String
  place = source.git
  if source.subdir != ""
    place = "#{source.git} (folder #{source.subdir})"
  end

  if source.tag != ""
    return "#{place} at tag #{source.tag}"
  end

  return "#{place} at ref #{source.ref}"
end

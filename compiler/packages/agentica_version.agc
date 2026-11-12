## The `agentica` key of agentica.toml: the oldest Agentica that a package works with, one SemVer version (semver.org)
## read as a minimum. Versions are ordered as semver.org §11 says: major, minor and patch as numbers; a pre-release
## before its release (0.31.0-alpha.1 < 0.31.0); pre-release identifiers one by one, a numeric one by its value
## (alpha.2 < alpha.10) and before any other, the others in ASCII order, and the shorter list first when the rest is
## equal. Build metadata (`+...`) takes no part in the order.

import Failure from "../modules/link_failure"

## The key of the manifest that holds the version, which is also the key path of its failures.
export KEY = "agentica"

DIGITS = Set.new("0123456789".split(""))
IDENTIFIER_CHARACTERS = Set.new("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-".split(""))
# A version is short; the limit keeps a hostile manifest from making the compare walk a long text.
MAX_LENGTH = 256

## Whose manifest a key is in, which the failure names.
export enum Owner
  Project
  WorkspaceRoot
  Package(String)
end

# The parts of a version, as text: the three numbers of the core and the pre-release identifiers (none for a release).
# A number is compared as text by length first, which is its value because it has no leading zero.
struct Version
  core: List[String]
  pre: List[String]
end

## Why text is not one SemVer version, or "" when it is one.
export def problem(text: String) -> String
  parsed = parse(text)
  return "" if parsed.ok?

  parsed.message
end

## The owner of the manifest of the package `package`, "" for the project.
export def owner_of(package: String) -> Owner
  return Owner.Project if package == ""

  Owner.Package(package)
end

## Checks the `agentica` key of the manifest in `file` against the running version. `needed` is "" when the manifest
## has no key, and `running` is "" when the front end does not know its version (a program that writes no bytecode):
## then there is nothing to check. The failure is PKG-AGENTICA-TOO-OLD at the key, naming the owner.
export def check(file: String, owner: Owner, needed: String, running: String) -> Result[Void]
  return ok() if needed == "" or running == ""

  current = parse(running)
  minimum = parse(needed)
  return ok() if !current.ok? or !minimum.ok? or compare(current.unwrap!, minimum.unwrap!) >= 0

  who = "the project"
  help = "install Agentica #{needed} or newer"
  case owner
    Owner.Project -> who = "the project"
    Owner.WorkspaceRoot -> who = "the workspace root"
    Owner.Package(package) ->
      who = "the package #{package}"
      help = "#{help}, or pin a version of #{package} that works with #{running}"
  end

  message = "#{who} needs Agentica #{needed} or newer, and this is Agentica #{running}"
  error(Failure.fail_key(file, KEY, "PKG-AGENTICA-TOO-OLD", message, Failure.hint(help)))
end

# The parts of a version, or why the text is not one: MAJOR.MINOR.PATCH, then an optional `-` and dot-separated
# pre-release identifiers, then an optional `+` and build identifiers.
def parse(text: String) -> Result[Version]
  shape = "a version is MAJOR.MINOR.PATCH, with an optional pre-release such as -alpha.1"
  return error(shape) if text.length == 0 or text.length > MAX_LENGTH

  rest = text
  plus = rest.index_of("+").unwrap_or(-1)
  if plus >= 0
    build = rest.slice(plus + 1, rest.length - plus - 1)
    rest = rest.slice(0, plus)
    return error(shape) if !build.split(".").all? do |part| identifier?(part) end
  end

  pre: List[String] = []
  # The first `-` starts the pre-release, whose identifiers may hold more of them.
  dash = rest.index_of("-").unwrap_or(-1)
  if dash >= 0
    pre = rest.slice(dash + 1, rest.length - dash - 1).split(".")
    rest = rest.slice(0, dash)
    return error(shape) if !pre.all? do |part| identifier?(part) and !leading_zero?(part) end
  end

  core = rest.split(".")
  return error(shape) if core.size != 3 or !core.all? do |part| number?(part) and !leading_zero?(part) end

  ok(Version(core: core, pre: pre))
end

# Below 0, 0 or above 0 as a is older than, the same as or newer than b.
def compare(a: Version, b: Version) -> Int
  for index in 0...3
    order = compare_numbers(a.core[index], b.core[index])
    return order if order != 0
  end

  # A release is newer than any of its pre-releases.
  return 0 if a.pre.size == 0 and b.pre.size == 0
  return 1 if a.pre.size == 0
  return -1 if b.pre.size == 0

  index = 0
  while index < a.pre.size and index < b.pre.size
    order = compare_identifiers(a.pre[index], b.pre[index])
    return order if order != 0

    index = index + 1
  end

  a.pre.size - b.pre.size
end

# Two pre-release identifiers: numbers by value, a number before any other identifier, the others in ASCII order.
def compare_identifiers(a: String, b: String) -> Int
  if number?(a) and number?(b)
    return compare_numbers(a, b)
  elsif number?(a)
    return -1
  elsif number?(b)
    return 1
  end

  a.compare(b)
end

# Two numbers written without leading zeros: the longer is the larger, and of the same length the text decides.
def compare_numbers(a: String, b: String) -> Int
  return a.length - b.length if a.length != b.length

  a.compare(b)
end

def number?(text: String) -> Bool = text.length > 0 and text.split("").all? do |letter| DIGITS.include?(letter) end

def identifier?(text: String) -> Bool
  text.length > 0 and text.split("").all? do |letter| IDENTIFIER_CHARACTERS.include?(letter) end
end

def leading_zero?(text: String) -> Bool = number?(text) and text.length > 1 and text.start_with?("0")

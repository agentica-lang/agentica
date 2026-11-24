## The `version` key of a dependency (docs/grammar/05b-modules.md): a requirement over the SemVer tags of a repository,
## written as RubyGems and Mix write it. A requirement is terms joined by `,`; a tag has to satisfy every term. A
## term is an operator and a version: `~>` (the pessimistic operator: `~> 0.8` is `>= 0.8.0, < 1.0.0` and `~> 0.8.1` is
## `>= 0.8.1, < 0.9.0`), `>=`, `>`, `<=`, `<` or `==`; a version alone is `==`. A version has one to three numbers, and
## the missing ones are 0; only the full version of a bound may have a pre-release (`1.2.3-rc.1`). A pre-release tag is
## taken only when a term names a pre-release. The tags that count are `X.Y.Z` and `vX.Y.Z` of a repository, and
## `NAME-X.Y.Z` of a folder of it (`tag_prefix`).

import AgenticaVersion from "agentica_version"

## One bound of a requirement: `>=`, `>`, `<=`, `<` or `==`, and the full version it compares with.
struct Term
  op: String
  bound: AgenticaVersion.Version
end

## A requirement as it was written, and the bounds it means (`~>` is two of them).
struct Requirement
  text: String
  terms: List[Term]
end

## The requirement of the text, or why the text is not one.
def parse(text: String) -> Result[Requirement]
  shape = "a requirement is terms joined by commas, such as ~> 0.8 or >= 1.2.0, < 2.0.0"
  return error(shape) if text.length == 0 or text.length > MAX_LENGTH

  words = text.split(",")
  return error("a requirement has at most #{MAX_TERMS} terms") if words.size > MAX_TERMS

  terms: List[Term] = []
  for word in words
    found = try term_of(word.strip)
    terms = terms.concat(found)
  end

  ok(Requirement(text: text, terms: terms))
end

## Why text is not a requirement, or "".
def problem(text: String) -> String
  parsed = parse(text)
  return "" if parsed.ok?

  parsed.message
end

## Whether a version satisfies every term. A pre-release is accepted only when `prerelease?`.
def satisfied?(requirement: Requirement, version: AgenticaVersion.Version) -> Bool
  return false if version.pre.size > 0 and !prerelease?(requirement)

  requirement.terms.all? do |term: Term| holds?(term, version) end
end

## Whether a term names a pre-release, which lets a pre-release tag in.
def prerelease?(requirement: Requirement) -> Bool = requirement.terms.any? do |term: Term| term.bound.pre.size > 0 end

## The text before the version in the tags of a folder of a repository: `NAME-` for a `subdir` whose last folder is
## NAME, and "" for the repository itself, whose tags are `X.Y.Z` and `vX.Y.Z`.
def tag_prefix(subdir: String) -> String
  return "" if subdir == ""

  parts = subdir.split("/")
  "#{parts[parts.size - 1]}-"
end

## The version a tag names, or none when the tag is not one of the repository (`prefix` is `tag_prefix`).
def tag_version(tag: String, prefix: String) -> Optional[AgenticaVersion.Version]
  text = tag
  if prefix == "" and text.start_with?("v")
    text = text.slice(1, text.length - 1)
  elsif prefix != "" and text.start_with?(prefix)
    text = text.slice(prefix.length, text.length - prefix.length)
  elsif prefix != ""
    return none
  end

  parsed = AgenticaVersion.parse(text)
  return none if !parsed.ok?

  some(parsed.unwrap!)
end

## Whether the tag names a version that satisfies the requirement.
def tag_satisfies?(requirement: Requirement, tag: String, prefix: String) -> Bool
  found = tag_version(tag, prefix)
  found.some? and satisfied?(requirement, found.unwrap!)
end

## The tag with the highest version that satisfies the requirement, or none. Two tags of one version (`1.2.0` and
## `v1.2.0`) are the same version: the first in text order wins, so the answer does not depend on git's listing.
def highest(requirement: Requirement, tags: List[String], prefix: String) -> Optional[String]
  best = ""
  best_version = AgenticaVersion.Version(core: ["0", "0", "0"], pre: [])
  for tag in tags.sort
    found = tag_version(tag, prefix)
    next if !found.some? or !satisfied?(requirement, found.unwrap!)

    if best == "" or AgenticaVersion.compare(found.unwrap!, best_version) > 0
      best = tag
      best_version = found.unwrap!
    end
  end

  return none if best == ""

  some(best)
end

## The tags that read as a version of this repository or folder, highest first, at most `limit`: what the failure of a
## requirement that no tag satisfies shows.
def newest(tags: List[String], prefix: String, limit: Int) -> List[String]
  named = tags.select do |tag: String| tag_version(tag, prefix).some? end
  ordered = named.sort_by do |tag: String| sort_text(tag_version(tag, prefix).unwrap!) end
  ordered.reverse.take(limit)
end

private

MAX_LENGTH = 256
MAX_TERMS = 8
OPERATORS = ["~>", ">=", "<=", "==", ">", "<"]
DIGITS = Set.new("0123456789".split(""))

# One written term as the bounds it means: `~>` gives a lower and an upper one, the others one.
def term_of(word: String) -> Result[List[Term]]
  op = "=="
  rest = word
  for candidate in OPERATORS
    if word.start_with?(candidate)
      op = candidate
      rest = word.slice(candidate.length, word.length - candidate.length).strip
      break
    end
  end

  dash = rest.index_of("-").unwrap_or(-1)
  core = rest
  if dash >= 0
    core = rest.slice(0, dash)
  end

  numbers = core.split(".")
  shaped = numbers.size <= 3 and core.length > 0 and !rest.include?("+")
  if !shaped or (numbers.size < 3 and dash >= 0)
    return error("#{word} is not a term: an operator, then a version of one to three numbers")
  end

  full = rest
  parts = numbers.size
  if parts < 3
    padding = ".0" * (3 - parts)
    full = "#{rest}#{padding}"
  end

  parsed = AgenticaVersion.parse(full)
  return error("#{word} is not a term: #{parsed.message}") if !parsed.ok?

  bound = parsed.unwrap!
  return ok([Term(op: op, bound: bound)]) if op != "~>"

  ok([Term(op: ">=", bound: bound), Term(op: "<", bound: upper(bound, parts))])
end

# The first version that `~>` leaves out: the next major for `~> X` and `~> X.Y`, the next minor for `~> X.Y.Z`.
def upper(bound: AgenticaVersion.Version, parts: Int) -> AgenticaVersion.Version
  major = bound.core[0]
  minor = bound.core[1]
  return AgenticaVersion.Version(core: [bump(major), "0", "0"], pre: []) if parts < 3

  AgenticaVersion.Version(core: [major, bump(minor), "0"], pre: [])
end

# The number after `digits` (written without a leading zero), as text.
def bump(digits: String) -> String
  letters = digits.split("")
  at = letters.size - 1
  while at >= 0
    if letters[at] == "9"
      letters = letters.take(at).append("0").concat(letters.drop(at + 1))
      at -= 1
    else
      next_digit = (letters[at].to_i! + 1).to_s
      letters = letters.take(at).append(next_digit).concat(letters.drop(at + 1))
      return letters.join("")
    end
  end

  "1#{letters.join("")}"
end

def holds?(term: Term, version: AgenticaVersion.Version) -> Bool
  order = AgenticaVersion.compare(version, term.bound)
  case term.op
    ">=" -> order >= 0
    ">" -> order > 0
    "<=" -> order <= 0
    "<" -> order < 0
    _ -> order == 0
  end
end

# A text that sorts versions as the versions compare, for the few tags a failure lists: the numbers are padded.
def sort_text(version: AgenticaVersion.Version) -> String
  padded = version.core.map do |number: String| "#{"0" * (12 - number.length)}#{number}" end
  release = "1"
  if version.pre.size > 0
    release = "0"
  end

  "#{padded.join(".")}.#{release}.#{version.pre.join(".")}"
end

## Semantic versions for packages (docs/future/45-packages.md, 45.7): MAJOR.MINOR.PATCH with an optional -prerelease.
## A version in agentica.toml and agentica.lock is written without the "v" of the git tag, and has no +build part.

# The largest number of digits of one number: it keeps every number far below the Int limit.
MAX_DIGITS = 9

## A parsed version. pre holds the dot-separated parts of the prerelease, empty for a release.
export struct Version
  major: Int
  minor: Int
  patch: Int
  pre: List[String]
end

## Reads a version, or says what is wrong with the text.
export def parse(text: String) -> Result[Version]
  dash = text.index_of("-")
  core = text
  pre: List[String] = []
  if dash.ok?
    core = text.slice(0, dash.unwrap!)
    pre = text.slice(dash.unwrap! + 1, text.length - dash.unwrap! - 1).split(".")
    for part in pre
      try check_identifier(part)
    end
  end
  numbers = core.split(".")
  if numbers.size != 3
    return error("a version is MAJOR.MINOR.PATCH")
  end
  major = try number(numbers[0])
  minor = try number(numbers[1])
  patch = try number(numbers[2])
  return ok(Version(major: major, minor: minor, patch: patch, pre: pre))
end

## Orders two versions: -1, 0 or 1. A prerelease is lower than its release, and prerelease parts compare as numbers
## when both are numeric, else as text, with a number lower than text, as in semver.org.
export def compare(left: Version, right: Version) -> Int
  for pair in [[left.major, right.major], [left.minor, right.minor], [left.patch, right.patch]]
    if pair[0] != pair[1]
      return sign(pair[0] - pair[1])
    end
  end
  if left.pre.size == 0 or right.pre.size == 0
    return sign(right.pre.size - left.pre.size)
  end
  return compare_pre(left.pre, right.pre)
end

## True when version is at least minimum and has the same major, which is the rule of one major for each key.
export def meets?(version: Version, minimum: Version) -> Bool
  return version.major == minimum.major and compare(version, minimum) >= 0
end

def sign(value: Int) -> Int
  if value < 0
    return -1
  elsif value > 0
    return 1
  end
  return 0
end

def compare_pre(left: List[String], right: List[String]) -> Int
  shared = left.size
  if right.size < shared
    shared = right.size
  end
  for index in 0...shared
    order = compare_part(left[index], right[index])
    if order != 0
      return order
    end
  end
  return sign(left.size - right.size)
end

# Numbers have no leading zero, so a longer one is larger and equal lengths compare as text, whatever the length.
def compare_part(left: String, right: String) -> Int
  if numeric?(left) and numeric?(right)
    if left.length != right.length
      return sign(left.length - right.length)
    end
  elsif numeric?(left)
    return -1
  elsif numeric?(right)
    return 1
  end
  return String.compare(left, right)
end

def numeric?(text: String) -> Bool
  return text != "" and text.split("").all? do |c| digit?(c) end
end

def digit?(character: String) -> Bool
  code = String.code(character)
  return code >= 48 and code <= 57
end

def check_identifier(part: String) -> Result[Void]
  if part == ""
    return error("a prerelease part is empty")
  end
  for character in part.split("")
    code = String.code(character)
    if !(digit?(character) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code == 45)
      return error("a prerelease part holds only letters, digits and -")
    end
  end
  if part.length > 1 and part.starts_with?("0") and numeric?(part)
    return error("a numeric prerelease part has no leading zero")
  end
  return ok()
end

def number(text: String) -> Result[Int]
  if text.length > MAX_DIGITS or !numeric?(text)
    return error("a version number is 1 to #{MAX_DIGITS} digits")
  end
  if text.length > 1 and text.starts_with?("0")
    return error("a version number has no leading zero")
  end
  return ok(text.to_i!)
end

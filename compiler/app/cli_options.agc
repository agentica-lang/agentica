## The options in front of the command or the source file, read left to right, up to the first word that is not an
## option; `--` ends them; an option that takes a value takes the next word whatever it is. `--version` and `-h` answer
## and stop at once, so an option after them is never read. A word that starts with "-" or "+" and has more than one
## character is an option.
##
## `-h` is the only short option, so `-hx` is the help and `-xh` is `unknown switch: -x`. An empty source file name is
## `cannot read `.

import Reply from "cli_reply"
import Texts from "cli_text"

# The options that are given once at most, with the number of values each takes; --steps may repeat.
ONCE = {
  "--version": 0, "--deny-run": 0, "--deny-native": 0, "--max-steps": 1, "--seed": 1, "--flush-timeout": 1,
  "--schedulers": 1, "--dump": 0, "--dump-ir": 0, "--ai": 0, "--json": 0,
}
DIGITS = "0123456789"

## What the options said, and the words after them (the command, or the source file, and its arguments).
export struct Options
  style: String
  max_steps: String
  seed: String
  flush_timeout: String
  schedulers: String
  deny_run: Bool
  deny_native: Bool
  dump: Bool
  dump_ir: Bool
  steps: List[String]
  words: List[String]
end

# What applying one option gave: the options, or why it was refused (exit code 2).
enum Applied
  Changed(Options)
  Refused(String)
end

## The result of reading the options: to go on with, or an answer already complete (`--version`, `-h`, a mistake in
## the options).
export enum Parsed
  Ready(Options)
  Answer(Reply.Reply)
end

## Reads the options of `arguments`. `version` is what `--version` prints.
export def parse(arguments: List[String], version: String) -> Parsed
  options = Options(
    style: "plain",
    max_steps: "",
    seed: "",
    flush_timeout: "",
    schedulers: "",
    deny_run: false,
    deny_native: false,
    dump: false,
    dump_ir: false,
    steps: [],
    words: [],
  )
  seen: Set[String] = Set.new([])
  at = 0
  while at < arguments.size
    word = arguments[at]
    if word == "--"
      return Parsed.Ready(options.with(words: arguments.drop(at + 1)))
    elsif !option?(word)
      return Parsed.Ready(options.with(words: arguments.drop(at)))
    elsif word == "--help" or (!word.starts_with?("--") and word.starts_with?("-h"))
      return Parsed.Answer(Reply.printed(Texts.help_text()))
    elsif !word.starts_with?("--") and word.length > 1
      return mistake("unknown switch: #{word.slice(0, 2)}")
    elsif word == "--version"
      return Parsed.Answer(Reply.printed("#{version}\n"))
    end
    taken = values(word)
    if taken < 0
      return mistake("unknown switch: #{word}")
    elsif seen.include?(word) and word != "--steps"
      return mistake("the #{word} option can only be specified once")
    elsif at + taken >= arguments.size
      return mistake("the \"#{word}\" option needs 1 argument, but 0 provided")
    end
    seen = seen.add(word)
    value = ""
    if taken > 0
      value = arguments[at + 1]
    end
    case apply(options, word, value)
      Applied.Changed(changed) -> options = changed
      Applied.Refused(message) -> return Parsed.Answer(Reply.failed(2, "agentica: #{message}\n"))
    end
    at += 1 + taken
  end
  return Parsed.Ready(options)
end

def mistake(message: String) -> Parsed
  return Parsed.Answer(Reply.failed(1, "agentica: #{message}\n"))
end

def option?(word: String) -> Bool
  return word.length > 1 and (word.starts_with?("-") or word.starts_with?("+"))
end

# How many values an option takes, or -1 when it is not one.
def values(word: String) -> Int
  if word == "--steps"
    return 1
  end
  found = ONCE.get(word)
  if found.ok?
    return found.unwrap!
  end
  return -1
end

def apply(options: Options, word: String, value: String) -> Applied
  case word
    "--deny-run" -> return Applied.Changed(options.with(deny_run: true))
    "--deny-native" -> return Applied.Changed(options.with(deny_native: true))
    "--dump" -> return Applied.Changed(options.with(dump: true))
    "--dump-ir" -> return Applied.Changed(options.with(dump_ir: true))
    "--ai" -> return Applied.Changed(options.with(style: "ai"))
    "--json" -> return Applied.Changed(options.with(style: "json"))
    "--steps" -> return Applied.Changed(options.with(steps: options.steps.push(value)))
    "--max-steps" -> return max_steps(options, value)
    "--seed" -> return seed(options, value)
    "--schedulers" -> return schedulers(options, value)
    _ -> return flush_timeout(options, value)
  end
end

def max_steps(options: Options, value: String) -> Applied
  digits = without_leading_zeros(value)
  if !digits?(value) or digits == "0"
    return Applied.Refused("--max-steps needs a positive integer")
  end
  return Applied.Changed(options.with(max_steps: digits))
end

def seed(options: Options, value: String) -> Applied
  digits = without_leading_zeros(value)
  if !digits?(value) or digits.length > 10 or digits.to_i! > 2_147_483_647
    return Applied.Refused("--seed needs an integer from 0 to 2147483647")
  end
  return Applied.Changed(options.with(seed: digits))
end

def schedulers(options: Options, value: String) -> Applied
  digits = without_leading_zeros(value)
  if !digits?(value) or digits.length > 4 or digits.to_i! < 1 or digits.to_i! > 1024
    return Applied.Refused("--schedulers needs an integer from 1 to 1024")
  end
  return Applied.Changed(options.with(schedulers: digits))
end

# The flag passes the text as it was typed (a leading zero stays).
def flush_timeout(options: Options, value: String) -> Applied
  if !digits?(value)
    return Applied.Refused("--flush-timeout needs a non-negative integer")
  end
  return Applied.Changed(options.with(flush_timeout: value))
end

# Not empty, and only the digits 0 to 9.
def digits?(text: String) -> Bool
  if text.length == 0
    return false
  end
  for character in text.split("")
    if !DIGITS.contains?(character)
      return false
    end
  end
  return true
end

# The number as `agentica` prints it: no leading zeros, and "0" for zero.
def without_leading_zeros(text: String) -> String
  at = 0
  while at < text.length - 1 and text.slice(at, 1) == "0"
    at += 1
  end
  return text.slice(at, text.length - at)
end

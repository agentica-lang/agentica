## Parses the command line of a program: positional arguments (`Arg`), options with a long and a short name
## (`Opt`), defaults, choices and the `--help` text. The shape is that of Python's `argparse`, the names are Ruby's
## (`OptionParser`, `parse`, `run!`). Pure Agentica: no Json, only structs, enums and `Optional`.
##
## Import it with `import OP from "std/option_parser"` and `import {Arg, Opt, Kind} from "std/option_parser"`.
## `OP.new(program, description, args, opts)` describes the interface and `OP.parse(parser, args)` checks the words
## (`System.args()`) and returns a `Parsed`, from which the typed getters (`OP.string`, `OP.int`, `OP.float`,
## `OP.flag` and the `OP.optional_*` forms) read each value into the program's own struct.
##
## Words the parser understands:
##
## - `--port 3000`, `--port=3000`, `-p 3000`, `-p3000` and `-p=3000`; a flag is `--verbose` or `-v`, and short flags
##   may be joined (`-vq`). As in argparse, the next word is a value only if it does not look like an option: a
##   negative number (`-1`, `-2.5`) and a lone `-` are values, any other word that starts with `-` is not, and the
##   option is missing its value. `--name=--x` and `-n--x` give the literal. A negative number is also an argument.
## - `--` ends the options; every later word is a positional argument, as is a lone `-`.
## - `--help` or `-h` asks for the usage text: `parse` then returns an error for which `help?` is true.
## - An option given twice keeps its last value.
## - An `Int` option or argument may have a range: `min` and `max` (each `some(n)` or `none`). A value outside it is
##   refused as any other bad value is, and the help shows it (`[min: 0, max: 65535]`).
## - On and off is a `String` option with `choices: ["on", "off"]`, read with `OP.string(p, "stats") == "on"`: there
##   is no Bool kind, because a `Flag` takes no value and a value that is one of two words is what `choices` says.
##
## Every error of `parse` is `"program: message"` plus a hint line (`Try 'program --help' for more information`),
## and the message names the option or argument. Print an error with `message(error)`, not as it is: for a help
## request (`help?` is true) the raw text starts with a marker line that `message` leaves out. A mistake in the
## specification itself (a duplicate name, a default that is not an Int) is an error too, from `parse`, without the
## hint. A getter called with a name that was not declared, with the wrong kind, or for a value that may be absent
## halts the program (`RUNTIME-UNWRAP-ERROR`, whose stack names the line of the call): that is a bug of the
## program, not of the user.

# The first line of the error that stands for a request of help; what follows it is the usage text.
HELP_MARK = "option_parser: help\n"

## The type of the value of an option or an argument. A `Flag` takes no value: it is false unless given.
export enum Kind
  Int
  Float
  String
  Flag
end

## A positional argument. All are required, in the order of the list given to `new`. `metavar` is the name shown in
## the usage line (default: `name`). `choices` are compared as text. `min` and `max` limit an `Int` argument
## (`none`: no limit).
export struct Arg
  name: String
  help: String = ""
  kind: Kind = Kind.String
  choices: List[String] = []
  metavar: String = ""
  min: Optional[Int] = none
  max: Optional[Int] = none
end

## An option. `name` is the long name (`--port`), `short` one character (`-p`) or "". `default` is a String
## converted by `kind` (it applies when the option is not given; "" means no default, and a `Flag` has none).
## `choices` are compared as text. `metavar` is the value name shown in the help (default: the choices as `a|b`,
## else `name` in capitals). `min` and `max` limit an `Int` option (`none`: no limit); they also apply to the
## default.
export struct Opt
  name: String
  short: String = ""
  kind: Kind = Kind.String
  default: String = ""
  choices: List[String] = []
  help: String = ""
  metavar: String = ""
  min: Optional[Int] = none
  max: Optional[Int] = none
end

## The interface of a program, built by `new`.
export struct Parser
  program: String
  description: String
  args: List[Arg]
  opts: List[Opt]
  rest: String = ""
end

## The converted values of a command line, read by the getters. Treat it as opaque: `kinds` says which names were
## declared and with what kind, the other maps hold the values that are present.
export struct Parsed
  kinds: Map[String, Kind]
  strings: Map[String, String]
  ints: Map[String, Int]
  floats: Map[String, Float]
  flags: Map[String, Bool]
  rest: List[String] = []
  after_dashes: List[String] = []
end

# One Arg or Opt, as the parser sees them.
struct Slot
  name: String
  short: String
  kind: Kind
  default: String
  choices: List[String]
  help: String
  metavar: String
  min: Optional[Int]
  max: Optional[Int]
  positional: Bool
  flag: Bool
end

# What the readers of one command line need: the specification and the words.
struct Reader
  parser: Parser
  slots: List[Slot]
  args: List[String]
end

# The raw text of each given name, the positional words in order, and how many of them came before `--` (all of them
# when there is none).
struct Scan
  values: Map[String, String]
  positionals: List[String]
  before_dashes: Int
end

# The result of reading one word: the values so far, the index of the next word, and whether help was asked.
struct Step
  values: Map[String, String]
  next: Int
  help: Bool
end

## Describes a program: its name, a one-line description and its arguments and options, each list in order. `rest`
## names the positional words after the arguments (`FILE` shows `[FILE...]` in the usage line), which `parse` then
## keeps for `rest` and `after_dashes` instead of refusing them; "" (the default) refuses them.
export def new(
  program: String,
  description: String = "",
  args: List[Arg] = [],
  opts: List[Opt] = [],
  rest: String = "",
) -> Parser
  return Parser(program: program, description: description, args: args, opts: opts, rest: rest)
end

## Checks the words (normally `System.args()`) against the parser and returns the converted values. An error says
## what is wrong, or, when `help?` is true for it, that the usage text was asked for.
export def parse(parser: Parser, args: List[String]) -> Result[Parsed]
  slots = try slots_of(parser)
  scan = try scan_words(parser, slots, args)
  return build(parser, slots, scan)
end

## Returns true when the error of `parse` stands for `--help`: the program prints `usage` and exits with 0.
export def help?(message: String) -> Bool
  return message.start_with?(HELP_MARK)
end

## Returns the text to print for an error of `parse`: the usage text when `help?` is true, without the marker line,
## and the message itself otherwise. A program that prints errors itself uses this and never prints the raw message
## of a help request.
export def message(error_text: String) -> String
  if help?(error_text)
    return error_text.slice(HELP_MARK.length, error_text.length - HELP_MARK.length)
  end
  return error_text
end

## Returns the help text: the usage line, the description and a row for every argument and option.
export def usage(parser: Parser) -> String
  slots = slots_unchecked(parser)
  lines = ["Usage: #{usage_line(parser, slots)}"]
  if !parser.description.empty?
    lines = lines.push("").push(parser.description)
  end
  positionals = slots.select do |slot| slot.positional end
  options = slots.select do |slot| not slot.positional end
  help_slot = Slot(
    name: "help",
    short: "h",
    kind: Kind.Flag,
    default: "",
    choices: [],
    help: "show this help",
    metavar: "",
    min: none,
    max: none,
    positional: false,
    flag: true,
  )

  width = slots.push(help_slot).reduce(0) do |widest, slot| wider(widest, head(slot).length) end
  if !positionals.empty?
    lines = lines.push("").push("Arguments:").concat(positionals.map do |slot| row(slot, width) end)
  end
  lines = lines.push("").push("Options:").concat(options.push(help_slot).map do |slot| row(slot, width) end)
  return lines.join("\n")
end

## Prints the help (to stdout) and exits with 0 when `result` is the error for `--help`; prints the error to stderr
## and exits with 2 for any other error; returns the value of an `ok`. Call it where the program gets its options
## (`options = OP.run!(load())`): it is the one place of this module that ends the program.
export def run![T](result: Result[T]) -> T
  case result
    ok(value) -> return value
    error(text) -> finish(text)
  end
  return result.unwrap!
end

## Returns the value of a String option or argument. The option needs a default (or be an argument); otherwise use
## `optional_string`.
export def string(parsed: Parsed, name: String) -> String
  require(parsed, name, Kind.String, parsed.strings.key?(name))
  return parsed.strings[name]
end

## Returns the value of an Int option or argument; see `string`.
export def int(parsed: Parsed, name: String) -> Int
  require(parsed, name, Kind.Int, parsed.ints.key?(name))
  return parsed.ints[name]
end

## Returns the value of a Float option or argument; see `string`.
export def float(parsed: Parsed, name: String) -> Float
  require(parsed, name, Kind.Float, parsed.floats.key?(name))
  return parsed.floats[name]
end

## Returns true when the flag was given, false otherwise.
export def flag(parsed: Parsed, name: String) -> Bool
  require(parsed, name, Kind.Flag, true)
  return parsed.flags[name]
end

## Returns the value of a String option, or `none` when it was not given and has no default.
export def optional_string(parsed: Parsed, name: String) -> Optional[String]
  require(parsed, name, Kind.String, true)
  return parsed.strings.get(name)
end

## Returns the value of an Int option, or `none` when it was not given and has no default.
export def optional_int(parsed: Parsed, name: String) -> Optional[Int]
  require(parsed, name, Kind.Int, true)
  return parsed.ints.get(name)
end

## Returns the value of a Float option, or `none` when it was not given and has no default.
export def optional_float(parsed: Parsed, name: String) -> Optional[Float]
  require(parsed, name, Kind.Float, true)
  return parsed.floats.get(name)
end

## Returns the positional words after the arguments, in order, those after `--` included, as Ruby's
## `OptionParser#parse` returns them. Empty unless `new` was given `rest`.
export def rest(parsed: Parsed) -> List[String]
  return parsed.rest
end

## Returns the words of `rest` that came after `--`, its last ones: in `FILE... -- FLAGS` they are the flags, and the
## files are `rest` without them.
export def after_dashes(parsed: Parsed) -> List[String]
  return parsed.after_dashes
end

# Halts with a bug of the program: an undeclared name, the wrong getter for a kind, or a plain getter for a value
# that may be absent. `present` is whether the value exists.
def require(parsed: Parsed, name: String, kind: Kind, present: Bool) -> Void
  declared = parsed.kinds.get(name)
  if declared.none?
    bug("no option or argument is named '#{name}'")
  end
  # Enums have no ==, so the kinds are compared by name.
  if kind_name(declared.unwrap!) != kind_name(kind)
    bug("'#{name}' is declared as #{kind_name(declared.unwrap!)} but read as #{kind_name(kind)}")
  end
  if !present
    bug("'#{name}' has no default and was not given: read it with optional_#{kind_name(kind)}")
  end
end

# Ends the program with the message as RUNTIME-UNWRAP-ERROR: its stack names the getter and the line of the caller.
def bug(message: String) -> Void
  failed: Result[Int] = error("option_parser: #{message}")
  failed.unwrap!
end

# The one place that ends the program.
def finish(error_text: String) -> Void
  if help?(error_text)
    puts(message(error_text))
    System.exit(0)
  end
  IO.warn(error_text)
  System.exit(2)
end

def kind_name(kind: Kind) -> String
  case kind
    Kind.Int -> return "int"
    Kind.Float -> return "float"
    Kind.String -> return "string"
    Kind.Flag -> return "flag"
  end
end

def int_kind?(kind: Kind) -> Bool
  case kind
    Kind.Int -> return true
    Kind.Float -> return false
    Kind.String -> return false
    Kind.Flag -> return false
  end
end

def flag_kind?(kind: Kind) -> Bool
  case kind
    Kind.Flag -> return true
    Kind.Int -> return false
    Kind.Float -> return false
    Kind.String -> return false
  end
end

# The slots of the specification, in the order arguments, then options, without any check.
def slots_unchecked(parser: Parser) -> List[Slot]
  positionals = parser.args.map do |arg|
    Slot(
      name: arg.name,
      short: "",
      kind: arg.kind,
      default: "",
      choices: arg.choices,
      help: arg.help,
      metavar: arg.metavar,
      min: arg.min,
      max: arg.max,
      positional: true,
      flag: flag_kind?(arg.kind),
    )
  end

  options = parser.opts.map do |opt|
    Slot(
      name: opt.name,
      short: opt.short,
      kind: opt.kind,
      default: opt.default,
      choices: opt.choices,
      help: opt.help,
      metavar: opt.metavar,
      min: opt.min,
      max: opt.max,
      positional: false,
      flag: flag_kind?(opt.kind),
    )
  end

  return positionals.concat(options)
end

# The slots, once the specification is checked: names and short names are well formed, free and different, and
# every default is valid for its kind and choices.
def slots_of(parser: Parser) -> Result[List[Slot]]
  if parser.program.empty?
    return error("option_parser: invalid specification: the program name is empty")
  end
  slots = slots_unchecked(parser)
  names = Set.new(["help"])
  shorts = Set.new(["h"])
  for slot in slots
    try check_names(parser, slot, names, shorts)
    names = names.add(slot.name)
    shorts = shorts.add(slot.short)
    try check_slot(parser, slot)
  end
  return ok(slots)
end

def check_names(parser: Parser, slot: Slot, names: Set[String], shorts: Set[String]) -> Result[Void]
  if slot.name.empty? or slot.name.start_with?("-") or slot.name.include?("=") or spaced?(slot.name)
    return bad_spec(parser, "'#{slot.name}' is not a valid name")
  end
  if names.include?(slot.name)
    return bad_spec(parser, "the name #{label(slot)} is used twice or is reserved")
  end
  if !slot.short.empty? and (!letter?(slot.short) or shorts.include?(slot.short))
    return bad_spec(parser, "the short name '#{slot.short}' of #{label(slot)} is not one free character")
  end
  return ok()
end

# Whether the text has a space or a control character.
def spaced?(text: String) -> Bool
  return text.split("").any? do |character| character.code <= 32 or character.code == 127 end
end

# One character that is not a space, a control character, "-", "=" or a digit: a digit would read as a negative
# number, and "=" as the end of the name.
def letter?(text: String) -> Bool
  return text.length == 1 and !spaced?(text) and text != "-" and text != "=" and !digits?(text)
end

def check_slot(parser: Parser, slot: Slot) -> Result[Void]
  if slot.flag and slot.positional
    return bad_spec(parser, "#{label(slot)} cannot be a Flag")
  end
  if slot.flag and (!slot.default.empty? or !slot.choices.empty?)
    return bad_spec(parser, "the flag #{label(slot)} has no default or choices")
  end
  if (slot.min.some? or slot.max.some?) and !int_kind?(slot.kind)
    return bad_spec(parser, "#{label(slot)} has min or max but is not an Int")
  end
  if slot.min.some? and slot.max.some? and slot.min.unwrap! > slot.max.unwrap!
    return bad_spec(parser, "the min of #{label(slot)} is above its max")
  end
  if slot.default.empty? or slot.flag
    return ok()
  end
  case store(empty_parsed(), slot, slot.default)
    ok(_) -> return ok()
    error(message) -> return bad_spec(parser, "invalid default for #{label(slot)}: #{message}")
  end
end

def bad_spec(parser: Parser, message: String) -> Result[Void]
  return error("#{parser.program}: invalid specification: #{message}")
end

def empty_parsed() -> Parsed
  return Parsed(kinds: {}, strings: {}, ints: {}, floats: {}, flags: {})
end

# Reads the words one at a time, left to right: the first `--help` or mistake ends the scan.
def scan_words(parser: Parser, slots: List[Slot], args: List[String]) -> Result[Scan]
  reader = Reader(parser: parser, slots: slots, args: args)
  values: Map[String, String] = {}
  words: List[String] = []
  i = 0
  ended = false
  before_dashes = -1
  while i < args.size
    word = args[i]
    if ended or value_word?(word)
      words = words.push(word)
      i = i + 1
    elsif word == "--"
      ended = true
      before_dashes = words.size
      i = i + 1
    else
      step = try read_option(reader, values, i)
      if step.help
        return error("#{HELP_MARK}#{usage(parser)}")
      end
      values = step.values
      i = step.next
    end
  end
  if !ended
    before_dashes = words.size
  end
  return ok(Scan(values: values, positionals: words, before_dashes: before_dashes))
end

# Reads the option at args[i], which starts with "-" and is not "-" or "--".
def read_option(reader: Reader, values: Map[String, String], i: Int) -> Result[Step]
  word = reader.args[i]
  if word.start_with?("--")
    return read_long(reader, values, i)
  end
  return read_short(reader, values, i)
end

# `--name`, `--name=value` or `--name value`.
def read_long(reader: Reader, values: Map[String, String], i: Int) -> Result[Step]
  body = reader.args[i].slice(2, reader.args[i].length - 2)
  equals = body.index_of("=")
  name = body
  if equals.some?
    name = body.slice(0, equals.unwrap!)
  end
  if name == "help"
    return ok(Step(values: values, next: i + 1, help: true))
  end
  slot = try find_slot(reader, name, false)
  if slot.flag
    if equals.some?
      return failure(reader.parser, "option --#{name} does not take a value")
    end
    return ok(Step(values: values.put(name, "true"), next: i + 1, help: false))
  end
  if equals.some?
    text = body.slice(equals.unwrap! + 1, body.length - equals.unwrap! - 1)
    return ok(Step(values: values.put(name, text), next: i + 1, help: false))
  end
  if i + 1 >= reader.args.size or !value_word?(reader.args[i + 1])
    return failure(reader.parser, "option --#{name} needs a value")
  end
  return ok(Step(values: values.put(name, reader.args[i + 1]), next: i + 2, help: false))
end

# `-p value`, `-pvalue`, and flags joined as `-vq` (the last letter may take a value).
def read_short(reader: Reader, values: Map[String, String], i: Int) -> Result[Step]
  letters = reader.args[i].slice(1, reader.args[i].length - 1).split("")
  found = values
  j = 0
  while j < letters.size
    if letters[j] == "h"
      return ok(Step(values: found, next: i + 1, help: true))
    end
    slot = try find_slot(reader, letters[j], true)
    if slot.flag
      found = found.put(slot.name, "true")
      j = j + 1
    elsif j + 1 < letters.size
      return ok(Step(values: found.put(slot.name, joined_value(letters, j + 1)), next: i + 1, help: false))
    elsif i + 1 < reader.args.size and value_word?(reader.args[i + 1])
      return ok(Step(values: found.put(slot.name, reader.args[i + 1]), next: i + 2, help: false))
    else
      return failure(reader.parser, "option --#{slot.name} needs a value")
    end
  end
  return ok(Step(values: found, next: i + 1, help: false))
end

# The rest of a joined short option from letters[from]: `-p3000` and `-p=3000` both give 3000, as in argparse.
def joined_value(letters: List[String], from: Int) -> String
  rest = letters.drop(from).join("")
  if rest.start_with?("=")
    return rest.slice(1, rest.length - 1)
  end
  return rest
end

# Whether a word is an argument or the value of an option, not an option: it does not start with "-", or it is "-" or
# a negative number (`-1`, `-2.5`, `-.5`), as in argparse. Any other word that starts with "-" is an option, so
# `--port --verbose` is a missing value; `--port=--x` and `-p--x` give the literal.
def value_word?(word: String) -> Bool
  if !word.start_with?("-") or word == "-"
    return true
  end
  parts = word.slice(1, word.length - 1).split(".")
  if parts.size == 1
    return digits?(parts[0])
  end
  return parts.size == 2 and (parts[0].empty? or digits?(parts[0])) and digits?(parts[1])
end

# Whether the text is one or more of the digits 0 to 9.
def digits?(text: String) -> Bool
  return !text.empty? and text.split("").all? do |character| "0123456789".include?(character) end
end

# The option with this long name, or with this short name when `short` is true.
def find_slot(reader: Reader, name: String, short: Bool) -> Result[Slot]
  found = reader.slots.find do |slot|
    !slot.positional and ((short and slot.short == name) or (!short and slot.name == name))
  end

  if found.ok?
    return found
  end
  if short
    return failure(reader.parser, "unknown option -#{name}")
  end
  return failure(reader.parser, "unknown option --#{name}")
end

# Matches the positional words to the arguments, converts every value and fills the defaults.
def build(parser: Parser, slots: List[Slot], scan: Scan) -> Result[Parsed]
  positionals = slots.select do |slot| slot.positional end
  if scan.positionals.size < positionals.size
    return failure(parser, "missing argument #{label(positionals[scan.positionals.size])}")
  end
  if scan.positionals.size > positionals.size and parser.rest.empty?
    return failure(parser, "unexpected argument '#{scan.positionals[positionals.size]}'")
  end
  values = scan.values
  for index in 0...positionals.size
    values = values.put(positionals[index].name, scan.positionals[index])
  end
  rest = scan.positionals.drop(positionals.size)
  dashed = scan.positionals.drop(wider(scan.before_dashes, positionals.size))
  parsed = empty_parsed().with(rest: rest, after_dashes: dashed)
  for slot in slots
    parsed = parsed.with(kinds: parsed.kinds.put(slot.name, slot.kind))
    if slot.flag
      parsed = parsed.with(flags: parsed.flags.put(slot.name, values.key?(slot.name)))
    elsif values.key?(slot.name)
      parsed = try given(parser, parsed, slot, values[slot.name])
    elsif !slot.default.empty?
      parsed = try store(parsed, slot, slot.default)
    end
  end
  return ok(parsed)
end

def given(parser: Parser, parsed: Parsed, slot: Slot, text: String) -> Result[Parsed]
  case store(parsed, slot, text)
    ok(stored) -> return ok(stored)
    error(message) -> return failure(parser, "invalid value for #{label(slot)}: #{message}")
  end
end

# Converts `text` by the kind of the slot, checks the choices and puts the value in the map of its kind. The error
# is the end of a sentence: the callers say whose value it is.
def store(parsed: Parsed, slot: Slot, text: String) -> Result[Parsed]
  if !slot.choices.empty? and !slot.choices.any? do |choice| choice == text end
    return error("'#{text}' is not one of #{slot.choices.join(", ")}")
  end
  case slot.kind
    Kind.String -> return ok(parsed.with(strings: parsed.strings.put(slot.name, text)))
    Kind.Int ->
      number = text.to_i
      if !number.ok?
        # Digits that to_i refuses are a number too big for an Int, which is not the same mistake as a word.
        digits = text
        if text.start_with?("-")
          digits = text.slice(1, text.length - 1)
        end
        if digits?(digits)
          return error("'#{text}' does not fit an Int")
        end
        return error("'#{text}' is not an Int")
      end
      if slot.min.some? and number.unwrap! < slot.min.unwrap!
        return error("'#{text}' is below the minimum #{slot.min.unwrap!}")
      end
      if slot.max.some? and number.unwrap! > slot.max.unwrap!
        return error("'#{text}' is above the maximum #{slot.max.unwrap!}")
      end
      return ok(parsed.with(ints: parsed.ints.put(slot.name, number.unwrap!)))
    Kind.Float ->
      number = text.to_f
      if !number.ok?
        return error("'#{text}' is not a Float")
      end
      return ok(parsed.with(floats: parsed.floats.put(slot.name, number.unwrap!)))
    Kind.Flag -> return ok(parsed)
  end
end

def failure[T](parser: Parser, message: String) -> Result[T]
  return error("#{parser.program}: #{message}\nTry '#{parser.program} --help' for more information")
end

# The name as the messages and the help show it: --port, or <file> for an argument.
def label(slot: Slot) -> String
  if slot.positional
    return "<#{shown_name(slot)}>"
  end
  return "--#{slot.name}"
end

def shown_name(slot: Slot) -> String
  if slot.metavar.empty?
    return slot.name
  end
  return slot.metavar
end

def usage_line(parser: Parser, slots: List[Slot]) -> String
  positionals = slots.select do |slot| slot.positional end
  words = [parser.program, "[options]"].concat(positionals.map do |slot| label(slot) end)
  if !parser.rest.empty?
    words = words.push("[#{parser.rest}...]")
  end
  return words.join(" ")
end

# The left column of the help: "-p, --port PORT", "    --user USER", "-v, --verbose" or "<file>".
def head(slot: Slot) -> String
  if slot.positional
    return label(slot)
  end
  names = "    --#{slot.name}"
  if !slot.short.empty?
    names = "-#{slot.short}, --#{slot.name}"
  end
  if slot.flag
    return names
  end
  return "#{names} #{value_name(slot)}"
end

# The value name of an option: the metavar, else the choices (`on|off`), else the name in capitals.
def value_name(slot: Slot) -> String
  if !slot.metavar.empty?
    return slot.metavar
  end
  if !slot.choices.empty?
    return slot.choices.join("|")
  end
  return slot.name.upcase
end

# The notes after the help text, each in brackets so that parentheses in the help text itself read well.
def notes(slot: Slot) -> List[String]
  found: List[String] = []
  if !slot.default.empty?
    found = found.push("[default: #{slot.default}]")
  end
  # The choices are already the value name of an option without a metavar.
  if !slot.choices.empty? and (slot.positional or !slot.metavar.empty?)
    found = found.push("[choices: #{slot.choices.join(", ")}]")
  end
  limits: List[String] = []
  if slot.min.some?
    limits = limits.push("min: #{slot.min.unwrap!}")
  end
  if slot.max.some?
    limits = limits.push("max: #{slot.max.unwrap!}")
  end
  if !limits.empty?
    found = found.push("[#{limits.join(", ")}]")
  end
  return found
end

def wider(a: Int, b: Int) -> Int
  if a > b
    return a
  end
  return b
end

def row(slot: Slot, width: Int) -> String
  text = [slot.help].concat(notes(slot)).select do |part| !part.empty? end.join(" ")
  line = "  #{head(slot)}"
  if text.empty?
    return line
  end
  return "#{line}#{List.repeat(" ", width - head(slot).length).join("")}  #{text}"
end

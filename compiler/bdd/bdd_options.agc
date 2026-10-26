## The arguments of the BDD driver.
##
## `agentica test` (cli.agc, which calls the driver in its own process) gives the driver `DRIVER_OPTIONS -- ARGUMENTS`.
## The driver options say what only the front end knows: `--vm PATH` (the binary, which the driver starts as `agentica
## run` for the runner and the tests), `--version V` (the Agentica version the programs it compiles are written for),
## `--agentica WORD` (once for each word of the command that runs `agentica`), `--style plain|ai|json`,
## `--seed N` and `--test-timeout-ms N`. ARGUMENTS are the words the user wrote after `test`: paths, `--steps FILE`,
## `--only TEXT`, `--tags EXPR`, `--json`, `--ai`, `--no-cache`, the `--deny-*` flags and `--sandbox` (cli.agc adds the
## ones in front of `test`).

import Tags from "std/bdd/tags"

# The flags that the VMs of the user's code get (the test files, the step program and the programs it starts), never
# the runner. A flag given twice counts once.
DENY = Set.new(["--deny-run", "--deny-net", "--deny-fs", "--deny-env", "--deny-native", "--sandbox"])

## Everything a run needs.
export struct Options
  vm: String
  version: String
  agentica: List[String]
  style: String
  seeded: Bool
  seed: Int
  test_timeout_ms: Int
  only: String
  tags: String
  steps: List[String]
  paths: List[String]
  deny: List[String]
  no_cache: Bool
end

## What the arguments are: options to run with; a usage error of the user (RUNTIME-BDD-USAGE, with the options read so
## far, which say how to report it); or a mistake in the driver options, which is a bug of the caller.
export enum Parsed
  Ready(Options)
  Usage(String, Options)
  Broken(String)
end

## Reads the arguments.
export def parse(arguments: List[String]) -> Parsed
  options = Options(
    vm: "",
    version: "",
    agentica: [],
    style: "plain",
    seeded: false,
    seed: 0,
    test_timeout_ms: 30_000,
    only: "",
    tags: "",
    steps: [],
    paths: [],
    deny: [],
    no_cache: false,
  )
  at = 0
  while at < arguments.size and arguments[at] != "--"
    word = arguments[at]
    if at + 1 >= arguments.size
      return Parsed.Broken("#{word} needs a value")
    else
      options = option(options, word, arguments[at + 1])
      at += 2
    end
  end
  if at >= arguments.size
    return Parsed.Broken("the driver options end with --")
  end
  if options.vm == "" or options.version == "" or options.agentica.size == 0
    return Parsed.Broken("--vm, --version and --agentica are required")
  end
  return user_arguments(options, arguments.drop(at + 1))
end

# One driver option with its value. An unknown name or a bad number leaves the options as they are, and the checks of
# parse find what is missing.
def option(options: Options, name: String, value: String) -> Options
  case name
    "--vm" -> return options.with(vm: value)
    "--version" -> return options.with(version: value)
    "--agentica" -> return options.with(agentica: options.agentica.push(value))
    "--style" -> return options.with(style: value)
    "--seed" -> return options.with(seeded: true, seed: value.to_int.unwrap_or(0))
    "--test-timeout-ms" -> return options.with(test_timeout_ms: value.to_int.unwrap_or(options.test_timeout_ms))
    _ -> return options
  end
end

# The words of the user. The last --json or --ai decides the style of every report, usage errors included, so they are
# looked for first, in all the words (a value such as `--only --json` counts too, as it always did).
def user_arguments(options: Options, words: List[String]) -> Parsed
  shown = options
  for word in words
    if word == "--json"
      shown = shown.with(style: "json")
    elsif word == "--ai"
      shown = shown.with(style: "ai")
    end
  end
  at = 0
  while at < words.size
    word = words[at]
    if word == "--steps" or word == "--only" or word == "--tags"
      if at + 1 >= words.size
        return Parsed.Usage("option needs a value", shown)
      end
      value = words[at + 1]
      if word == "--steps"
        shown = shown.with(steps: shown.steps.push(value))
      elsif word == "--tags"
        if shown.tags != ""
          return Parsed.Usage("one --tags EXPR", shown)
        elsif value.strip == ""
          return Parsed.Usage("--tags needs a non-empty EXPR", shown)
        end

        checked = Tags.compile(value)
        if !checked.ok?
          return Parsed.Usage("invalid --tags: #{checked.message}", shown)
        end

        shown = shown.with(tags: value)
      elsif shown.only != ""
        return Parsed.Usage("one --only TEXT", shown)
      elsif value == ""
        return Parsed.Usage("--only needs a non-empty TEXT", shown)
      else
        shown = shown.with(only: value)
      end
      at += 2
    elsif word == "--json" or word == "--ai"
      at += 1
    elsif word == "--no-cache"
      shown = shown.with(no_cache: true)
      at += 1
    elsif DENY.include?(word)
      shown = shown.with(deny: shown.deny.push(word).uniq)
      at += 1
    elsif word.starts_with?("--")
      return Parsed.Usage("unknown option #{word}", shown)
    else
      shown = shown.with(paths: shown.paths.push(word))
      at += 1
    end
  end
  return Parsed.Ready(shown)
end

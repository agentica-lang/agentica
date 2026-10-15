## The arguments of the BDD driver.
##
## `agentica test` (src/main.rkt, src/bdd-driver.rkt) starts the driver as `DRIVER_OPTIONS -- ARGUMENTS`. The driver
## options say what only the front end knows: `--vm PATH` (the VM that runs the runner and the tests), `--agentica
## WORD` (once for each word of the command that runs `agentica`), `--style plain|ai|json`, `--allow-run`, `--seed N`
## and `--test-timeout-ms N`. ARGUMENTS are the words the user wrote after `test`: paths, `--steps FILE`, `--only
## TEXT`, `--json`, `--ai` and `--allow-run`. The `std/` sources come on stdin (bdd_driver.agc).

## Everything a run needs.
export struct Options
  vm: String
  agentica: List[String]
  style: String
  allow_run: Bool
  seeded: Bool
  seed: Int
  test_timeout_ms: Int
  only: String
  steps: List[String]
  paths: List[String]
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
    agentica: [],
    style: "plain",
    allow_run: false,
    seeded: false,
    seed: 0,
    test_timeout_ms: 30000,
    only: "",
    steps: [],
    paths: [],
  )
  at = 0
  while at < arguments.size and arguments[at] != "--"
    word = arguments[at]
    if word == "--allow-run"
      options = options.with(allow_run: true)
      at += 1
    elsif at + 1 >= arguments.size
      return Parsed.Broken("#{word} needs a value")
    else
      options = option(options, word, arguments[at + 1])
      at += 2
    end
  end
  if at >= arguments.size
    return Parsed.Broken("the driver options end with --")
  end
  if options.vm == "" or options.agentica.size == 0
    return Parsed.Broken("--vm and --agentica are required")
  end
  return user_arguments(options, arguments.drop(at + 1))
end

# One driver option with its value. An unknown name or a bad number leaves the options as they are, and the checks of
# parse find what is missing.
def option(options: Options, name: String, value: String) -> Options
  if name == "--vm"
    return options.with(vm: value)
  elsif name == "--agentica"
    return options.with(agentica: options.agentica.push(value))
  elsif name == "--style"
    return options.with(style: value)
  elsif name == "--seed"
    return options.with(seeded: true, seed: value.to_int.unwrap_or(0))
  elsif name == "--test-timeout-ms"
    return options.with(test_timeout_ms: value.to_int.unwrap_or(options.test_timeout_ms))
  end
  return options
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
    if word == "--steps" or word == "--only"
      if at + 1 >= words.size
        return Parsed.Usage("option needs a value", shown)
      end
      value = words[at + 1]
      if word == "--steps"
        shown = shown.with(steps: shown.steps.push(value))
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
    elsif word == "--allow-run"
      shown = shown.with(allow_run: true)
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

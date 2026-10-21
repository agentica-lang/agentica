## The fixed texts of the command line: the usage lines for bad arguments, and the help (`agentica help` prints
## SUMMARY and the namespaces of the builtins; `-h` and `--help` print HELP_FIRST_LINE, the SUMMARY indented by two
## spaces, and OPTIONS, the list of the options). tests/test_cli_forms.py
## compares them with a golden.

# What a command line that names no source file gets on stderr (exit code 2), one line each.
USAGE = [
  [
    "usage: agentica [--version] [--dump] [--dump-ir] [--ai|--json] [--max-steps N] [--seed N] [--flush-timeout MS] ",
    "[--schedulers N] [--allow-run] [check] <source-file> [args...]",
  ].join(""),
  "       agentica [--ai|--json] check --stdin <source-file>",
  "       agentica [--ai|--json] compile <source-file> -o <file.agcb>",
  "       agentica help [NAME] [--json]",
  "       agentica [--ai|--json] doc <path> [--json]",
  "       agentica [--ai|--json] outline <source-file> [--json]",
  "       agentica [--ai|--json] outline --stdin <source-file> [--json]",
  "       agentica [--ai|--json] type-at <source-file>:LINE:COL [--json]",
  "       agentica [--ai|--json] type-at --stdin <source-file>:LINE:COL [--json]",
  "       agentica [--ai|--json] [--allow-run] [--seed N] test [PATH...] [--steps FILE] [--only TEXT]",
  "       agentica run [OPTIONS] -- <file.agcb> [args...]",
]

# The first line of the help of `-h`.
HELP_FIRST_LINE = "usage: agentica [ <option> ... ] [<arguments>] ..."

# The lines of the summary: the commands and the core rules.
SUMMARY = [
  "Programs run on the bytecode VM.",
  "Commands:",
  "  agentica [options] FILE.agc [ARGS...]   run a program; System.args() reads ARGS",
  "  agentica check FILE.agc                 check only: prints \"check ok\" or the first diagnostic",
  "  agentica check --stdin FILE.agc         check the text on standard input as if FILE.agc held it",
  "  agentica test [PATH...] [--steps FILE] [--only TEXT]",
  "                                          run *_test.agc and .feature files (default PATH: test/ and specs/);",
  "                                          --steps FILE is the step program of the .feature files",
  "  agentica compile FILE.agc -o OUT.agcb   write bytecode",
  "  agentica run [OPTIONS] -- FILE.agcb [ARGS...]",
  "                                          run a compiled program; OPTIONS: --max-steps N, --seed N,",
  "                                          --flush-timeout MS, --schedulers N, --allow-run, --source-root DIR,",
  "                                          --ai, --json",
  "  agentica doc PATH [--json]              exported API of a file or a std/ module, with its ## docs (parse only)",
  "  agentica outline FILE [--json]          declarations of a file or a std/ module, private ones too, with docs",
  "                                          and spans (parse only); --stdin FILE reads the file from standard input",
  "  agentica type-at FILE:LINE:COL          type and definition of the expression at a position (checks FILE and",
  "                                          its imports, needs no main); --stdin reads FILE from standard input",
  "  agentica help NAME [--json]             signature and description of a builtin, e.g. agentica help String.split",
  "  agentica help [--json]                  this summary and the builtin namespaces;",
  "                                          --json prints every builtin as a JSON array",
  "Core rules:",
  "  - A program starts at `def main() -> Void`. Calls always use parentheses: puts(\"hi\").",
  "  - Ruby syntax: no semicolons and no braces for blocks; blocks end with \"end\".",
  "  - Values are immutable: methods return new values, so assign them: xs = xs.push(2), m = Map.put(m, k, v).",
  "  - A block (do |x| ... end) cannot assign an outer variable (CHECK-CAPTURED-ASSIGNMENT):",
  "    use `for x in xs ... end`, or xs.reduce(0) do |acc, x| ... end.",
  [
    "  - Fallible builtins return Result[T] (ok(v) or error(msg)); `try expr` in a function returning Result passes ",
    "the error up.",
  ].join(""),
]

# The lines of `-h` after the summary: the options.
OPTIONS = [
  "",
  "<option> is one of",
  "",
  "  --version",
  "     print the version and exit",
  "  --allow-run",
  "     allow Process.spawn to run child programs",
  "  --max-steps <count>",
  "     limit execution to N expression/statement entries",
  "  --seed <n>",
  "     seed Random with N (0..2147483647) for repeatable runs",
  "  --flush-timeout <ms>",
  [
    "     wait at most MS milliseconds for file data and buffered output at the end of the run (default 30000; ",
    "AGENTICA_FLUSH_TIMEOUT_MS sets it too, the flag wins)",
  ].join(""),
  "  --schedulers <n>",
  [
    "     run on N scheduler threads, 1 to 1024 (default: one per logical core; AGENTICA_SCHEDULERS sets it too, ",
    "the flag wins over a valid value); 1 runs one task at a time, in a fixed order",
  ].join(""),
  "  --dump",
  "     print the checked tree instead of running it",
  "  --dump-ir",
  "     print the lowered VM IR instead of running it",
  "  --ai",
  "     print diagnostics as compact text for an agent",
  "  --json",
  "     print diagnostics as one JSON object",
  "* --steps <path>",
  "     the step program of agentica test",
  "  --help, -h",
  "     Show this help",
  "  --",
  "     Do not treat any remaining argument as a switch (at this level)",
  "",
  " *   Asterisks indicate options allowed multiple times.",
  "",
  " Multiple single-letter switches can be combined after",
  " one `-`. For example, `-h-` is the same as `-h --`.",
]

## What a command line gets when it names `run` after other words: `agentica run` is answered before the options of the
## command line are read, so it must be the first word.
export def run_first_text() -> String
  return "agentica: run must be the first word, before any option: agentica run [OPTIONS] -- <file.agcb> [args...]\n"
end

## What `test` says when the front end does not know the path of the binary that it has to start again.
export def test_without_binary_text() -> String
  return "agentica: the test command needs the path of the binary, which this front end was not given (--self)\n"
end

## The usage lines, each ending with a line feed.
export def usage_text() -> String
  return "#{USAGE.join("\n")}\n"
end

## The summary of the commands and the core rules: the lines of `agentica help` before the namespaces, each ending with
## a line feed.
export def summary_text() -> String
  return "#{SUMMARY.join("\n")}\n"
end

## The help of `-h` and `--help`.
export def help_text() -> String
  lines = [HELP_FIRST_LINE].concat(SUMMARY.map do |line: String| "  #{line}" end).concat(OPTIONS)
  return "#{lines.join("\n")}\n"
end

## The fixed texts of the command line: the usage lines for bad arguments, and the help (`agentica help` prints
## SUMMARY and the namespaces of the builtins; `-h` and `--help` print HELP_FIRST_LINE, the SUMMARY indented by two
## spaces, and OPTIONS, the list of the options). tests/test_cli_forms.py
## compares them with a golden.

## What a command line gets when it names `run` after other words: `agentica run` is answered before the options of the
## command line are read, so it must be the first word.
def run_first_text() -> String
  "agentica: run must be the first word, before any option: agentica run [OPTIONS] -- <file.agcb> [args...]\n"
end

## What `test` says when the front end does not know the path of the binary that it has to start again.
def test_without_binary_text() -> String
  "agentica: the test command needs the path of the binary, which this front end was not given (--self)\n"
end

## The usage lines, each ending with a line feed.
def usage_text() -> String = "#{USAGE.join("\n")}\n"

## The summary of the commands and the core rules: the lines of `agentica help` before the namespaces, each ending with
## a line feed.
def summary_text() -> String = "#{SUMMARY.join("\n")}\n"

## The help of `agentica COMMAND --help`: the usage lines of the command, as `agentica` prints them for a bad command
## line but without the options that come before the command, then the part of the summary that describes it. "" for a
## word that is no command with a help.
def command_help_text(command: String) -> String
  forms = usage_forms(command)
  return "" if forms.size == 0

  first = "usage: agentica #{forms[0]}"
  more = forms.drop(1).map do |form: String| "       agentica #{form}" end
  lines = [first].concat(more).concat([""]).concat(summary_block(command)).concat(["", HELP_MORE])
  "#{lines.join("\n")}\n"
end

## The help of `-h` and `--help`.
def help_text() -> String
  lines = [HELP_FIRST_LINE].concat(SUMMARY.map do |line: String| "  #{line}" end).concat(OPTIONS)
  "#{lines.join("\n")}\n"
end

private

# The words that start the usage lines of a command in USAGE, before the command, and the options that may follow them.
USAGE_MARGIN = "       agentica "
USAGE_OPTIONS = ["[--ai|--json] ", "[--seed N] [--no-cache] "]
HELP_MORE = "Options that come before the command (--json, --ai, --max-steps, ...): agentica --help"

# What a command line that names no source file gets on stderr (exit code 2), one line each.
USAGE = [
  [
    "usage: agentica [--version] [--dump] [--dump-ir] [--ai|--json] [--max-steps N] [--max-heap SIZE] [--seed N] ",
    "[--flush-timeout MS] [--schedulers N] [--jit MODE] [--deny-run] [--deny-net] [--deny-fs] [--deny-env] ",
    "[--deny-native] [--sandbox] [--native-build[=NAMES]] [--native-prebuilt-only[=NAMES]] [--no-cache] ",
    "[--coverage FILE] <source-file> [args...]",
  ].join(""),
  "       agentica [--ai|--json] check [PATH...]",
  "       agentica [--ai|--json] check --stdin <source-file>",
  "       agentica [--ai|--json] compile <source-file> -o <file.agcb>",
  "       agentica [--ai|--json] compile [<source-file>...]",
  "       agentica [--ai|--json] fmt [--check] [PATH...]",
  "       agentica [--ai|--json] fmt -",
  "       agentica [--ai|--json] lint [PATH...] [--strict]",
  "       agentica repl [--json | --ai]",
  "       agentica help [NAME|std/MODULE[.NAME]] [--json]",
  "       agentica [--ai|--json] doc <path> [--json]",
  "       agentica [--ai|--json] outline <source-file> [--json] [--partial]",
  "       agentica [--ai|--json] outline --stdin <source-file> [--json] [--partial]",
  "       agentica [--ai|--json] symbol NAME [PATH...] [--json]",
  "       agentica [--ai|--json] symbol NAME [PATH...] --stdin <source-file> [--json]",
  "       agentica [--ai|--json] type-at <source-file>:LINE:COL [--json] [--partial]",
  "       agentica [--ai|--json] type-at --stdin <source-file>:LINE:COL [--json] [--partial]",
  "       agentica [--ai|--json] refs NAME [PATH...] [--json]",
  "       agentica [--ai|--json] refs <source-file>:LINE:COL [PATH...] [--json] [--partial]",
  "       agentica [--ai|--json] refs --stdin <source-file>:LINE:COL [PATH...] [--json] [--partial]",
  "       agentica [--ai|--json] install",
  "       agentica [--ai|--json] init [NAME]",
  [
    "       agentica [--ai|--json] add NAME URL|OWNER/REPO --tag TAG|--ref COMMIT|--version REQ ",
    "[--subdir DIR|--workspace] [--group test]",
  ].join(""),
  "       agentica [--ai|--json] update [NAME]",
  "       agentica [--ai|--json] native source NAME",
  [
    "       agentica [--ai|--json] [--seed N] [--no-cache] test [PATH...] [--steps FILE] [--only TEXT] [--tags EXPR] ",
    "[--jobs N] [--max-steps N|unlimited] [--timing] [--coverage] [--isolate]",
  ].join(""),
  "       agentica run [OPTIONS] -- <file.agcb> [args...]",
]

# The first line of the help of `-h`.
HELP_FIRST_LINE = "usage: agentica [ <option> ... ] [<arguments>] ..."

# The lines of the summary: the commands and the core rules.
SUMMARY = [
  "Programs run on the bytecode VM.",
  "Commands:",
  "  agentica [options] FILE.agc [ARGS...]   run a program; System.args() reads ARGS",
  "  agentica check [PATH...]                check only: prints \"check ok\" or the first diagnostic; a folder",
  "                                          is every .agc file under it (default PATH: the current folder, without",
  "                                          deps/ and hidden folders), and several files end with a count",
  "  agentica check --stdin FILE.agc         check the text on standard input as if FILE.agc held it",
  "  agentica repl [--json | --ai]           run entries one at a time; their names, declarations and tasks live",
  "                                          on; :type, :load, :reset, :quit, :help",
  "  agentica fmt [PATH...]                  format the .agc files in place (default PATH: the current folder);",
  "                                          --check lists the files it would change and exits 1 if any;",
  "                                          - formats standard input to standard output; [style] of agentica.toml",
  "                                          sets max_line_width (default 119) and blank_line_after_end; a file",
  "                                          whose name starts with - is written ./-x.agc",
  "  agentica lint [PATH...] [--strict]      suggest changes from the style guide for the .agc files (default PATH:",
  "                                          the current folder); suggestions exit 0, --strict exits 1 for any;",
  "                                          --json prints one document",
  "  agentica test [PATH...] [--steps FILE] [--only TEXT] [--tags EXPR]",
  "                                          [--jobs N] [--max-steps N|unlimited] [--timing] [--coverage]",
  "                                          [--isolate]",
  "                                          run *_test.agc and .feature files (default PATH: test/ and specs/);",
  "                                          --steps FILE is the step program of the .feature files (default:",
  "                                          the nearest steps.agc in or above the folder of each PATH, up to",
  "                                          the current folder);",
  "                                          --tags EXPR keeps the scenarios whose tags match, as in",
  "                                          \"@db and not @slow\" (not, and, or);",
  "                                          --jobs N runs up to N scenarios or test files at once (1 to 1024,",
  "                                          default 1);",
  "                                          --max-steps N gives each test (each step of a scenario) N steps and",
  "                                          the start of each file or scenario N more (default 1000000);",
  "                                          unlimited sets no limit;",
  "                                          --timing adds the time of the run, of each file and of the 5",
  "                                          slowest scenarios;",
  "                                          --coverage writes the line coverage to coverage/lcov.info (LCOV);",
  "                                          --isolate runs each scenario in a child of its own (default: each",
  "                                          job slot reuses one child while its scenarios pass)",
  "  agentica install                        fetch the packages of agentica.lock with git (a package already in",
  "                                          the package cache is not fetched) and write them to deps/NAME/;",
  "                                          the lock is never changed",
  "  agentica init [NAME]                    start a project in the working folder: write agentica.toml (NAME,",
  "                                          default the folder name, and the running version) and, when there is",
  "                                          none, main.agc; an existing agentica.toml is never changed",
  "  agentica add NAME URL|OWNER/REPO --tag TAG|--ref COMMIT|--version REQ [--subdir DIR|--workspace] [--group test]",
  "                                          add a dependency to agentica.toml, fetch it with git, write",
  "                                          agentica.lock and deps/ (the other lines of agentica.toml stay);",
  "                                          OWNER/REPO is https://github.com/OWNER/REPO;",
  "                                          --subdir DIR: the package is that folder of the repository (a tag",
  "                                          NAME-X.Y.Z takes the folder NAME when the package is there and",
  "                                          not at the root);",
  "                                          --workspace: the whole workspace of the repository (its members",
  "                                          are imported as pkg/NAME/MEMBER/MODULE);",
  "                                          --group test: only the tests import it",
  "  agentica update [NAME]                  fetch the tag pins again (all, or the dependency NAME), rewrite",
  "                                          agentica.lock and refresh deps/; a commit pin and a package already",
  "                                          locked do not move",
  "  agentica native source NAME             the source key of the native module NAME (its build table and the",
  "                                          files of native/), the native API of this agentica and the URL of",
  "                                          each target of its prebuilt table, for the files a release uploads",
  "  agentica compile FILE.agc -o OUT.agcb   write bytecode",
  "  agentica compile [FILE...]              fill the bytecode cache, so the next runs start at once; no FILE:",
  "                                          every main.agc under the working folder, outside tests/ and fixtures/",
  "  agentica run [OPTIONS] -- FILE.agcb [ARGS...]",
  "                                          run a compiled program; OPTIONS: --max-steps N, --max-heap SIZE,",
  "                                          --seed N, --flush-timeout MS, --schedulers N, --jit MODE, the --deny-*",
  "                                          flags, --sandbox, --source-root DIR, --coverage FILE, --ai, --json",
  "  agentica doc PATH [--json]              exported API of a file or a std/ module, with its ## docs",
  "  agentica outline FILE [--json]          declarations of a file or a std/ module, private ones too, with docs",
  "                                          and spans; --stdin FILE reads the file from standard input",
  "  agentica symbol NAME [PATH...]          where a name is defined in the files under PATH (default .) and",
  "                                          what they import; --stdin FILE reads one more file from standard input",
  "  agentica type-at FILE:LINE:COL          type and definition of the expression at a position (checks FILE and",
  "                                          its imports, needs no main); --stdin reads FILE from standard input;",
  "                                          --partial answers although some functions do not check",
  "  agentica refs NAME|FILE:LINE:COL [PATH...]",
  "                                          every reference to a declaration, builtin or local, by name or at a",
  "                                          position, in the files linked from FILE and PATH... (a NAME searches .",
  "                                          by default) and what they import (checks them, needs no main);",
  "                                          --partial as type-at, for a position without PATH...",
  "  agentica help NAME [--json]             signature and description of a builtin, e.g. agentica help String.split",
  "  agentica help std/MODULE[.NAME] [--json]",
  "                                          the exports of a std/ module with their summaries, or the signature",
  "                                          and ## doc of one, e.g. agentica help std/queue.pop",
  "  agentica help [--json]                  this summary and the builtin namespaces;",
  "                                          --json prints every builtin as a JSON array",
  "Core rules:",
  "  - A program starts at `def main() -> Void`. Calls always use parentheses: puts(\"hi\").",
  "  - Ruby syntax: no semicolons; a block is do ... end, or { ... } after a call without arguments.",
  "  - Values are immutable: methods return new values, so assign them: xs = xs.push(2), m = m.put(k, v).",
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
  "  --deny-run",
  "     make the Process starts and System.signal return an error",
  "  --deny-net",
  "     make TCP, TLS and HTTP connections and listeners return an error",
  "  --deny-fs",
  "     make the File, Dir and Path calls (but Path.join) return an error",
  "  --deny-env",
  "     make System.env return an error",
  "  --deny-native",
  [
    "     refuse a program that declares extern functions (native code), before it starts; every --deny-* flag ",
    "turns it on",
  ].join(""),
  "  --sandbox",
  "     all the --deny-* flags, for code you do not trust",
  "  --native-build[=NAMES]",
  [
    "     build the native modules NAMES (a,b; all without =) from source, never from their prebuilt files ",
    "(AGENTICA_NATIVE_BUILD sets it too, the flag wins)",
  ].join(""),
  "  --native-prebuilt-only[=NAMES]",
  [
    "     use only the prebuilt files of the native modules NAMES (all without =), never a build ",
    "(AGENTICA_NATIVE_PREBUILT_ONLY sets it too, the flag wins)",
  ].join(""),
  "  --max-steps <count>",
  "     limit execution to N expression/statement entries",
  "  --max-heap <size>",
  [
    "     end the run (RUNTIME-HEAP-LIMIT, exit code 70) when the program's memory would grow past SIZE: bytes, or ",
    "with K, M or G, such as 256M",
  ].join(""),
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
  "  --jit <mode>",
  [
    "     off, on or always: compile hot functions to machine code (on by default, x86-64 and arm64; ",
    "AGENTICA_JIT sets it too, the flag wins); always compiles each function at its first call",
  ].join(""),
  "  --coverage <file>",
  [
    "     write the LCOV of the lines that ran to FILE at the end of the run (std/ and fetched packages left out); ",
    "the program runs with the JIT off",
  ].join(""),
  "  --dump",
  "     print the checked tree instead of running it",
  "  --dump-ir",
  "     print the lowered VM IR instead of running it",
  "  --no-cache",
  [
    "     compile the program again and do not keep its bytecode; by default the bytecode of a program that ",
    "did not change is read from _build/bytecode/ in the project (AGENTICA_BUILD_DIR replaces _build/)",
  ].join(""),
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

# The forms of `command` in USAGE, each without the margin and the options before the command.
def usage_forms(command: String) -> List[String]
  forms: List[String] = []
  for line in USAGE.drop(1)
    form = line.slice(USAGE_MARGIN.length, line.length - USAGE_MARGIN.length)
    for option in USAGE_OPTIONS
      if form.start_with?(option)
        form = form.slice(option.length, form.length - option.length)
      end
    end

    if form == command or form.start_with?("#{command} ")
      forms = forms.push(form)
    end
  end

  forms
end

# The lines of SUMMARY that describe `command`: from each line `  agentica COMMAND ...` to the next line that starts
# another command.
def summary_block(command: String) -> List[String]
  lines: List[String] = []
  inside = false
  for line in SUMMARY.drop(2)
    break if line == "Core rules:"

    if line.start_with?("  agentica ")
      inside = line.strip.split(" ")[1] == command
    end

    if inside
      lines = lines.push(line)
    end
  end

  lines
end

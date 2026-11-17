/*
 * The agentica binary (dist/agentica), the only program of the
 * product. `agentica run [OPTIONS] -- FILE.agcb [ARGS...]` runs a compiled program with the VM flags and
 * starts no front end. Anything else is the command line of the front end, a compiled program carried in
 * the binary: it runs in a first runtime, compiles in memory and hands the program over
 * (FrontEnd.hand_off); this file retires that runtime and runs the program in a second one, so the
 * options and the heap are the program's alone. `--front-end FILE.agcb` (build-only) loads another front
 * end in place of the carried one. Design: docs/vm/08-loader-and-cli.md.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "core.h"
#include "embedded.h"
#include "launch.h"
#include "services.h"
#include "tls.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

/* How the launcher ended (run_launcher). */
typedef enum { LAUNCHER_DECLINED, LAUNCHER_MISSED, LAUNCHER_HANDED } launcher_end;

/* The exit status of a launcher that looked for the cache entry of the run and found none it could use
 * (MISSED_STATUS in compiler/app/cli_hit.agc): the front end is told, and does not look again. */
#define AGC_LAUNCHER_MISSED 3

static const char name[] = "agentica";
static const char run_name[] = "agentica run";

static const char usage[] =
  "usage: agentica run [--version] [--max-steps N] [--max-heap SIZE] [--seed N] [--flush-timeout MS] "
  "[--schedulers N] [--jit MODE] [--deny-run] "
  "[--deny-net] [--deny-fs] [--deny-env] [--deny-native] [--sandbox] [--ai|--json] [--source-root DIR] "
  "[--coverage FILE] -- <file.agcb> [args...]\n"
  "  --source-root DIR is put before each stored source name that is relative and does not start with std/, in diagnostics and reports\n"
  "  the file flush at the end of the run waits at most 30000 ms, or MS, or AGENTICA_FLUSH_TIMEOUT_MS (the flag wins, at most 86400000)\n"
  "  the run uses one scheduler per logical core (at most 1024), or N (1 to 1024), or AGENTICA_SCHEDULERS (the flag "
  "wins); --schedulers 1 runs one task at a time, in a fixed order\n"
  "  --jit MODE (off, on or always; or AGENTICA_JIT, the flag wins) compiles hot functions to machine code: "
  "on by default, x86-64 and arm64\n"
  "  --coverage FILE writes the LCOV of the lines that ran to FILE at the end of the run (with the JIT off)\n";

/* The std/ sources of the binary, from the index that make wrote. The rows point only into agc_embedded_data, which
 * is static, so the array holds no GC pointer and is atomic. */
static agc_std_source *std_sources(size_t *count) {
  size_t n = (size_t)agc_embedded_index[8];
  agc_std_source *sources = agc_alloc_atomic(agc_size_mul(n ? n : 1, sizeof *sources));
  for (size_t k = 0; k < n; k++) {
    const uint64_t *row = agc_embedded_index + 9 + 3 * k;
    const char *path = (const char *)agc_embedded_data + row[0];
    sources[k] = (agc_std_source){path, agc_embedded_data + row[1], (size_t)row[2]};
  }
  *count = n;
  return sources;
}

/* The program that `run --embedded WHICH` runs: the BDD runner or the default step program of `agentica test`, compiled
 * when the binary was built. NULL for another name; the length is 0 when this binary carries none (the first binary of
 * the bootstrap, which cannot compile them). */
static const uint8_t *embedded_program(const char *which, size_t *len) {
  size_t slot;
  if (strcmp(which, "runner") == 0)
    slot = 2;
  else if (strcmp(which, "steps") == 0)
    slot = 4;
  else
    return NULL;
  *len = (size_t)agc_embedded_index[slot + 1];
  return agc_embedded_data + agc_embedded_index[slot];
}

/* One run of a program that may hand a program over: the front end, or the launcher before it. It returns only in two
 * cases. The first: the program handed a program over and its run ended cleanly. The second: it is the launcher and it
 * declined, by ending without a hand-off (its status and its way of ending do not matter: the front end runs next and
 * does the whole work). A launcher that crashed declines too, and its diagnostic is not printed: the front end looks
 * the entry up again and reports what is wrong, once and in the style of the run. Every other end of the front end (a
 * usage error, a problem in the user's file, a crash, a stop signal) is the end of the process. The status is the one
 * the front end gave, except for a crash: a runtime error in the front end is a bug of the compiler or of `agentica
 * test`'s driver, not a problem in the user's program (status 1), and a driver that crashed must not look like a test
 * run that failed, so it is status 2, like a front end started wrongly. What the run allocated is garbage once it
 * returns.
 *
 * The front end may start processes whatever the user's --deny-* flags: `agentica test` starts the runner and the
 * programs under test from here. That is no loophole for the user's program, which never runs in this runtime: the
 * front end only compiles it. */
static int run_stage(agc_launch *launch, agc_program *program, bool launcher, const char *self, bool replacement,
                     bool missed, int count, char **words, agc_front_end *fe) {
  /* The inputs of the front end (compiler/app/front_end_inputs.agc), then the words of the user. A front end of
   * --front-end gets no --self, and a front end with no --self uses no cache (#1489): the key of a cache entry names
   * the binary, not the front end, so it would get a program that another front end compiled. Without --self it
   * cannot run `agentica test`, which starts the binary again, and the bootstrap does not need that. */
  char version_flag[] = "--version", self_flag[] = "--self", bdd_flag[] = "--embedded-bdd",
       missed_flag[] = "--cache-missed", tty_flag[] = "--stderr-tty", separator[] = "--", version[] = AGC_VERSION;
  /* The front end comes from this build when the binary carries the BDD programs that it compiled: the first binary
   * of the bootstrap carries stage0 and none of them. Only such a front end knows --embedded-bdd and --stderr-tty. */
  bool this_build = !replacement && agc_embedded_index[3] != 0 && agc_embedded_index[5] != 0;
  bool embedded_bdd = this_build;
  bool tty = this_build && agc_launch_stderr_tty();
  int input_count = 3 + (replacement ? 0 : 2) + (embedded_bdd ? 1 : 0) + (missed ? 1 : 0) + (tty ? 1 : 0);
  char **arguments = agc_alloc(agc_size_mul((size_t)count + (size_t)input_count, sizeof *arguments));
  arguments[0] = version_flag;
  arguments[1] = version;
  int separator_at = 2;
  if (!replacement) {
    arguments[separator_at++] = self_flag;
    arguments[separator_at++] = (char *)self;
  }
  if (embedded_bdd) arguments[separator_at++] = bdd_flag;
  if (missed) arguments[separator_at++] = missed_flag;
  if (tty) arguments[separator_at++] = tty_flag;
  arguments[separator_at++] = separator;
  for (int k = 0; k < count; k++) arguments[separator_at + k] = words[k];
  agc_launch_options options;
  agc_launch_defaults(&options);
  agc_vm *vm = agc_launch_vm(launch, program, &options, agc_launch_args(count + input_count, arguments, 0), fe);
  agc_outcome outcome = agc_vm_run(vm);
  bool crashed = outcome.kind == AGC_FAILED;
  if (crashed && launcher) outcome = (agc_outcome){.kind = AGC_DONE};
  int status = agc_launch_settle(vm, &outcome);
  if (crashed) status = 2;
  bool stopped = agc_io_stop_signal();
  bool handed = fe->handed && outcome.kind == AGC_EXITED && status == 0;
  if (stopped || (!handed && !launcher)) {
    agc_output_end(vm);
    agc_launch_exit(status);
  }
  /* A job that is still running would keep this run's loop alive next to the next one's: the program must not share
   * a process with anything of the compiler, so this is the end of the run. */
  if (!agc_io_close(vm)) {
    fprintf(stderr, "%s: internal error: the %s left an operation running\n", name,
            launcher ? "launcher" : "front end");
    fflush(stderr);
    agc_launch_exit(1);
  }
  if (!handed) fe->handed = false;
  return crashed || outcome.kind != AGC_EXITED ? 0 : status;
}

/* False when the words cannot be a run that the cache serves, the one case of the launcher: there is no word, the
 * first word that is no option is a command, or an option before it turns the cache off (--no-cache, --dump,
 * --dump-ir). This is a hint that saves the launcher's start, not a rule: the launcher reads the words as the front
 * end does and declines what is not its case, so a command missing here only costs time. The list is
 * CliRun.COMMANDS (compiler/app/cli_run.agc; tests/test_bytecode_cache.py compares the two). */
static bool may_run_a_file(int count, char **words) {
  static const char *const commands[] = {"test",    "help",    "doc",    "fmt",  "lint", "install", "add",     "update",
                                         "outline", "type-at", "symbol", "refs", "run",  "check",   "compile", "repl"};
  for (int k = 0; k < count; k++) {
    const char *word = words[k];
    if (strcmp(word, "--no-cache") == 0 || strcmp(word, "--dump") == 0 || strcmp(word, "--dump-ir") == 0)
      return false;
    if ((word[0] == '-' || word[0] == '+') && word[1] != '\0') continue;
    for (size_t c = 0; c < sizeof commands / sizeof commands[0]; c++)
      if (strcmp(word, commands[c]) == 0) return false;
    return true;
  }
  return false;
}

/* The launcher (compiler/embedded/launcher.agc): a small program that starts a run whose bytecode is in the cache, so
 * such a start does not load the front end. It runs first when this binary carries one and no --front-end was given.
 * A launcher that does not load is skipped: the front end says what is wrong with the binary, if anything is. */
static launcher_end run_launcher(agc_launch *launch, const char *self, int count, char **words, agc_front_end *fe) {
  size_t len = (size_t)agc_embedded_index[7];
  if (len == 0 || !may_run_a_file(count, words)) return LAUNCHER_DECLINED;
  agc_program *program = NULL;
  char error[160];
  if (!agc_load_front_end(agc_embedded_data + agc_embedded_index[6], len, &program, error, sizeof error, &launch->trace))
    return LAUNCHER_DECLINED;
  int status = run_stage(launch, program, true, self, false, false, count, words, fe);
  if (fe->handed) return LAUNCHER_HANDED;
  return status == AGC_LAUNCHER_MISSED ? LAUNCHER_MISSED : LAUNCHER_DECLINED;
}

/* The front end: the carried one, or the file of --front-end. */
static void run_front_end(agc_launch *launch, const char *self, const char *replacement, bool missed, int count,
                          char **words, agc_front_end *fe) {
  size_t len = (size_t)agc_embedded_index[1];
  const uint8_t *bytes = agc_embedded_data + agc_embedded_index[0];
  if (replacement && !(bytes = agc_launch_file(replacement, false, &len))) {
    fprintf(stderr, "%s: cannot read %s\n", name, replacement);
    exit(2);
  }
  agc_program *program = NULL;
  char error[160];
  if (!agc_load_front_end(bytes, len, &program, error, sizeof error, &launch->trace)) {
    fprintf(stderr, "%s: invalid front end: %s\n", name, error);
    exit(2);
  }
  run_stage(launch, program, false, self, replacement != NULL, missed, count, words, fe);
}

/* The second run: the program that the front end handed over, with the options it passed on. It returns only to
 * report a start that failed. The options are those of `agentica run` (--ai, --json, the --deny-* flags, --sandbox,
 * --max-steps, --max-heap, --seed, --flush-timeout, --schedulers, --jit, --source-root, --coverage), each once. The
 * front end is trusted with them, but --driver-pid is not one: it names the process that started this one, which only
 * that process can say, so the front end cannot. The counts are capped by the hand-off (AGC_FRONT_END_MAX_OPTIONS and
 * _ARGUMENTS), so they fit an int. */
static int run_program(agc_launch *launch, const agc_front_end *fe) {
  agc_launch_options options;
  int at = 0;
  int option_count = (int)fe->option_count;
  agc_launch_status status = agc_launch_parse(name, option_count, fe->options, &at, &options);
  if (status == AGC_LAUNCH_BAD) return 2;
  if (status == AGC_LAUNCH_VERSION || at != option_count) {
    fprintf(stderr, "%s: the front end passed %s, which is not an option of a run\n", name, fe->options[at]);
    return 2;
  }
  if (options.seen_driver) {
    fprintf(stderr, "%s: the front end passed --driver-pid, which only the process that started %s may name\n", name,
            name);
    return 2;
  }
  if (options.embedded || options.session) {
    fprintf(stderr, "%s: the front end passed %s, which only %s takes\n", name,
            options.embedded ? "--embedded" : "--session", run_name);
    return 2;
  }
  if (!agc_launch_env(name, &options) || !agc_launch_supported(name, &options)) return 2;
  agc_program *program = NULL;
  char error[160];
  if (!agc_load_traced(fe->program, fe->program_len, &program, error, sizeof error, &launch->trace)) {
    fprintf(stderr, "%s: invalid bytecode: %s\n", name, error);
    return 2;
  }
  if (!agc_program_set_source_root(program, options.source_root, options.source_root_chars)) {
    fprintf(stderr, "%s: --source-root is too long for this program\n", name);
    return 2;
  }
  if (!agc_launch_native(program, &options)) return 2;
  agc_gc_collect();
  agc_value args = agc_launch_args((int)fe->argument_count, fe->arguments, 0);
  agc_vm *vm = agc_launch_vm(launch, program, &options, args, NULL);
  agc_launch_end(vm, agc_vm_run(vm));
}

static void print_version(void) {
  unsigned gc = agc_gc_version();
  const char *uv = agc_uv_version();
  const char *ssl = agc_tls_version();
  const char *trace = AGC_TRACE_BUILD ? "" : ", trace off";
  if (gc)
    printf("agentica %s (libgc %u.%u.%u, yyjson %s%s%s%s%s%s)\n", AGC_VERSION, gc >> 16, (gc >> 8) & 0xFF, gc & 0xFF,
           agc_json_version(), uv ? ", libuv " : "", uv ? uv : "", ssl ? ", OpenSSL " : "", ssl ? ssl : "", trace);
  else
    printf("agentica %s (sanitizer build, no libgc, yyjson %s%s%s%s%s%s)\n", AGC_VERSION, agc_json_version(),
           uv ? ", libuv " : "", uv ? uv : "", ssl ? ", OpenSSL " : "", ssl ? ssl : "", trace);
}

/* The first program of `run --session`, which the front end writes to the child's standard input and closes: the
 * entries read no input after it. NULL when it cannot be read or is larger than a file the loader takes. */
static const uint8_t *session_program(size_t *len) {
  size_t cap = 4096, n = 0;
  uint8_t *data = agc_alloc_atomic(cap);
  for (;;) {
    if (n == cap) {
      if (n > AGC_MAX_FILE_BYTES) return NULL;
      size_t more = cap * 2 > AGC_MAX_FILE_BYTES ? AGC_MAX_FILE_BYTES + 1 : cap * 2;
      uint8_t *grown = agc_alloc_atomic(more);
      memcpy(grown, data, n);
      data = grown;
      cap = more;
    }
    size_t got = fread(data + n, 1, cap - n, stdin);
    n += got;
    if (got == 0) break;
  }
  if (ferror(stdin) || n > AGC_MAX_FILE_BYTES) return NULL;
  *len = n;
  return data;
}

/* `agentica run`: argv[2] and on are the options, then `--` (or the first word that is not an option), the file and
 * the program's arguments. The steps and their order are those of a run of the front end's program, with the options
 * typed here instead of handed over: a start that fails is status 2. With `--embedded NAME` there is no file: the
 * program is one the binary carries, and every word after `--` is its argument. */
static int run_command(agc_launch *launch, int argc, char **argv) {
  agc_launch_options options;
  int i = 2;
  agc_launch_status status = agc_launch_parse(run_name, argc, argv, &i, &options);
  if (status == AGC_LAUNCH_VERSION) {
    print_version();
    return fflush(stdout) == 0 ? 0 : 1;
  }
  if (status == AGC_LAUNCH_BAD) return 2;
  if (i >= argc && !options.embedded) {
    fputs(usage, stderr);
    return 2;
  }
  if (!agc_launch_env(run_name, &options) || !agc_launch_supported(run_name, &options)) return 2;
  if (options.seen_driver && !agc_launch_bind(options.driver)) {
    fprintf(stderr, "%s: --driver-pid does not match the parent process\n", run_name);
    return 2;
  }
  agc_launch_trace(launch);
  size_t len = 0;
  const uint8_t *data = NULL;
  /* The file is the first word; the arguments of an embedded program start where the file would have been. */
  int first = i + 1;
  if (options.session) {
    /* The child of `agentica repl` (vm/session.c): its first program comes on stdin ("-"), and a session never has
       the JIT, the coverage or the profile, which size their tables by that program. */
    if (options.embedded || options.coverage || options.source_root[0] || strcmp(argv[i], "-") != 0 ||
        (launch->trace.mask & AGC_TRACE_PROFILE)) {
      fprintf(stderr,
              "%s: --session takes its program on stdin (-), without --embedded, --coverage, --source-root or the "
              "profile\n",
              run_name);
      return 2;
    }
    if (!(data = session_program(&len))) {
      fprintf(stderr, "%s: cannot read the session's program from stdin\n", run_name);
      return 2;
    }
  } else if (options.embedded) {
    data = embedded_program(options.embedded, &len);
    first = i;
    if (!data || len == 0) {
      fprintf(stderr, "%s: this binary carries no embedded program %s\n", run_name, options.embedded);
      return 2;
    }
  } else if (!(data = agc_launch_file(argv[i], options.seen_driver, &len))) {
    fprintf(stderr, "%s: cannot read %s\n", run_name, argv[i]);
    return 2;
  }
  agc_program *program = NULL;
  char error[160];
  if (!agc_load_traced(data, len, &program, error, sizeof error, &launch->trace)) {
    fprintf(stderr, "%s: invalid bytecode: %s\n", run_name, error);
    /* The usual mistake: a source file given to run. */
    if (!options.embedded && (len < 4 || memcmp(data, AGC_MAGIC, 4) != 0))
      fprintf(stderr, "%s: %s is not compiled bytecode; to run a source file, use agentica %s\n", run_name, argv[i],
              argv[i]);
    return 2;
  }
  if (!agc_program_set_source_root(program, options.source_root, options.source_root_chars)) {
    fprintf(stderr, "%s: --source-root is too long for this program\n", run_name);
    return 2;
  }
  if (!agc_launch_native(program, &options)) return 2;
  agc_vm *vm = agc_launch_vm(launch, program, &options, agc_launch_args(argc, argv, first), NULL);
  agc_launch_end(vm, agc_vm_run(vm));
}

int main(int argc, char **argv) {
  /* Answered here, before the allocator starts or anything is opened: no front end runs and no trace file is
   * created. A closed pipe on the standard output must not end the process with a signal. */
  agc_launch_ignore_sigpipe();
  agc_launch_init_streams();
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts(AGC_VERSION);
    return fflush(stdout) == 0 ? 0 : 1;
  }
  agc_launch launch;
  agc_launch_init(&launch);
  if (!agc_launch_utf8_args(&argc, &argv)) {
    fprintf(stderr, "%s: cannot decode command line arguments\n", name);
    return 2;
  }
  launch.std = std_sources(&launch.std_count);
  if (argc > 1 && strcmp(argv[1], "run") == 0) return run_command(&launch, argc, argv);
  /* The environment is checked before the trace file is opened and before the front end spends its time compiling;
   * run_program applies the value. */
  agc_launch_options environment;
  agc_launch_defaults(&environment);
  if (!agc_launch_env(name, &environment)) return 2;
  agc_launch_trace(&launch);
  int first = 1;
  const char *replacement = NULL;
  if (argc > 1 && strcmp(argv[1], "--front-end") == 0) {
    if (argc < 3) {
      fprintf(stderr, "%s: --front-end needs a file\n", name);
      return 2;
    }
    replacement = argv[2];
    first = 3;
  }
  agc_front_end fe;
  memset(&fe, 0, sizeof fe);
  char self[32768];
  const char *self_name = agc_launch_self_path(argc, argv, argc > 0 ? argv[0] : "", self, sizeof self);
  launcher_end launched = LAUNCHER_DECLINED;
  if (!replacement) launched = run_launcher(&launch, self_name, argc - first, argv + first, &fe);
  if (launched != LAUNCHER_HANDED)
    run_front_end(&launch, self_name, replacement, launched == LAUNCHER_MISSED, argc - first, argv + first, &fe);
  return run_program(&launch, &fe);
}

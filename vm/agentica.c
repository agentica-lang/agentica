/*
 * The agentica binary (dist/agentica, docs/future/35-self-hosting.md 35.6), the only program of the
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

static const char name[] = "agentica";
static const char run_name[] = "agentica run";

static const char usage[] =
  "usage: agentica run [--version] [--max-steps N] [--seed N] [--flush-timeout MS] [--allow-run] [--ai|--json] "
  "[--source-root DIR] -- <file.agcb> [args...]\n"
  "  --source-root DIR is put before each stored source name that is relative and does not start with std/, in diagnostics and reports\n"
  "  the file flush at the end of the run waits at most 30000 ms, or MS, or AGENTICA_FLUSH_TIMEOUT_MS (the flag wins, at most 86400000)\n";

/* The std/ sources of the binary, from the index that make wrote. */
static agc_std_source *std_sources(size_t *count) {
  size_t n = (size_t)agc_embedded_index[6];
  agc_std_source *sources = agc_alloc(agc_size_mul(n ? n : 1, sizeof *sources));
  for (size_t k = 0; k < n; k++) {
    const uint64_t *row = agc_embedded_index + 7 + 3 * k;
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

/* The first run. It leaves this function only when the front end handed a program over and its run ended cleanly;
 * every other end (a usage error, a problem in the user's file, a crash of the front end, a stop signal) is the
 * end of the process. The status is the one the front end gave, except for a crash: a runtime error in the front end
 * is a bug of the compiler or of `agentica test`'s driver, not a problem in the user's program (status 1), and a
 * driver that crashed must not look like a test run that failed, so it is status 2, like a front end started wrongly.
 * What it allocated is garbage once it returns.
 *
 * The front end may start processes (--allow-run): `agentica test` starts the runner and the programs under test from
 * here. That is no loophole for the user's program, which never runs in this runtime: the front end only compiles it. */
static void run_front_end(agc_launch *launch, const char *self, const char *replacement, int count, char **words,
                          agc_front_end *fe) {
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
  /* The inputs of the front end (compiler/front_end_inputs.agc), then the words of the user. */
  char version_flag[] = "--version", self_flag[] = "--self", bdd_flag[] = "--embedded-bdd", separator[] = "--",
       version[] = AGC_VERSION;
  bool embedded_bdd = !replacement && agc_embedded_index[3] != 0 && agc_embedded_index[5] != 0;
  int input_count = embedded_bdd ? 6 : 5;
  char **arguments = agc_alloc(agc_size_mul((size_t)count + (size_t)input_count, sizeof *arguments));
  arguments[0] = version_flag;
  arguments[1] = version;
  arguments[2] = self_flag;
  arguments[3] = (char *)self;
  int separator_at = 4;
  if (embedded_bdd) arguments[separator_at++] = bdd_flag;
  arguments[separator_at++] = separator;
  for (int k = 0; k < count; k++) arguments[separator_at + k] = words[k];
  fe->std = std_sources(&fe->std_count);
  agc_launch_options options;
  agc_launch_defaults(&options);
  options.allow_run = true;
  agc_vm *vm = agc_launch_vm(launch, program, &options, agc_launch_args(count + input_count, arguments, 0), fe);
  agc_outcome outcome = agc_vm_run(vm);
  bool crashed = outcome.kind == AGC_FAILED;
  int status = agc_launch_settle(vm, &outcome);
  if (crashed) status = 2;
  if (!fe->handed || outcome.kind != AGC_EXITED || status != 0 || agc_io_stop_signal()) agc_launch_exit(status);
  /* A job that is still running would keep the front end's loop alive next to the program's: the program must not share
   * a process with anything of the compiler, so this is the end of the run. */
  if (!agc_io_close(vm)) {
    fprintf(stderr, "%s: internal error: the front end left an operation running\n", name);
    agc_launch_exit(1);
  }
}

/* The second run: the program that the front end handed over, with the options it passed on. It returns only to
 * report a start that failed. The options are those of `agentica run` (--ai, --json, --allow-run, --max-steps,
 * --seed, --flush-timeout, --source-root), each once. The front end is trusted with them, but
 * --driver-pid is not one: it names the process that started this one, which only that process can say, so the
 * front end cannot. The counts are capped by the hand-off (AGC_FRONT_END_MAX_OPTIONS and _ARGUMENTS), so they fit
 * an int. */
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
  if (options.embedded) {
    fprintf(stderr, "%s: the front end passed --embedded, which only %s takes\n", name, run_name);
    return 2;
  }
  if (!agc_launch_flush_env(name, &options)) return 2;
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
  if (!agc_launch_flush_env(run_name, &options)) return 2;
  if (options.seen_driver && !agc_launch_bind(options.driver)) {
    fprintf(stderr, "%s: --driver-pid does not match the parent process\n", run_name);
    return 2;
  }
  agc_launch_trace(launch);
  size_t len = 0;
  const uint8_t *data = NULL;
  /* The file is the first word; the arguments of an embedded program start where the file would have been. */
  int first = i + 1;
  if (options.embedded) {
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
  agc_vm *vm = agc_launch_vm(launch, program, &options, agc_launch_args(argc, argv, first), NULL);
  agc_launch_end(vm, agc_vm_run(vm));
}

int main(int argc, char **argv) {
  /* Answered here, before the allocator starts or anything is opened: no front end runs and no trace file is
   * created. A closed pipe on the standard output must not end the process with a signal. */
  agc_launch_ignore_sigpipe();
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
  if (argc > 1 && strcmp(argv[1], "run") == 0) return run_command(&launch, argc, argv);
  /* The environment is checked before the trace file is opened and before the front end spends its time compiling;
   * run_program applies the value. */
  agc_launch_options environment;
  agc_launch_defaults(&environment);
  if (!agc_launch_flush_env(name, &environment)) return 2;
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
  run_front_end(&launch, self_name, replacement, argc - first, argv + first, &fe);
  return run_program(&launch, &fe);
}

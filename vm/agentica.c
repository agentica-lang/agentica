/*
 * The single binary (dist/agentica-next, docs/future/35-self-hosting.md §35.6).
 * It runs its front end, a compiled program carried in the binary, in a first
 * runtime. The front end compiles in memory and hands the program over
 * (FrontEnd.hand_off); this file retires that runtime and runs the program in
 * a second one, so the options and the heap are the program's alone.
 * `--front-end FILE.agcb` (build-only) loads another front end in place of the carried one.
 * Design: docs/vm/08-loader-and-cli.md.
 */
#include "core.h"
#include "embedded.h"
#include "launch.h"

#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char name[] = "agentica";

/* The std/ sources of the binary, from the index that make wrote. */
static agc_std_source *std_sources(size_t *count) {
  size_t n = (size_t)agc_embedded_index[2];
  agc_std_source *sources = agc_alloc(agc_size_mul(n ? n : 1, sizeof *sources));
  for (size_t k = 0; k < n; k++) {
    const uint64_t *row = agc_embedded_index + 3 + 3 * k;
    const char *path = (const char *)agc_embedded_data + row[0];
    sources[k] = (agc_std_source){path, agc_embedded_data + row[1], (size_t)row[2]};
  }
  *count = n;
  return sources;
}

/* The path the front end gets as --self, to start this binary again (the `test` command of the full CLI does). On Linux
 * /proc/self/exe is exact; the name in argv[0] is what is left without /proc. */
static const char *self_path(const char *argv0, char *buffer, size_t size) {
  ssize_t n = readlink("/proc/self/exe", buffer, size - 1);
  if (n <= 0 || (size_t)n >= size - 1) return argv0;
  buffer[n] = '\0';
  return buffer;
}

/* O_NONBLOCK keeps the open of a named pipe from waiting for a writer; the S_ISREG test then refuses it. */
static uint8_t *read_front_end(const char *path, size_t *len) {
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) return NULL;
  struct stat info;
  if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
      (uint64_t)info.st_size > AGC_MAX_FILE_BYTES) {
    close(fd);
    return NULL;
  }
  *len = (size_t)info.st_size;
  return agc_launch_read(fd, *len);
}

/* The first run. It leaves this function only when the front end handed a program over and its run ended cleanly;
 * every other end (a usage error, a problem in the user's file, a crash of the front end, a stop signal) is the
 * end of the process, with the status the front end gave. What it allocated is garbage once it returns. */
static void run_front_end(agc_launch *launch, const char *self, const char *replacement, int count, char **words,
                          agc_front_end *fe) {
  size_t len = (size_t)agc_embedded_index[1];
  const uint8_t *bytes = agc_embedded_data + agc_embedded_index[0];
  if (replacement && !(bytes = read_front_end(replacement, &len))) {
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
  char version_flag[] = "--version", self_flag[] = "--self", separator[] = "--", version[] = AGC_VERSION;
  char **arguments = agc_alloc(agc_size_mul((size_t)count + 5, sizeof *arguments));
  arguments[0] = version_flag;
  arguments[1] = version;
  arguments[2] = self_flag;
  arguments[3] = (char *)self;
  arguments[4] = separator;
  for (int k = 0; k < count; k++) arguments[5 + k] = words[k];
  fe->std = std_sources(&fe->std_count);
  agc_launch_options options;
  agc_launch_defaults(&options);
  agc_vm *vm = agc_launch_vm(launch, program, &options, agc_launch_args(count + 5, arguments, 0), fe);
  agc_outcome outcome = agc_vm_run(vm);
  int status = agc_launch_settle(vm, &outcome);
  if (!fe->handed || outcome.kind != AGC_EXITED || status != 0 || agc_io_stop_signal()) agc_launch_exit(status);
  /* A job that is still running would keep the front end's loop alive next to the program's: the program must not share
   * a process with anything of the compiler, so this is the end of the run. */
  if (!agc_io_close(vm)) {
    fprintf(stderr, "%s: internal error: the front end left an operation running\n", name);
    agc_launch_exit(1);
  }
}

/* The second run: the program that the front end handed over, with the options it passed on. It returns only to
 * report a start that failed. The options are those of agentica-vm for a run (--ai, --json, --allow-run,
 * --max-steps, --seed, --flush-timeout, --source-root), each once. The front end is trusted with them, but
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

int main(int argc, char **argv) {
  /* Answered here, before anything is opened: no front end runs and no trace file is created. */
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    puts(AGC_VERSION);
    return fflush(stdout) == 0 ? 0 : 1;
  }
  agc_launch launch;
  agc_launch_init(&launch);
  agc_launch_trace(&launch);
  /* The environment is checked before the front end spends its time compiling; run_program applies the value. */
  agc_launch_options environment;
  agc_launch_defaults(&environment);
  if (!agc_launch_flush_env(name, &environment)) return 2;
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
  char self[PATH_MAX];
  const char *self_name = self_path(argc > 0 ? argv[0] : "", self, sizeof self);
  run_front_end(&launch, self_name, replacement, argc - first, argv + first, &fe);
  return run_program(&launch, &fe);
}

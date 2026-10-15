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

static uint8_t *read_front_end(const char *path, size_t *len) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
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
static void run_front_end(agc_launch *launch, const char *replacement, int count, char **words, agc_front_end *fe) {
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
  char flag[] = "--version", separator[] = "--", version[] = AGC_VERSION;
  char **arguments = agc_alloc(agc_size_mul((size_t)count + 3, sizeof *arguments));
  arguments[0] = flag;
  arguments[1] = version;
  arguments[2] = separator;
  for (int k = 0; k < count; k++) arguments[3 + k] = words[k];
  fe->std = std_sources(&fe->std_count);
  agc_launch_options options;
  agc_launch_defaults(&options);
  agc_vm *vm = agc_launch_vm(launch, program, &options, agc_launch_args(count + 3, arguments, 0), fe);
  agc_outcome outcome = agc_vm_run(vm);
  int status = agc_launch_settle(vm, &outcome);
  if (!fe->handed || outcome.kind != AGC_EXITED || status != 0 || agc_io_stop_signal()) agc_launch_exit(status);
  agc_io_close(vm);
}

/* The second run: the program that the front end handed over, with the options it passed on. It returns only to
 * report a start that failed. */
static int run_program(agc_launch *launch, const agc_front_end *fe) {
  agc_launch_options options;
  int at = 0;
  agc_launch_status status = agc_launch_parse(name, (int)fe->option_count, fe->options, &at, &options);
  if (status == AGC_LAUNCH_BAD) return 2;
  if (status == AGC_LAUNCH_VERSION || at != (int)fe->option_count) {
    fprintf(stderr, "%s: the front end passed %s, which is not an option of a run\n", name, fe->options[at]);
    return 2;
  }
  if (!agc_launch_flush_env(name, &options)) return 2;
  if (options.seen_driver && !agc_launch_bind(options.driver)) {
    fprintf(stderr, "%s: --driver-pid does not match the parent process\n", name);
    return 2;
  }
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
  agc_launch launch;
  agc_launch_init(&launch);
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
  run_front_end(&launch, replacement, argc - first, argv + first, &fe);
  return run_program(&launch, &fe);
}

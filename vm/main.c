#include "agc.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char usage[] = "usage: agentica-vm [--version] [--max-steps N] -- <file.agcb> [args...]\n";

static int usage_error(void) {
  fputs(usage, stderr);
  return 2;
}

static bool parse_steps(const char *text, int64_t *steps) {
  if (!*text) return false;
  int64_t value = 0;
  bool clamped = false;
  for (const char *c = text; *c; c++) {
    if (*c < '0' || *c > '9') return false;
    if (!clamped && (__builtin_mul_overflow(value, 10, &value) || __builtin_add_overflow(value, *c - '0', &value)))
      clamped = true;
  }
  if (clamped) value = INT64_MAX;
  *steps = value;
  return value > 0;
}

static uint8_t *read_file(const char *path, size_t *len) {
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
  if (fd < 0) return NULL;
  struct stat info;
  if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
      (uint64_t)info.st_size > AGC_MAX_FILE_BYTES) {
    close(fd);
    return NULL;
  }
  size_t size = (size_t)info.st_size;
  uint8_t *data = agc_alloc_atomic(size);
  size_t done = 0;
  while (done < size) {
    ssize_t n = read(fd, data + done, size - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    done += (size_t)n;
  }
  close(fd);
  if (done != size) return NULL;
  *len = size;
  return data;
}

int main(int argc, char **argv) {
  signal(SIGPIPE, SIG_IGN);
  agc_init();
  int64_t max_steps = INT64_MAX;
  int i = 1;
  while (i < argc) {
    const char *arg = argv[i];
    if (strcmp(arg, "--") == 0) {
      i++;
      break;
    }
    if (strcmp(arg, "--version") == 0) {
      unsigned gc = agc_gc_version();
      if (gc)
        printf("agentica-vm %s (libgc %u.%u.%u)\n", AGC_VERSION, gc >> 16, (gc >> 8) & 0xFF, gc & 0xFF);
      else
        printf("agentica-vm %s (sanitizer build, no libgc)\n", AGC_VERSION);
      return fflush(stdout) == 0 ? 0 : 1;
    }
    if (strcmp(arg, "--max-steps") == 0) {
      if (i + 1 >= argc || !parse_steps(argv[i + 1], &max_steps)) {
        fputs("agentica-vm: --max-steps needs a positive integer\n", stderr);
        return 2;
      }
      i += 2;
      continue;
    }
    if (arg[0] == '-' && arg[1] != '\0') {
      fprintf(stderr, "agentica-vm: unknown option %s\n", arg);
      return 2;
    }
    break;
  }
  if (i >= argc) return usage_error();
  const char *path = argv[i];

  size_t len = 0;
  uint8_t *data = read_file(path, &len);
  if (!data) {
    fprintf(stderr, "agentica-vm: cannot read %s\n", path);
    return 2;
  }
  agc_program *program = NULL;
  char error[160];
  if (!agc_load(data, len, &program, error, sizeof error)) {
    fprintf(stderr, "agentica-vm: invalid bytecode: %s\n", error);
    return 2;
  }

  agc_vm *vm = agc_alloc(sizeof(agc_vm));
  agc_vm_init(vm, program, stdout, max_steps);
  agc_outcome outcome = agc_vm_run(vm);
  if (outcome.kind == AGC_DONE && fflush(stdout) != 0) {
    outcome.kind = AGC_FAILED;
    outcome.code = "RUNTIME-INTERNAL";
    outcome.message = "cannot write to standard output";
    outcome.span = 0;
  }
  if (outcome.kind == AGC_FAILED) {
    agc_print_diagnostic(stderr, program, &outcome);
    return 1;
  }
  return 0;
}

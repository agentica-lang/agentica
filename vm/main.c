/*
 * Aurora, the Agentica bytecode VM.
 *
 * Aurora is the VM's codename, used in docs only. The binary stays
 * agentica-vm, and the AGENTICA_VM* variables, the agc_ prefix, .agcb and
 * vm/ keep their names. This file is the entry point: it reads the command
 * line, loads a .agcb file, runs it and maps the outcome to an exit code.
 * The design is in docs/vm/README.md.
 */
#include "core.h"
#include "launch.h"
#include "services.h"
#include "tls.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <io.h>
#include <windows.h>

#define file_stat _fstat64

typedef struct _stat64 file_info;

static wchar_t **wide_args; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
#else
#include <unistd.h>

#define file_stat fstat

typedef struct stat file_info;
#endif

#ifdef _WIN32
static int open_input(int index, const char *path, bool driven) {
  (void)path;
  (void)driven;
  return _wopen(wide_args[index], _O_RDONLY | _O_BINARY | _O_NOINHERIT);
}

static bool private_input(const file_info *info) {
  (void)info;
  return true;
}

static void remove_input(int index, const char *path, const file_info *info) {
  (void)path;
  (void)info;
  _wunlink(wide_args[index]);
}
#else
static int open_input(int index, const char *path, bool driven) {
  (void)index;
  return open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | (driven ? O_NOFOLLOW : 0));
}

static bool private_input(const file_info *info) {
  return info->st_uid == geteuid() && info->st_nlink == 1 && (info->st_mode & 077) == 0;
}

static void remove_input(int index, const char *path, const file_info *info) {
  (void)index;
  struct stat now;
  if (lstat(path, &now) == 0 && now.st_dev == info->st_dev && now.st_ino == info->st_ino) unlink(path);
}
#endif

static const char usage[] =
  "usage: agentica-vm [--version] [--max-steps N] [--seed N] [--flush-timeout MS] [--allow-run] [--ai|--json] "
  "[--source-root DIR] -- <file.agcb> [args...]\n"
  "  --source-root DIR is put before each stored source name that is relative and does not start with std/, in diagnostics and reports\n"
  "  the file flush at the end of the run waits at most 30000 ms, or MS, or AGENTICA_FLUSH_TIMEOUT_MS (the flag wins, at most 86400000)\n";

static int usage_error(void) {
  fputs(usage, stderr);
  return 2;
}

static uint8_t *read_file(int index, const char *path, bool driven, size_t *len) {
  int fd = open_input(index, path, driven);
  if (fd < 0) return NULL;
  file_info info;
  if (file_stat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
      (uint64_t)info.st_size > AGC_MAX_FILE_BYTES || (driven && !private_input(&info))) {
    close(fd);
    return NULL;
  }
  if (driven) remove_input(index, path, &info);
  uint8_t *data = agc_launch_read(fd, (size_t)info.st_size);
  if (data) *len = (size_t)info.st_size;
  return data;
}

static void print_version(void) {
  unsigned gc = agc_gc_version();
  const char *uv = agc_uv_version();
  const char *ssl = agc_tls_version();
  const char *trace = AGC_TRACE_BUILD ? "" : ", trace off";
  if (gc)
    printf("agentica-vm %s (libgc %u.%u.%u, yyjson %s%s%s%s%s%s)\n", AGC_VERSION, gc >> 16, (gc >> 8) & 0xFF, gc & 0xFF,
           agc_json_version(), uv ? ", libuv " : "", uv ? uv : "", ssl ? ", OpenSSL " : "", ssl ? ssl : "", trace);
  else
    printf("agentica-vm %s (sanitizer build, no libgc, yyjson %s%s%s%s%s%s)\n", AGC_VERSION, agc_json_version(),
           uv ? ", libuv " : "", uv ? uv : "", ssl ? ", OpenSSL " : "", ssl ? ssl : "", trace);
}

static int run(int argc, char **argv) {
  agc_launch launch;
  agc_launch_init(&launch);
  agc_launch_options options;
  int i = 1;
  agc_launch_status status = agc_launch_parse("agentica-vm", argc, argv, &i, &options);
  if (status == AGC_LAUNCH_VERSION) {
    print_version();
    return fflush(stdout) == 0 ? 0 : 1;
  }
  if (status == AGC_LAUNCH_BAD) return 2;
  if (i >= argc) return usage_error();
  const char *path = argv[i];
  if (!agc_launch_flush_env("agentica-vm", &options)) return 2;

  if (options.seen_driver && !agc_launch_bind(options.driver)) {
    fputs("agentica-vm: --driver-pid does not match the parent process\n", stderr);
    return 2;
  }
  agc_launch_trace(&launch);
  size_t len = 0;
  uint8_t *data = read_file(i, path, options.seen_driver, &len);
  if (!data) {
    fprintf(stderr, "agentica-vm: cannot read %s\n", path);
    return 2;
  }
  agc_program *program = NULL;
  char error[160];
  if (!agc_load_traced(data, len, &program, error, sizeof error, &launch.trace)) {
    fprintf(stderr, "agentica-vm: invalid bytecode: %s\n", error);
    return 2;
  }
  if (!agc_program_set_source_root(program, options.source_root, options.source_root_chars)) {
    fputs("agentica-vm: --source-root is too long for this program\n", stderr);
    return 2;
  }
  agc_vm *vm = agc_launch_vm(&launch, program, &options, agc_launch_args(argc, argv, i + 1), NULL);
  agc_launch_end(vm, agc_vm_run(vm));
}

#ifdef _WIN32
int wmain(int argc, wchar_t **wide_argv) {
  agc_init();
  _setmode(_fileno(stdin), _O_BINARY);
  _setmode(_fileno(stdout), _O_BINARY);
  _setmode(_fileno(stderr), _O_BINARY);
  wide_args = wide_argv;
  char **argv = agc_alloc(agc_size_mul((size_t)argc + 1, sizeof *argv));
  for (int i = 0; i < argc; i++) {
    int n = WideCharToMultiByte(CP_UTF8, 0, wide_argv[i], -1, NULL, 0, NULL, NULL);
    if (n > 0) argv[i] = agc_alloc_atomic((size_t)n);
    if (n <= 0 || WideCharToMultiByte(CP_UTF8, 0, wide_argv[i], -1, argv[i], n, NULL, NULL) != n) {
      fputs("agentica-vm: cannot convert arguments\n", stderr);
      return 2;
    }
  }
  return run(argc, argv);
}
#else
int main(int argc, char **argv) { return run(argc, argv); }
#endif

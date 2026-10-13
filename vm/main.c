/*
 * Aurora, the Agentica bytecode VM.
 *
 * Aurora is the VM's codename, used in docs only. The binary stays
 * agentica-vm, and the AGENTICA_VM* variables, the agc_ prefix, .agcb and
 * vm/ keep their names. This file is the entry point: it reads the command
 * line, loads a .agcb file, runs it and maps the outcome to an exit code.
 * The design is in docs/vm/README.md.
 */
#ifdef _WIN32
#define _CRT_RAND_S
#endif
#include "agc.h"
#include "tls.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#ifdef __linux__
#include <sys/prctl.h>
#include <sys/random.h>
#endif

#ifdef _WIN32
#include <io.h>
#include <windows.h>

#define file_stat _fstat64
#define TRACE_OPEN (_O_WRONLY | _O_APPEND | _O_CREAT | _O_NOINHERIT | _O_BINARY)
#define TRACE_MODE (_S_IREAD | _S_IWRITE)

typedef struct _stat64 file_info;

static wchar_t **wide_args; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
#else
#include <unistd.h>

#define file_stat fstat
#define TRACE_OPEN (O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
#define TRACE_MODE 0600

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

#ifndef _WIN32
static bool urandom_entropy(uint8_t *out, size_t len) {
  int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return false;
  size_t done = 0;
  while (done < len) {
    ssize_t n = read(fd, out + done, len - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    done += (size_t)n;
  }
  close(fd);
  return done == len;
}
#endif

#ifdef __linux__
static bool os_entropy(uint8_t *out, size_t len) {
  size_t done = 0;
  while (done < len) {
    ssize_t n = getrandom(out + done, len - done, 0);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return urandom_entropy(out, len);
    done += (size_t)n;
  }
  return true;
}
#elif defined(_WIN32)
static bool os_entropy(uint8_t *out, size_t len) {
  for (size_t k = 0; k < len; k++) {
    unsigned int x;
    if (rand_s(&x) != 0) return false;
    out[k] = (uint8_t)x;
  }
  return true;
}
#else
static bool os_entropy(uint8_t *out, size_t len) { return urandom_entropy(out, len); }
#endif

static uint64_t entropy_seed(void) {
  uint8_t bytes[8];
  if (!os_entropy(bytes, sizeof bytes)) {
    struct timespec ts = {0};
    if (timespec_get(&ts, TIME_UTC) != TIME_UTC) return 0;
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
  }
  uint64_t seed = 0;
  for (unsigned k = 0; k < 8; k++) seed |= (uint64_t)bytes[k] << (8 * k);
  return seed;
}

static void seed_map_hash(agc_vm *vm) {
  uint8_t key[16];
  if (!os_entropy(key, sizeof key)) return;
  uint64_t k0 = 0, k1 = 0;
  for (unsigned k = 0; k < 8; k++) {
    k0 |= (uint64_t)key[k] << (8 * k);
    k1 |= (uint64_t)key[8 + k] << (8 * k);
  }
  vm->rt->hash_key[0] = k0;
  vm->rt->hash_key[1] = k1;
}

#ifdef __linux__
static bool bind_to_driver(int64_t driver) {
  signal(SIGTERM, SIG_DFL);
  if (prctl(PR_SET_PDEATHSIG, SIGTERM) != 0) return false;
  return (int64_t)getppid() == driver;
}
#else
static bool bind_to_driver(int64_t driver) {
  (void)driver;
  return true;
}
#endif

#ifdef _WIN32
static int private_trace_fd(int fd) { return fd; }
#else
static int private_trace_fd(int fd) {
  struct stat info;
  if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != geteuid()) {
    close(fd);
    return -1;
  }
  if (fd > 2) return fd;
  int moved = fcntl(fd, F_DUPFD_CLOEXEC, 3);
  close(fd);
  return moved;
}
#endif

#ifdef __linux__
static void fill_standard_fds(void) {
  for (int fd = 0; fd <= 2; fd++) {
    if (fcntl(fd, F_GETFD) != -1 || errno != EBADF) continue;
    int opened = open("/dev/null", fd == 0 ? O_WRONLY : O_RDONLY);
    if (opened < 0 || opened == fd) continue;
    dup2(opened, fd);
    close(opened);
  }
}
#endif

static void start_trace(agc_trace *trace) {
  const char *names = getenv("AGENTICA_VM_TRACE");
  const char *path = getenv("AGENTICA_VM_TRACE_FILE");
  int fd = 2;
  if (AGC_TRACE_BUILD && names && *names && path && *path) {
    fd = open(path, TRACE_OPEN, TRACE_MODE);
    if (fd >= 0) fd = private_trace_fd(fd);
    if (fd < 0) {
      agc_trace_message(2, "cannot open", path, strlen(path), false);
      names = NULL;
      fd = 2;
    }
  }
  agc_trace_parse(trace, names, fd);
}

static agc_value program_args(int argc, char **argv, int first) {
  size_t n = first < argc ? (size_t)(argc - first) : 0;
  agc_list *list = agc_new_list(n);
  for (size_t k = 0; k < n; k++) {
    const char *arg = argv[(size_t)first + k];
    list->items[k] = agc_string_value(agc_utf8_decode((const uint8_t *)arg, strlen(arg), "?", true));
  }
  return agc_list_value(list);
}

static const char usage[] =
  "usage: agentica-vm [--version] [--max-steps N] [--seed N] [--flush-timeout MS] [--allow-run] [--ai|--json] -- "
  "<file.agcb> [args...]\n";

static int usage_error(void) {
  fputs(usage, stderr);
  return 2;
}

static bool once(bool *seen, const char *option) {
  if (*seen) {
    fprintf(stderr, "agentica-vm: the %s option can only be specified once\n", option);
    return false;
  }
  *seen = true;
  return true;
}

static bool parse_count(const char *text, int64_t *count) {
  if (!*text) return false;
  int64_t value = 0;
  bool clamped = false;
  for (const char *c = text; *c; c++) {
    if (*c < '0' || *c > '9') return false;
    if (!clamped && (__builtin_mul_overflow(value, 10, &value) || __builtin_add_overflow(value, *c - '0', &value)))
      clamped = true;
  }
  if (clamped) value = INT64_MAX;
  *count = value;
  return true;
}

static bool parse_steps(const char *text, int64_t *steps) { return parse_count(text, steps) && *steps > 0; }

static bool parse_seed(const char *text, uint32_t *seed) {
  if (!*text) return false;
  uint64_t value = 0;
  for (const char *c = text; *c; c++) {
    if (*c < '0' || *c > '9') return false;
    value = value * 10 + (uint64_t)(*c - '0');
    if (value > 2147483647u) return false;
  }
  *seed = (uint32_t)value;
  return true;
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

static int run(int argc, char **argv) {
#ifdef SIGPIPE
  signal(SIGPIPE, SIG_IGN);
#endif
  agc_init();
  int64_t max_steps = INT64_MAX;
  agc_style style = AGC_STYLE_PLAIN;
  int64_t driver = 0, flush_timeout = -1;
  uint32_t seed = 0;
  bool seen_flush = false, seen_steps = false, seen_ai = false, seen_json = false, seen_driver = false, seen_seed = false, allow_run = false;
  int i = 1;
  while (i < argc) {
    const char *arg = argv[i];
    if (strcmp(arg, "--") == 0) {
      i++;
      break;
    }
    if (strcmp(arg, "--version") == 0) {
      unsigned gc = agc_gc_version();
      const char *uv = agc_uv_version();
      const char *ssl = agc_tls_version();
      const char *trace = AGC_TRACE_BUILD ? "" : ", trace off";
      if (gc)
        printf("agentica-vm %s (libgc %u.%u.%u, yyjson %s%s%s%s%s%s)\n", AGC_VERSION, gc >> 16, (gc >> 8) & 0xFF,
               gc & 0xFF, agc_json_version(), uv ? ", libuv " : "", uv ? uv : "", ssl ? ", OpenSSL " : "",
               ssl ? ssl : "", trace);
      else
        printf("agentica-vm %s (sanitizer build, no libgc, yyjson %s%s%s%s%s%s)\n", AGC_VERSION, agc_json_version(),
               uv ? ", libuv " : "", uv ? uv : "", ssl ? ", OpenSSL " : "", ssl ? ssl : "", trace);
      return fflush(stdout) == 0 ? 0 : 1;
    }
    if (strcmp(arg, "--ai") == 0 || strcmp(arg, "--json") == 0) {
      bool json = arg[2] == 'j';
      if (!once(json ? &seen_json : &seen_ai, arg)) return 2;
      style = json ? AGC_STYLE_JSON : AGC_STYLE_AI;
      i++;
      continue;
    }
    if (strcmp(arg, "--allow-run") == 0) {
      if (!once(&allow_run, arg)) return 2;
      i++;
      continue;
    }
    if (strcmp(arg, "--max-steps") == 0) {
      if (!once(&seen_steps, arg)) return 2;
      if (i + 1 >= argc || !parse_steps(argv[i + 1], &max_steps)) {
        fputs("agentica-vm: --max-steps needs a positive integer\n", stderr);
        return 2;
      }
      i += 2;
      continue;
    }
    if (strcmp(arg, "--seed") == 0) {
      if (!once(&seen_seed, arg)) return 2;
      if (i + 1 >= argc || !parse_seed(argv[i + 1], &seed)) {
        fputs("agentica-vm: --seed needs an integer from 0 to 2147483647\n", stderr);
        return 2;
      }
      i += 2;
      continue;
    }
    if (strcmp(arg, "--flush-timeout") == 0) {
      if (!once(&seen_flush, arg)) return 2;
      if (i + 1 >= argc || !parse_count(argv[i + 1], &flush_timeout)) {
        fputs("agentica-vm: --flush-timeout needs a non-negative integer\n", stderr);
        return 2;
      }
      i += 2;
      continue;
    }
    if (strcmp(arg, "--driver-pid") == 0) {
      if (!once(&seen_driver, arg)) return 2;
      if (i + 1 >= argc || !parse_steps(argv[i + 1], &driver)) {
        fputs("agentica-vm: --driver-pid needs a positive integer\n", stderr);
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

  if (seen_driver && !bind_to_driver(driver)) {
    fputs("agentica-vm: --driver-pid does not match the parent process\n", stderr);
    return 2;
  }
  agc_trace trace;
  start_trace(&trace);
  size_t len = 0;
  uint8_t *data = read_file(i, path, seen_driver, &len);
  if (!data) {
    fprintf(stderr, "agentica-vm: cannot read %s\n", path);
    return 2;
  }
  agc_program *program = NULL;
  char error[160];
  if (!agc_load_traced(data, len, &program, error, sizeof error, &trace)) {
    fprintf(stderr, "agentica-vm: invalid bytecode: %s\n", error);
    return 2;
  }

  bool own_uring_env = agc_io_init();
  agc_vm *vm = agc_alloc(sizeof(agc_vm));
  agc_vm_init(vm, program, stdout, stderr, max_steps);
  vm->rt->trace = trace;
  vm->rt->style = style;
  vm->rt->flush_timeout = flush_timeout;
  vm->rt->allow_run = allow_run;
  vm->rt->drop_uring_env = own_uring_env;
  seed_map_hash(vm);
  agc_files_init(vm);
  const char *no_turn_cost = getenv("AGENTICA_VM_TEST_NO_TURN_COST");
  vm->rt->no_turn_cost = no_turn_cost && strcmp(no_turn_cost, "1") == 0;
  agc_random_seed(&vm->main->random, seen_seed ? seed : entropy_seed());
  vm->rt->args = program_args(argc, argv, i + 1);
  agc_input_open(vm, 0, isatty(1));
  agc_outcome outcome = agc_vm_run(vm);
  bool stdout_ok = fflush(stdout) == 0;
  bool settled = agc_io_close(vm);
  agc_files_close(vm);
  if (vm->rt->flush_expired) agc_print_flush_timeout(stderr, flush_timeout, style);
  if (outcome.kind != AGC_FAILED && (!stdout_ok || fflush(stdout) != 0)) {
    outcome.kind = AGC_FAILED;
    outcome.code = "RUNTIME-INTERNAL";
    outcome.message = "cannot write to standard output";
    outcome.message_len = strlen(outcome.message);
    outcome.span = 0;
  }
  int code = 0;
  if (outcome.kind == AGC_FAILED) {
    agc_print_diagnostic(stderr, program, &outcome, style, false);
    code = 1;
  } else if (outcome.kind == AGC_EXITED && outcome.exit_code >= 1 && outcome.exit_code <= 255) {
    code = (int)outcome.exit_code;
  }
#ifdef __linux__
  if (!settled) {
    AGC_TRACE(&trace, AGC_TRACE_IO, "hard_exit code=%d", code);
    fflush(stdout);
    fflush(stderr);
    _exit(code);
  }
#else
  (void)settled;
#endif
  return code;
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
int main(int argc, char **argv) {
#ifdef __linux__
  fill_standard_fds();
#endif
  return run(argc, argv);
}
#endif

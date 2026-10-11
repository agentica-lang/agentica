#ifdef _WIN32
#define _CRT_RAND_S
#endif
#include "agc.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <io.h>
#include <windows.h>

typedef struct _stat64 file_info;
#define file_stat _fstat64

static wchar_t **wide_args;

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
#include <unistd.h>

typedef struct stat file_info;
#define file_stat fstat

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
#include <sys/random.h>

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

static void seed_map_hash(void) {
  uint8_t key[16];
  if (!os_entropy(key, sizeof key)) return;
  uint64_t k0 = 0, k1 = 0;
  for (unsigned k = 0; k < 8; k++) {
    k0 |= (uint64_t)key[k] << (8 * k);
    k1 |= (uint64_t)key[8 + k] << (8 * k);
  }
  agc_map_seed(k0, k1);
}

#ifdef __linux__
#include <sys/prctl.h>

static bool bind_to_driver(int64_t driver) {
  if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0) return false;
  return (int64_t)getppid() == driver;
}
#else
static bool bind_to_driver(int64_t driver) {
  (void)driver;
  return true;
}
#endif

static bool incomplete_tail(const uint8_t *s, size_t len) {
  uint8_t c = s[0];
  size_t width = c >= 0xC2 && c <= 0xDF ? 2 : c >= 0xE0 && c <= 0xEF ? 3 : c >= 0xF0 && c <= 0xF4 ? 4 : 0;
  if (width == 0 || len >= width) return false;
  for (size_t k = 1; k < len; k++)
    if ((s[k] & 0xC0) != 0x80) return false;
  if (len > 1 && ((c == 0xE0 && s[1] < 0xA0) || (c == 0xF0 && s[1] < 0x90))) return false;
  return true;
}

static agc_string *decode_arg(const char *arg) {
  const uint8_t *s = (const uint8_t *)arg;
  size_t len = strlen(arg);
  agc_string *out = agc_new_string(len, 0);
  size_t at = 0, chars = 0;
  for (size_t i = 0; i < len; chars++) {
    size_t n = agc_utf8_valid(s + i, len - i);
    if (n) {
      memcpy(out->data + at, s + i, n);
      at += n;
      i += n;
    } else {
      out->data[at++] = '?';
      i = incomplete_tail(s + i, len - i) ? len : i + 1;
    }
  }
  out->bytes = at;
  out->chars = chars;
  return out;
}

static agc_value program_args(int argc, char **argv, int first) {
  size_t n = first < argc ? (size_t)(argc - first) : 0;
  agc_list *list = agc_new_list(n);
  for (size_t k = 0; k < n; k++) list->items[k] = agc_string_value(decode_arg(argv[(size_t)first + k]));
  return agc_list_value(list);
}

static const char usage[] = "usage: agentica-vm [--version] [--max-steps N] [--ai|--json] -- <file.agcb> [args...]\n";

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
  int64_t driver = 0;
  bool seen_steps = false, seen_ai = false, seen_json = false, seen_driver = false;
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
    if (strcmp(arg, "--ai") == 0 || strcmp(arg, "--json") == 0) {
      bool json = arg[2] == 'j';
      if (!once(json ? &seen_json : &seen_ai, arg)) return 2;
      style = json ? AGC_STYLE_JSON : AGC_STYLE_AI;
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
  size_t len = 0;
  uint8_t *data = read_file(i, path, seen_driver, &len);
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

  seed_map_hash();
  agc_vm *vm = agc_alloc(sizeof(agc_vm));
  agc_vm_init(vm, program, stdout, stderr, max_steps);
  vm->args = program_args(argc, argv, i + 1);
  agc_input_open(vm, 0, isatty(1));
  agc_outcome outcome = agc_vm_run(vm);
  if (outcome.kind != AGC_FAILED && fflush(stdout) != 0) {
    outcome.kind = AGC_FAILED;
    outcome.code = "RUNTIME-INTERNAL";
    outcome.message = "cannot write to standard output";
    outcome.message_len = strlen(outcome.message);
    outcome.span = 0;
  }
  if (outcome.kind == AGC_FAILED) {
    agc_print_diagnostic(stderr, program, &outcome, style);
    return 1;
  }
  if (outcome.kind == AGC_EXITED && outcome.exit_code >= 1 && outcome.exit_code <= 255) return (int)outcome.exit_code;
  return 0;
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

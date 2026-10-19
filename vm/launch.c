/*
 * What the two ways of starting a VM in the agentica binary share: the option
 * parser, the entropy for seeds, the trace setup, the runtime set-up from a
 * loaded program and the one exit path. Driver, not a layer. The choices
 * that differ (a run of the front end, `agentica run`) stay in agentica.c.
 * Design: docs/vm/08-loader-and-cli.md and docs/vm/14-core-invariants.md, 14.4.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#ifdef _WIN32
#define _CRT_RAND_S
#endif
#include "launch.h"

#include "core.h"
#include "services.h"
#include "file_io.h"

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <uv.h>

#ifdef __linux__
#include <sys/prctl.h>
#include <sys/random.h>
#endif

#ifdef _WIN32
#include <io.h>
#include <windows.h>
#include <shellapi.h>

#define TRACE_OPEN (_O_WRONLY | _O_APPEND | _O_CREAT | _O_NOINHERIT | _O_BINARY)
#define TRACE_MODE (_S_IREAD | _S_IWRITE)
#else
#include <unistd.h>

#define TRACE_OPEN (O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
#define TRACE_MODE 0600
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
bool agc_launch_bind(int64_t driver) {
  signal(SIGTERM, SIG_DFL);
  if (prctl(PR_SET_PDEATHSIG, SIGTERM) != 0) return false;
  return (int64_t)getppid() == driver;
}
#elif defined(__APPLE__)
bool agc_launch_bind(int64_t driver) { return (int64_t)getppid() == driver; }
#else
bool agc_launch_bind(int64_t driver) {
  uv_loop_t loop;
  if (uv_loop_init(&loop) != 0) return false;
  uv_pid_t parent = uv_os_getppid();
  if (uv_loop_close(&loop) != 0) return false;
  return parent > 0 && (int64_t)parent == driver;
}
#endif

const char *agc_launch_self_path(int argc, char **argv, const char *fallback, char *buffer, size_t size) {
  uv_setup_args(argc, argv);
  size_t len = size;
  if (!size || uv_exepath(buffer, &len) != 0 || len >= size) return fallback;
  buffer[len] = '\0';
  return buffer;
}

static bool flush_stream(FILE *stream) {
  while (fflush(stream) != 0) {
    if (errno != EINTR) return false;
    clearerr(stream);
  }
  return true;
}

static void flush_files(agc_vm *vm) {
  if (setjmp(vm->fail) == 0) {
    agc_io_flush_files(vm);
    return;
  }
  agc_sync_reset(vm);
  const agc_outcome *o = &vm->rt->outcome;
  agc_notice notice;
  agc_print_flush_failed(agc_notice_begin(&vm->rt->err, &notice), o->code, o->message, o->message_len, vm->rt->style);
  agc_notice_end(vm, &notice, AGC_NOTICE_FINAL);
}

static void print_outcome(agc_vm *vm, const agc_outcome *outcome, agc_notice_mode mode) {
  agc_notice notice;
  agc_print_diagnostic(agc_notice_begin(&vm->rt->err, &notice), vm->rt->program, outcome, vm->rt->style, false);
  agc_notice_end(vm, &notice, mode);
}

static void announce_outcome(agc_vm *vm, const agc_outcome *outcome) {
  if (setjmp(vm->fail) == 0) print_outcome(vm, outcome, AGC_NOTICE_KEPT);
}

/* The one exit path (docs/vm/14-core-invariants.md, 14.4): the children,
   then standard output and the files, then the exit. Nothing else is
   drained: the OS frees descriptors and memory. */
int agc_launch_settle(agc_vm *vm, agc_outcome *outcome) {
  agc_processes_stop(vm);
  agc_io_children_stopped();
  agc_io_goodbye(vm);
  bool stdout_ok = flush_stream(stdout);
  flush_stream(stderr);
  if (outcome->kind == AGC_FAILED) announce_outcome(vm, outcome);
  flush_files(vm);
  agc_files_close(vm);
  stdout_ok = stdout_ok && !agc_output_failed(&vm->rt->out);
  if (vm->rt->flush_expired) {
    agc_notice notice;
    agc_print_flush_timeout(agc_notice_begin(&vm->rt->err, &notice), vm->rt->flush_timeout, vm->rt->style);
    agc_notice_end(vm, &notice, AGC_NOTICE_FINAL);
  }
  const char *write_error = NULL;
  if (outcome->kind != AGC_FAILED && !agc_io_stop_signal()) {
    if (!stdout_ok || !flush_stream(stdout))
      write_error = "cannot write to standard output";
    else if (agc_output_failed(&vm->rt->err))
      write_error = "cannot write to standard error";
  }
  if (write_error) {
    outcome->kind = AGC_FAILED;
    outcome->code = "RUNTIME-INTERNAL";
    outcome->message = write_error;
    outcome->message_len = strlen(outcome->message);
    outcome->span = 0;
    outcome->stack.shown = false;
    print_outcome(vm, outcome, AGC_NOTICE_FINAL);
  }
  int code = 0;
  if (outcome->kind == AGC_FAILED) {
    code = 1;
  } else if (outcome->kind == AGC_EXITED && outcome->exit_code >= 1 && outcome->exit_code <= 255) {
    code = (int)outcome->exit_code;
  }
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "end code=%d signal=%d", code, agc_io_stop_signal());
  flush_stream(stdout);
  flush_stream(stderr);
  return code;
}

void agc_launch_exit(int code) {
#if defined(__linux__) || defined(__APPLE__)
  sigset_t saved;
  agc_io_block_stop(&saved);
  int sig = agc_io_stop_signal();
  if (sig) {
    signal(sig, SIG_DFL);
    pthread_sigmask(SIG_SETMASK, &saved, NULL);
    raise(sig);
  }
  _exit(code);
#else
  exit(code);
#endif
}

void agc_launch_end(agc_vm *vm, agc_outcome outcome) {
  int code = agc_launch_settle(vm, &outcome);
  agc_launch_exit(code);
}

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

#if defined(__linux__) || defined(__APPLE__)
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

void agc_launch_ignore_sigpipe(void) {
#ifdef SIGPIPE
  signal(SIGPIPE, SIG_IGN);
#endif
}

void agc_launch_init_streams(void) {
#ifdef _WIN32
  for (int fd = 0; fd <= 2; fd++)
    if (uv_guess_handle(fd) != UV_UNKNOWN_HANDLE) _setmode(fd, _O_BINARY);
  setvbuf(stdout, NULL, _IONBF, 0);
#endif
}

void agc_launch_init(agc_launch *launch) {
#if defined(__linux__) || defined(__APPLE__)
  fill_standard_fds();
#endif
  agc_launch_ignore_sigpipe();
  agc_launch_init_streams();
  agc_init();
  memset(launch, 0, sizeof *launch);
  launch->inherited = agc_files_inherited();
}

bool agc_launch_utf8_args(int *argc, char ***argv) {
#ifdef _WIN32
  int count = 0;
  wchar_t **wide = CommandLineToArgvW(GetCommandLineW(), &count);
  if (!wide) return false;
  char **words = agc_alloc(agc_size_mul(agc_size_add((size_t)count, 1), sizeof(char *)));
  for (int k = 0; k < count; k++) {
    int len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide[k], -1, NULL, 0, NULL, NULL);
    if (!len) { LocalFree(wide); return false; }
    words[k] = agc_alloc_atomic((size_t)len);
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide[k], -1, words[k], len, NULL, NULL)) {
      LocalFree(wide);
      return false;
    }
  }
  words[count] = NULL;
  LocalFree(wide);
  *argc = count;
  *argv = words;
#else
  (void)argc;
  (void)argv;
#endif
  return true;
}

void agc_launch_trace(agc_launch *launch) {
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
  agc_trace_parse(&launch->trace, names, fd);
}

agc_value agc_launch_args(int argc, char **argv, int first) {
  size_t n = first < argc ? (size_t)(argc - first) : 0;
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t k = 0; k < n; k++) {
    const char *arg = argv[(size_t)first + k];
    agc_list_builder_push(&b, agc_string_value(agc_utf8_decode((const uint8_t *)arg, strlen(arg), "?", true)));
  }
  return agc_list_value(agc_list_builder_finish(&b));
}

uint8_t *agc_launch_read(int fd, size_t size) {
  if (size > AGC_MAX_FILE_BYTES) { agc_fs_close(fd); return NULL; }
  uint8_t *data = agc_alloc_atomic(size);
  size_t done = 0;
  while (done < size) {
    int64_t n = agc_fs_read(fd, data + done, size - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    done += (size_t)n;
  }
  agc_fs_close(fd);
  return done == size ? data : NULL;
}

uint8_t *agc_launch_file(const char *path, bool driven, size_t *size) {
  int fd = agc_fs_bytecode_open(path, driven, AGC_MAX_FILE_BYTES, size);
  return fd < 0 ? NULL : agc_launch_read(fd, *size);
}

static bool once(const char *name, bool *seen, const char *option) {
  if (*seen) {
    fprintf(stderr, "%s: the %s option can only be specified once\n", name, option);
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

static bool parse_flush(const char *text, int64_t *ms) {
  return parse_count(text, ms) && *ms <= AGC_FLUSH_TIMEOUT_MAX_MS;
}

static bool parse_schedulers(const char *text, int64_t *count) {
  return parse_count(text, count) && *count >= 1 && *count <= AGC_SCHEDULERS_MAX;
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

void agc_launch_defaults(agc_launch_options *options) {
  memset(options, 0, sizeof *options);
  options->max_steps = INT64_MAX;
  options->flush_timeout = AGC_FLUSH_TIMEOUT_MS;
  options->schedulers = 1;
  options->style = AGC_STYLE_PLAIN;
  options->source_root = "";
}

bool agc_launch_env(const char *name, agc_launch_options *options) {
  const char *flush = getenv("AGENTICA_FLUSH_TIMEOUT_MS");
  int64_t ms = 0;
  if (flush && !parse_flush(flush, &ms)) {
    fprintf(stderr, "%s: AGENTICA_FLUSH_TIMEOUT_MS needs an integer from 0 to 86400000\n", name);
    return false;
  }
  if (flush && !options->seen_flush) options->flush_timeout = ms;
  /* A bad variable is an error even when the flag is given, as the flush limit's is: the flag wins over a valid value
     only. */
  const char *schedulers = getenv("AGENTICA_SCHEDULERS");
  int64_t count = 0;
  if (schedulers && !parse_schedulers(schedulers, &count)) {
    fprintf(stderr, "%s: AGENTICA_SCHEDULERS needs an integer from 1 to %d\n", name, AGC_SCHEDULERS_MAX);
    return false;
  }
  if (schedulers && !options->seen_schedulers) options->schedulers = count;
  return true;
}

/* More than one scheduler runs only under the test switch AGENTICA_VM_TEST_MULTICORE=1 until the count is lifted
   (#345). The profile trace counts on one scheduler, and the test-only blocking output holds a stream lock across a
   write, which the end of a run with scheduler threads cannot wait for: both refuse a larger count. */
bool agc_launch_supported(const char *name, const agc_launch_options *options) {
  if (options->schedulers <= 1) return true;
  const char *multicore = getenv("AGENTICA_VM_TEST_MULTICORE");
  if (!multicore || strcmp(multicore, "1") != 0) {
    fprintf(stderr, "%s: %" PRId64 " schedulers were asked for, but this build runs one\n", name, options->schedulers);
    return false;
  }
  if (agc_trace_mask(getenv("AGENTICA_VM_TRACE")) & AGC_TRACE_PROFILE) {
    fprintf(stderr, "%s: the profile trace needs one scheduler\n", name);
    return false;
  }
  const char *blocking = getenv("AGENTICA_VM_TEST_BLOCKING_OUTPUT");
  if (blocking && strcmp(blocking, "1") == 0) {
    fprintf(stderr, "%s: AGENTICA_VM_TEST_BLOCKING_OUTPUT needs one scheduler\n", name);
    return false;
  }
  return true;
}

static agc_launch_status refuse(const char *name, const char *message) {
  fprintf(stderr, "%s: %s\n", name, message);
  return AGC_LAUNCH_BAD;
}

agc_launch_status agc_launch_parse(const char *name, int argc, char **argv, int *at, agc_launch_options *options) {
  agc_launch_defaults(options);
  bool seen_steps = false, seen_ai = false, seen_json = false, seen_root = false;
  int i = *at;
  while (i < argc) {
    const char *arg = argv[i];
    const char *value = i + 1 < argc ? argv[i + 1] : NULL;
    if (strcmp(arg, "--") == 0) {
      i++;
      break;
    }
    if (strcmp(arg, "--version") == 0) {
      *at = i;
      return AGC_LAUNCH_VERSION;
    }
    if (strcmp(arg, "--ai") == 0 || strcmp(arg, "--json") == 0) {
      bool json = arg[2] == 'j';
      if (!once(name, json ? &seen_json : &seen_ai, arg)) return AGC_LAUNCH_BAD;
      options->style = json ? AGC_STYLE_JSON : AGC_STYLE_AI;
      i++;
    } else if (strcmp(arg, "--allow-run") == 0) {
      if (!once(name, &options->allow_run, arg)) return AGC_LAUNCH_BAD;
      i++;
    } else if (strcmp(arg, "--max-steps") == 0) {
      if (!once(name, &seen_steps, arg)) return AGC_LAUNCH_BAD;
      if (!value || !parse_steps(value, &options->max_steps))
        return refuse(name, "--max-steps needs a positive integer");
      i += 2;
    } else if (strcmp(arg, "--seed") == 0) {
      if (!once(name, &options->seen_seed, arg)) return AGC_LAUNCH_BAD;
      if (!value || !parse_seed(value, &options->seed))
        return refuse(name, "--seed needs an integer from 0 to 2147483647");
      i += 2;
    } else if (strcmp(arg, "--flush-timeout") == 0) {
      if (!once(name, &options->seen_flush, arg)) return AGC_LAUNCH_BAD;
      if (!value || !parse_flush(value, &options->flush_timeout))
        return refuse(name, "--flush-timeout needs an integer from 0 to 86400000");
      i += 2;
    } else if (strcmp(arg, "--schedulers") == 0) {
      if (!once(name, &options->seen_schedulers, arg)) return AGC_LAUNCH_BAD;
      if (!value || !parse_schedulers(value, &options->schedulers))
        return refuse(name, "--schedulers needs an integer from 1 to 1024");
      i += 2;
    } else if (strcmp(arg, "--source-root") == 0) {
      if (!once(name, &seen_root, arg)) return AGC_LAUNCH_BAD;
      if (!value || strcmp(value, "--") == 0 ||
          !agc_utf8_chars((const uint8_t *)value, strlen(value), &options->source_root_chars))
        return refuse(name, "--source-root needs a folder name in UTF-8");
      options->source_root = value;
      i += 2;
    } else if (strcmp(arg, "--embedded") == 0) {
      bool seen = options->embedded != NULL;
      if (!once(name, &seen, arg)) return AGC_LAUNCH_BAD;
      if (!value || strcmp(value, "--") == 0) return refuse(name, "--embedded needs a program name");
      options->embedded = value;
      i += 2;
    } else if (strcmp(arg, "--driver-pid") == 0) {
      if (!once(name, &options->seen_driver, arg)) return AGC_LAUNCH_BAD;
      if (!value || !parse_steps(value, &options->driver))
        return refuse(name, "--driver-pid needs a positive integer");
      i += 2;
    } else if (arg[0] == '-' && arg[1] != '\0') {
      fprintf(stderr, "%s: unknown option %s\n", name, arg);
      return AGC_LAUNCH_BAD;
    } else {
      break;
    }
  }
  *at = i;
  return AGC_LAUNCH_OK;
}

agc_vm *agc_launch_vm(agc_launch *launch, const agc_program *program, const agc_launch_options *options,
                      agc_value args, agc_front_end *front_end) {
  if (!launch->io_started) {
    launch->own_uring_env = agc_io_init();
    launch->io_started = true;
  }
  agc_vm *vm = agc_alloc(sizeof(agc_vm));
  agc_vm_init(vm, program, stdout, stderr, options->max_steps);
  agc_runtime *rt = vm->rt;
  rt->trace = launch->trace;
  rt->style = options->style;
  rt->flush_timeout = options->flush_timeout;
  rt->allow_run = options->allow_run;
  rt->drop_uring_env = launch->own_uring_env;
  rt->inherited = launch->inherited;
  rt->front_end = front_end;
  rt->schedulers = front_end ? 1 : options->schedulers;
  seed_map_hash(vm);
  agc_files_init(vm);
  const char *no_turn_cost = getenv("AGENTICA_VM_TEST_NO_TURN_COST");
  rt->no_turn_cost = no_turn_cost && strcmp(no_turn_cost, "1") == 0;
  /* Test-only: run on one scheduler with every lock on (agc_share), so the whole suite goes through the locking code
     of the shared state until the scheduler threads exist. */
  const char *shared = getenv("AGENTICA_VM_TEST_SHARED");
  if (shared && strcmp(shared, "1") == 0 && !front_end) agc_share(vm);
  rt->seed = options->seen_seed ? options->seed : entropy_seed();
  agc_random_seed(&vm->rt->main->random, rt->seed);
  rt->args = args;
  if (!front_end) {
    agc_parent_take(vm);
    agc_input_open(vm, 0, isatty(1));
  }
  const char *blocking_output = getenv("AGENTICA_VM_TEST_BLOCKING_OUTPUT");
  if (!blocking_output || strcmp(blocking_output, "1") != 0) {
    agc_output_open(vm, &rt->out, 1);
    agc_output_open(vm, &rt->err, 2);
  }
  agc_io_watch_stop(vm, options->seen_driver ? options->driver : 0);
  return vm;
}

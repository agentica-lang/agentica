/* The independent peer of the native calls (tests/test_vm_native.py): a shared library that the test builds with the
   system C compiler, so each C type crosses the boundary through a real ABI. On Windows it is a DLL linked with
   ws2_32, and the "pipe" of the descriptor functions is a connected loopback TCP pair: Native.wait_* polls only
   sockets there. */
#define _GNU_SOURCE
#include <ctype.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <winsock2.h>
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#else
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#endif

static char shout[64];
static int32_t bumps;
static atomic_int flag, returned, waiting, naps, stalled;

/* Sleeps MS milliseconds. */
static void sleep_ms(int32_t ms) {
#ifdef _WIN32
  Sleep((DWORD)ms);
#else
  struct timespec nap = {ms / 1000, (long)(ms % 1000) * 1000000L};
  while (nanosleep(&nap, &nap) != 0) {}
#endif
}

int32_t peer_add(int32_t a, int32_t b) { return a + b; }
int64_t peer_mul64(int64_t a, int64_t b) { return a * b; }
double peer_scale(double x, double k) { return x * k; }
bool peer_not(bool b) { return !b; }
int64_t peer_len(const char *s) { return (int64_t)strlen(s); }
void peer_bump(void) { bumps++; }
int32_t peer_bumps(void) { return bumps; }
const char *peer_null(void) { return NULL; }
const char *peer_bad_utf8(void) { return "a\xff" "b"; }

/* The returned text stays in the library; Agentica copies it. */
const char *peer_upper(const char *s) {
  size_t k = 0;
  for (; s[k] && k + 1 < sizeof shout; k++) shout[k] = (char)toupper((unsigned char)s[k]);
  shout[k] = '\0';
  return shout;
}

/* More integer and floating arguments than the registers hold, so some go on the stack. */
int64_t peer_sum9(int32_t a, int32_t b, int32_t c, int32_t d, int32_t e, int32_t f, int32_t g, int32_t h, int64_t i) {
  return (int64_t)a + b + c + d + e + f + g + h + i;
}

double peer_mix(int32_t a, double b, int64_t c, bool d, const char *s, double e, double f, double g, double h,
                double i, double j, double k, double l) {
  return a + b + (double)c + (d ? 1000.0 : 0.0) + (double)strlen(s) + e + f + g + h + i + j + k + l;
}

/* A variadic function: KINDS names the type of each variadic argument (i int, l int64_t, j uint32_t, n long, d double,
   s a string, which adds its length, y bytes, which add the first byte, p a pointer, which adds its address), and it
   returns the sum. */
static double vmix_sum(const char *kinds, va_list args) {
  double sum = 0;
  for (const char *kind = kinds; *kind; kind++) {
    switch (*kind) {
      case 'i': sum += va_arg(args, int); break;
      case 'l': sum += (double)va_arg(args, int64_t); break;
      case 'j': sum += va_arg(args, uint32_t); break;
      case 'n': sum += (double)va_arg(args, long); break;
      case 'd': sum += va_arg(args, double); break;
      case 's': sum += (double)strlen(va_arg(args, const char *)); break;
      case 'y': sum += *va_arg(args, const uint8_t *); break;
      case 'p': sum += (double)(intptr_t)va_arg(args, void *); break;
      default: break;
    }
  }
  return sum;
}

double peer_vmix(const char *kinds, ...) {
  va_list args;
  va_start(args, kinds);
  double sum = vmix_sum(kinds, args);
  va_end(args);
  return sum;
}

/* peer_vmix with an out pointer before the variadic part: COUNT gets the number of kinds. */
double peer_vmix_out(int32_t *count, const char *kinds, ...) {
  *count = (int32_t)strlen(kinds);
  va_list args;
  va_start(args, kinds);
  double sum = vmix_sum(kinds, args);
  va_end(args);
  return sum;
}

/* For compute defs, which run on a pool thread. peer_wait_flag returns 1 once peer_set_flag (a fast call from another
   task) has run, or 0 after LIMIT_MS milliseconds; each start and each return is counted. */
int32_t peer_wait_flag(int32_t limit_ms) {
  atomic_fetch_add(&waiting, 1);
  int32_t found = 0;
  for (int32_t k = 0; k < limit_ms && !found; k++) {
    found = atomic_load(&flag);
    if (!found) sleep_ms(1);
  }
  atomic_fetch_add(&returned, 1);
  return found;
}

void peer_set_flag(void) { atomic_store(&flag, 1); }
int32_t peer_returned(void) { return atomic_load(&returned); }
int32_t peer_waiting(void) { return atomic_load(&waiting); }

/* The text is in a buffer of the calling thread, which the next call on that thread overwrites. */
const char *peer_word(int32_t n) {
  static _Thread_local char word[8];
  memset(word, 'a' + n % 26, 3);
  word[3] = '\0';
  return word;
}

double peer_half(int64_t n) { return (double)n / 2.0; }

static atomic_int nap_starts;

/* Counts one started nap, sleeps MS milliseconds, then counts one nap. */
int32_t peer_nap(int32_t ms) {
  atomic_fetch_add(&nap_starts, 1);
  sleep_ms(ms);
  atomic_fetch_add(&naps, 1);
  return ms;
}

/* How many peer_nap calls have started. */
int32_t peer_nap_starts(void) { return atomic_load(&nap_starts); }

int32_t peer_naps(void) { return atomic_load(&naps); }

/* Writes through the C library into a pipe that nobody reads, as a library that logs to a stalled pipe does: once the
   pipe is full, the call waits inside fwrite and holds the stream's lock. It returns only if the write fails.
   peer_write_started is 1 once the writes have begun. */
int32_t peer_write_stalled(void) {
  int fds[2];
#ifdef _WIN32
  if (_pipe(fds, 4096, _O_BINARY) != 0) return -1;
  FILE *log = _fdopen(fds[1], "wb");
#else
  if (pipe(fds) != 0) return -1;
  FILE *log = fdopen(fds[1], "wb");
#endif
  if (!log) return -1;
  static char block[1 << 16];
  atomic_store(&stalled, 1);
  for (;;)
    if (fwrite(block, 1, sizeof block, log) != sizeof block) return -1;
}

int32_t peer_write_started(void) { return atomic_load(&stalled); }

#ifndef _WIN32
/* Holds a standard C stream lock and then blocks writing to its pipe, marking lock ownership independently. */
int32_t peer_hold_stdio(int32_t which, const char *marker) {
  FILE *stream = which == 1 ? stdout : stderr;
  static char block[1 << 16];
  flockfile(stream);
  (void)fwrite("native-locked\n", 1, sizeof "native-locked\n" - 1, stream);
  int fd = open(marker, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) {
    funlockfile(stream);
    return -1;
  }
  ssize_t written = write(fd, "locked", 6);
  close(fd);
  if (written != 6) {
    funlockfile(stream);
    return -1;
  }
  for (;;) fwrite(block, 1, sizeof block, stream);
}

/* Leaves a small native C stdio buffer for the other standard stream to flush at settlement. */
int32_t peer_buffer_stdio(int32_t which) {
  FILE *stream = which == 1 ? stdout : stderr;
  return (int32_t)fwrite("native-free\n", 1, sizeof "native-free\n" - 1, stream);
}
#endif

#ifdef _WIN32
/* For Native.wait_readable and wait_writable: a non-blocking connected pair of loopback TCP sockets that the peer owns,
   as a library owns its socket. Windows has no socketpair: the pair is a listen on 127.0.0.1 port 0, a connect and an
   accept. Small buffers let peer_pipe_fill fill it quickly. */
static SOCKET pipe_fds[2] = {INVALID_SOCKET, INVALID_SOCKET};

static void set_nonblocking(SOCKET s, u_long on) { (void)ioctlsocket(s, FIONBIO, &on); }

/* Opens the pair and returns its read end, or -1. */
int32_t peer_pipe(void) {
  WSADATA data;
  if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return -1;
  struct sockaddr_in at = {0};
  at.sin_family = AF_INET;
  at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int len = sizeof at, small = 4096;
  SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  pipe_fds[1] = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (listener == INVALID_SOCKET || pipe_fds[1] == INVALID_SOCKET) return -1;
  (void)setsockopt(listener, SOL_SOCKET, SO_RCVBUF, (const char *)&small, sizeof small);
  (void)setsockopt(pipe_fds[1], SOL_SOCKET, SO_SNDBUF, (const char *)&small, sizeof small);
  if (bind(listener, (struct sockaddr *)&at, sizeof at) != 0 || listen(listener, 1) != 0 ||
      getsockname(listener, (struct sockaddr *)&at, &len) != 0 ||
      connect(pipe_fds[1], (struct sockaddr *)&at, sizeof at) != 0)
    return -1;
  pipe_fds[0] = accept(listener, NULL, NULL);
  closesocket(listener);
  if (pipe_fds[0] == INVALID_SOCKET) return -1;
  set_nonblocking(pipe_fds[0], 1);
  set_nonblocking(pipe_fds[1], 1);
  return (int32_t)pipe_fds[0];
}

int32_t peer_pipe_writer(void) { return (int32_t)pipe_fds[1]; }

/* Writes one byte into the pair; 1 when it went in. */
int32_t peer_pipe_put(void) { return (int32_t)send(pipe_fds[1], "x", 1, 0); }

/* Reads what the pair holds; the number of bytes read. */
int32_t peer_pipe_take(void) {
  char buf[256];
  int32_t total = 0;
  int n;
  while ((n = recv(pipe_fds[0], buf, sizeof buf, 0)) > 0) total += n;
  return total;
}

/* Writes until the pair is full, so its write end no longer polls writable. */
void peer_pipe_fill(void) {
  char buf[4096];
  memset(buf, 'y', sizeof buf);
  while (send(pipe_fds[1], buf, sizeof buf, 0) > 0) {}
}

/* Makes both ends of the pair blocking. */
void peer_pipe_blocking(void) {
  for (int k = 0; k < 2; k++) set_nonblocking(pipe_fds[k], 0);
}

/* Winsock cannot read back the non-blocking mode of a socket: -1. */
int32_t peer_nonblocking(int32_t fd) {
  (void)fd;
  return -1;
}

/* A value that is not a socket: the handle of a regular file, deleted when it closes. */
int32_t peer_regular_file(void) {
  char dir[MAX_PATH], path[MAX_PATH];
  if (!GetTempPathA(sizeof dir, dir) || !GetTempFileNameA(dir, "agc", 0, path)) return -1;
  HANDLE h = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, NULL);
  return h == INVALID_HANDLE_VALUE ? -1 : (int32_t)(intptr_t)h;
}

/* 1 when S is a socket on the local address of either end of the pair. */
static int32_t of_pair(SOCKET s) {
  struct sockaddr_in at, end;
  int type, len = sizeof type;
  if (getsockopt(s, SOL_SOCKET, SO_TYPE, (char *)&type, &len) != 0) return 0;
  len = sizeof at;
  if (getsockname(s, (struct sockaddr *)&at, &len) != 0 || at.sin_family != AF_INET) return 0;
  for (int k = 0; k < 2; k++) {
    len = sizeof end;
    if (getsockname(pipe_fds[k], (struct sockaddr *)&end, &len) == 0 && end.sin_port == at.sin_port) return 1;
  }
  return 0;
}

/* The number of sockets open on the pair (its two ends and their duplicates). A process's handle count also moves with
   threads and with libuv's own sockets, so the handle values are probed instead. */
int32_t peer_open_fds(void) {
  int32_t n = 0;
  for (uintptr_t h = 4; h < 65536; h += 4) n += of_pair((SOCKET)h);
  return n;
}
#else
/* For Native.wait_readable and wait_writable: a non-blocking pipe that the peer owns, as a library owns its socket. */
static int pipe_fds[2] = {-1, -1};

/* Opens the pipe and returns its read end, or -1. macOS has no pipe2. */
int32_t peer_pipe(void) {
  if (pipe(pipe_fds) != 0) return -1;
  for (int k = 0; k < 2; k++) {
    (void)fcntl(pipe_fds[k], F_SETFL, O_NONBLOCK);
    (void)fcntl(pipe_fds[k], F_SETFD, FD_CLOEXEC);
  }
  return pipe_fds[0];
}
int32_t peer_pipe_writer(void) { return pipe_fds[1]; }

/* Writes one byte into the pipe; 1 when it went in. */
int32_t peer_pipe_put(void) { return (int32_t)write(pipe_fds[1], "x", 1); }

/* Reads what the pipe holds; the number of bytes read. */
int32_t peer_pipe_take(void) {
  char buf[256];
  int32_t total = 0;
  ssize_t n;
  while ((n = read(pipe_fds[0], buf, sizeof buf)) > 0) total += (int32_t)n;
  return total;
}

/* Writes until the pipe is full, so its write end no longer polls writable. */
void peer_pipe_fill(void) {
  char buf[4096];
  memset(buf, 'y', sizeof buf);
  while (write(pipe_fds[1], buf, sizeof buf) > 0) {}
}

/* Makes both ends of the pipe blocking, as a terminal usually is. */
void peer_pipe_blocking(void) {
  for (int k = 0; k < 2; k++) (void)fcntl(pipe_fds[k], F_SETFL, fcntl(pipe_fds[k], F_GETFL) & ~O_NONBLOCK);
}

/* 1 when FD is in non-blocking mode, 0 when not, -1 when it is not open. */
int32_t peer_nonblocking(int32_t fd) {
  int flags = fcntl(fd, F_GETFL);
  return flags < 0 ? -1 : (flags & O_NONBLOCK) != 0;
}

/* A descriptor that cannot be polled: a regular file, unlinked at once. (/dev/null cannot be polled on Linux, but
   kqueue calls it always ready.) */
int32_t peer_regular_file(void) {
  char path[] = "/tmp/agentica-peer-XXXXXX";
  int fd = mkstemp(path);
  if (fd >= 0) (void)unlink(path);
  return fd;
}

/* A named FIFO at PATH, with a reader and a writer that the peer owns; its read end, or -1. */
static int fifo_fds[2] = {-1, -1};

int32_t peer_fifo(const char *path) {
  if (mkfifo(path, 0600) != 0) return -1;
  fifo_fds[0] = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  fifo_fds[1] = fifo_fds[0] < 0 ? -1 : open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
  return fifo_fds[1] < 0 ? -1 : fifo_fds[0];
}

/* Writes one byte into the FIFO; 1 when it went in. */
int32_t peer_fifo_put(void) { return (int32_t)write(fifo_fds[1], "x", 1); }

/* A terminal: its master, or -1. The peer keeps the slave open. */
static int pty_slave = -1;

int32_t peer_pty(void) {
  int master = posix_openpt(O_RDWR | O_NOCTTY);
  if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0) return -1;
  const char *name = ptsname(master);
  pty_slave = name ? open(name, O_RDWR | O_NOCTTY | O_CLOEXEC) : -1;
  return pty_slave < 0 ? -1 : master;
}

/* Writes one byte on the slave side, which the master then reads; 1 when it went in. */
int32_t peer_pty_put(void) { return (int32_t)write(pty_slave, "x", 1); }

/* The number of descriptors the process has open. */
int32_t peer_open_fds(void) {
#ifdef __APPLE__
  DIR *dir = opendir("/dev/fd");
#else
  DIR *dir = opendir("/proc/self/fd");
#endif
  if (!dir) return -1;
  int32_t n = 0;
  while (readdir(dir)) n++;
  closedir(dir);
  return n;
}
#endif

/* For resources: a malloc'd struct that peer_res_free frees and counts. peer_res_hold, a compute call, marks it busy
   until peer_set_flag has run (or LIMIT_MS passed), so a free that comes while C still uses it is counted apart. */
typedef struct {
  int32_t value;
  atomic_int busy;
} peer_res;

static atomic_int res_opens, res_frees, res_busy_frees;

void *peer_res_open(int32_t value) {
  if (value < 0) return NULL;
  peer_res *r = malloc(sizeof *r);
  if (!r) return NULL;
  r->value = value;
  atomic_init(&r->busy, 0);
  atomic_fetch_add(&res_opens, 1);
  return r;
}

void peer_res_free(void *p) {
  peer_res *r = p;
  if (atomic_load(&r->busy)) atomic_fetch_add(&res_busy_frees, 1);
  atomic_fetch_add(&res_frees, 1);
  free(r);
}

/* The same free under a name that starts with a capital letter, as in libpq (PQfinish) and OpenSSL (SSL_free). */
void PeerFree(void *p) { peer_res_free(p); }

/* For free_ref: a free that takes the address of the handle, as duckdb_close(duckdb_database *) does: it frees
   the resource and writes NULL there. A call with a NULL handle, a second free of the same handle, is counted apart. */
static atomic_int res_closes, res_null_closes;

void peer_res_close(void **p) {
  if (!*p) {
    atomic_fetch_add(&res_null_closes, 1);
    return;
  }
  atomic_fetch_add(&res_closes, 1);
  peer_res_free(*p);
  *p = NULL;
}

int32_t peer_res_closes(void) { return atomic_load(&res_closes); }
int32_t peer_res_null_closes(void) { return atomic_load(&res_null_closes); }

int32_t peer_res_get(void *p) { return ((peer_res *)p)->value; }
int32_t peer_res_opens(void) { return atomic_load(&res_opens); }
int32_t peer_res_frees(void) { return atomic_load(&res_frees); }
int32_t peer_res_busy_frees(void) { return atomic_load(&res_busy_frees); }

static atomic_int res_holding;

int32_t peer_res_hold(void *p, int32_t limit_ms) {
  peer_res *r = p;
  atomic_store(&r->busy, 1);
  atomic_fetch_add(&res_holding, 1);
  peer_wait_flag(limit_ms);
  int32_t value = r->value;
  atomic_store(&r->busy, 0);
  return value;
}

/* How many peer_res_hold calls have started. */
int32_t peer_res_holding(void) { return atomic_load(&res_holding); }

/* A compute call that opens a resource once peer_set_flag has run. */
void *peer_res_open_later(int32_t value, int32_t limit_ms) {
  peer_wait_flag(limit_ms);
  return peer_res_open(value);
}

/* For the end of the run, which the program cannot watch: a resource that writes down its own free. peer_note_open
   makes one that appends the line TAG to the file PATH when peer_note_free frees it, so the file shows which frees ran
   and in what order. peer_note_free_slow first sleeps 20 seconds, a free that hangs. peer_note_hold, a compute call,
   appends "returned" once it has slept MS milliseconds, so a free that waits for it comes after that line. */
typedef struct {
  char path[1024];
  char tag[64];
} peer_note;

static atomic_int note_holding;

static void note_line(const char *path, const char *line) {
  FILE *f = fopen(path, "a");
  if (!f) return;
  fputs(line, f);
  fputc('\n', f);
  fclose(f);
}

void *peer_note_open(const char *path, const char *tag) {
  peer_note *n = calloc(1, sizeof *n);
  if (!n) return NULL;
  snprintf(n->path, sizeof n->path, "%s", path);
  snprintf(n->tag, sizeof n->tag, "%s", tag);
  return n;
}

void *peer_note_open_slow(const char *path, const char *tag) { return peer_note_open(path, tag); }

void peer_note_free(void *p) {
  peer_note *n = p;
  note_line(n->path, n->tag);
  free(n);
}

void peer_note_free_slow(void *p) {
  sleep_ms(20000);
  peer_note_free(p);
}

int32_t peer_note_hold(void *p, int32_t ms) {
  atomic_fetch_add(&note_holding, 1);
  sleep_ms(ms);
  note_line(((peer_note *)p)->path, "returned");
  return ms;
}

int32_t peer_note_holding(void) { return atomic_load(&note_holding); }

/* For C.Bytes: the sum of the N bytes. */
int32_t peer_bytes_sum(const uint8_t *bytes, int32_t n) {
  int32_t sum = 0;
  for (int32_t k = 0; k < n; k++) sum += bytes[k];
  return sum;
}

/* For a resource with C.Bytes: the value plus the sum of the N bytes. */
int32_t peer_res_bytes(void *p, const uint8_t *bytes, int32_t n) { return peer_res_get(p) + peer_bytes_sum(bytes, n); }

/* For C.Pointer. */
static int32_t somewhere = 42;
void *peer_ptr_echo(void *p) { return p; }
void *peer_ptr_static(void) { return &somewhere; }
int32_t peer_ptr_read(void *p) { return *(int32_t *)p; }

/* For out parameters: one of each type, with an out resource of peer_res_open(N). */
int32_t peer_out_all(int32_t n, int32_t *i, int64_t *l, double *d, bool *b, void **p, void **res) {
  *i = n + 1;
  *l = (int64_t)n * 3000000000;
  *d = n / 4.0;
  *b = n > 0;
  *p = &somewhere;
  *res = peer_res_open(n);
  return n * 2;
}

/* An open that fails and writes NULL, as sqlite3_open does when it has no memory. */
int32_t peer_out_null(void **res) {
  *res = NULL;
  return -1;
}

/* A function that leaves its out slot as it found it. */
int32_t peer_out_untouched(void **res) {
  (void)res;
  return 0;
}

/* A Void function with an out parameter. */
void peer_out_twice(int32_t n, int32_t *twice) { *twice = 2 * n; }

/* A compute call that opens its out resource once peer_set_flag has run. */
int32_t peer_out_open_later(int32_t value, int32_t limit_ms, void **res) {
  peer_wait_flag(limit_ms);
  *res = peer_res_open(value);
  return value;
}

/* For Native.get_string and get_bytes: UTF-8 text with a NUL inside, 12 bytes before the last NUL. And for
   Native.pointer: the integer value of a pointer. */
static const char text_with_nul[] = "h\xc3\xa9llo\0world";
const void *peer_text(void) { return text_with_nul; }
int64_t peer_ptr_value(void *p) { return (int64_t)(intptr_t)p; }

/* C.Float: a float result, and float arguments mixed with the other types, more than the registers hold (8 floating
   registers on x86_64 System V and arm64, 4 slots in all on Windows x64), so some go on the stack. */
float peer_scalef(float x, float k) { return x * k; }
double peer_fmix(int32_t a, float b, double c, float d, int64_t e, float f, float g, float h, float i, float j,
                 float k, float l, float m) {
  return a + b + c + d + (double)e + f + g + h + i + j + k + l + m;
}
void peer_out_half(float x, float *half) { *half = x / 2; }

/* For owned buffers: C fills and reads memory that Agentica owns, as llama.cpp and onnxruntime do. */
void peer_fill_floats(float *out, int32_t n) {
  for (int32_t k = 0; k < n; k++) out[k] = (float)k * 0.5f;
}
double peer_sum_floats(const float *xs, int32_t n) {
  double sum = 0;
  for (int32_t k = 0; k < n; k++) sum += xs[k];
  return sum;
}
void peer_fill_ints(int32_t *out, int32_t n) {
  for (int32_t k = 0; k < n; k++) out[k] = k * k - 3;
}
int64_t peer_sum_int64s(const int64_t *xs, int32_t n) {
  int64_t sum = 0;
  for (int32_t k = 0; k < n; k++) sum += xs[k];
  return sum;
}
/* The total length of N C strings, given as an array of pointers (onnxruntime's input names). */
int64_t peer_strs_len(const char *const *strs, int32_t n) {
  int64_t sum = 0;
  for (int32_t k = 0; k < n; k++) sum += (int64_t)strlen(strs[k]);
  return sum;
}
/* Text with a length (sqlite3_bind_text, mysql_real_query): the sum of each of the LEN bytes times its place from 1,
   so a byte cut off or out of order changes it. */
int64_t peer_text_sum(const char *p, int32_t len) {
  int64_t sum = 0;
  for (int32_t k = 0; k < len; k++) sum += (int64_t)(k + 1) * (uint8_t)p[k];
  return sum;
}
/* SQLite's pzTail: a pointer into the input past the first ';' of its LEN bytes, or at its end when it has none. */
const char *peer_tail(const char *p, int32_t len) {
  const char *semi = memchr(p, ';', (size_t)len);
  return semi ? semi + 1 : p + len;
}
/* Memory that C owns, read through a plain C.Pointer: 1.5, -2.25 and 1e30 as floats, then 7 and -9 as int64. */
static const float static_floats[] = {1.5f, -2.25f, 1e30f};
static const int64_t static_int64s[] = {7, -9};
const void *peer_static_floats(void) { return static_floats; }
const void *peer_static_int64s(void) { return static_int64s; }
/* A compute call that holds a buffer of floats until peer_set_flag has run, then sums it: a buffer freed meanwhile
   would give another sum (the allocator writes into a freed block). */
double peer_floats_hold(const float *xs, int32_t n, int32_t limit_ms) {
  atomic_fetch_add(&res_holding, 1);
  peer_wait_flag(limit_ms);
  return peer_sum_floats(xs, n);
}

/* For C function pointers: a table of them, as onnxruntime's OrtApi is. peer_get_api_base gives the base, whose
   get_api(1) gives the table (NULL for another version). The resources of the table are peer_res values, freed only
   through its release slot, which counts them apart. The table has a NULL slot, which a call must refuse. */
static atomic_int api_releases;

static int32_t api_add(int32_t a, int32_t b) { return a + b; }
static double api_mix(int32_t a, double b, float c, int64_t d) { return a + b + c + (double)d; }
static int32_t api_create(int32_t value, void **out) {
  *out = peer_res_open(value);
  return *out ? 0 : 1;
}
static void *api_open(int32_t value) { return peer_res_open(value); }
static void api_release(void *p) {
  atomic_fetch_add(&api_releases, 1);
  peer_res_free(p);
}
static int32_t api_get(void *p) { return peer_res_get(p); }
static int32_t api_read(void *p) { return *(int32_t *)p; }
static double api_half(double x) { return x / 2; }
/* A compute call that makes its out resource once peer_set_flag has run. */
static int32_t api_create_later(int32_t value, int32_t limit_ms, void **out) {
  peer_wait_flag(limit_ms);
  return api_create(value, out);
}

typedef struct {
  int32_t (*add)(int32_t, int32_t);
  double (*mix)(int32_t, double, float, int64_t);
  int32_t (*create)(int32_t, void **);
  void *(*open)(int32_t);
  void (*release)(void *);
  int32_t (*get)(void *);
  int32_t (*read)(void *);
  double (*half)(double);
  int32_t (*create_later)(int32_t, int32_t, void **);
  void (*missing)(void);
} peer_api;

static const peer_api api_table = {api_add, api_mix, api_create, api_open, api_release, api_get, api_read, api_half,
                                   api_create_later, NULL};

static const peer_api *api_get_api(int32_t version) { return version == 1 ? &api_table : NULL; }
static const char *api_version(void) { return "peer-api-1"; }

typedef struct {
  const peer_api *(*get_api)(int32_t);
  const char *(*version)(void);
} peer_api_base;

static const peer_api_base api_base = {api_get_api, api_version};

const void *peer_get_api_base(void) { return &api_base; }
/* A named maker whose value is freed only through the table's release slot, which the program passes. */
void *peer_api_thing(void) { return peer_res_open(5); }
int32_t peer_api_releases(void) { return atomic_load(&api_releases); }

/* For C structs by value, one per class of the ABIs: two int32 (8 bytes, one integer register), an int32 and a double
   (an integer and a floating register on x86_64), four floats (a homogeneous float aggregate: four floating registers
   on arm64), a struct larger than 16 bytes with bool and pointer fields (in memory; Windows x64 passes it by a hidden
   pointer) like llama.cpp's params, a nested struct, and a batch that points at the caller's tokens. */
typedef struct {
  int32_t x, y;
} peer_pair;
typedef struct {
  int32_t n;
  double x;
} peer_mixed;
typedef struct {
  float a, b, c, d;
} peer_quad;
typedef struct {
  int32_t n_ctx;
  int32_t n_threads;
  int64_t seed;
  double rope_freq_base;
  float yarn_factor;
  bool use_mmap;
  bool embeddings;
  const void *user_data;
} peer_params;
typedef struct {
  peer_pair at;
  peer_mixed mixed;
  bool flag;
} peer_nested;
typedef struct {
  int32_t n_tokens;
  const int32_t *token;
} peer_batch;

static char params_text[256];
static const int32_t static_tokens[] = {5, 6, 7};

peer_pair peer_pair_make(int32_t x, int32_t y) { return (peer_pair){x, y}; }
peer_pair peer_pair_swap(peer_pair p) { return (peer_pair){p.y, p.x}; }
int64_t peer_pair_sum(peer_pair p) { return (int64_t)p.x + p.y; }
/* The address of peer_pair_swap, for a call through a C function pointer. */
const void *peer_pair_swap_address(void) {
  peer_pair (*fn)(peer_pair) = peer_pair_swap;
  const void *p;
  memcpy(&p, &fn, sizeof p);
  return p;
}
peer_mixed peer_mixed_scale(peer_mixed m, double k) { return (peer_mixed){m.n * 2, m.x * k}; }
peer_quad peer_quad_add(peer_quad p, peer_quad q) { return (peer_quad){p.a + q.a, p.b + q.b, p.c + q.c, p.d + q.d}; }
double peer_quad_sum(peer_quad q) { return (double)q.a + q.b + q.c + q.d; }
peer_params peer_params_default(void) {
  return (peer_params){512, 4, -1, 10000.5, 0.25f, true, false, static_tokens};
}
/* Every field of the params as text, so the test sees what C got. */
const char *peer_params_text(peer_params p) {
  snprintf(params_text, sizeof params_text, "n_ctx=%d threads=%d seed=%lld rope=%.2f yarn=%.3f mmap=%d emb=%d data=%s",
           p.n_ctx, p.n_threads, (long long)p.seed, p.rope_freq_base, (double)p.yarn_factor, p.use_mmap, p.embeddings,
           p.user_data == static_tokens ? "static" : p.user_data ? "other" : "null");
  return params_text;
}
peer_nested peer_nested_make(int32_t k) { return (peer_nested){{k, k + 1}, {k + 2, k * 0.5}, true}; }
peer_nested peer_nested_bump(peer_nested v) {
  return (peer_nested){{v.at.x + 1, v.at.y + 1}, {v.mixed.n + 1, v.mixed.x * 2}, !v.flag};
}
peer_batch peer_batch_get_one(const int32_t *tokens, int32_t n) { return (peer_batch){n, tokens}; }
int64_t peer_batch_sum(peer_batch b) {
  int64_t sum = 0;
  for (int32_t k = 0; k < b.n_tokens; k++) sum += b.token[k];
  return sum;
}
/* A compute call that holds the batch's tokens until peer_set_flag has run, then sums them: a buffer freed meanwhile
   would give another sum. */
int64_t peer_batch_hold(peer_batch b, int32_t limit_ms) {
  atomic_fetch_add(&res_holding, 1);
  peer_wait_flag(limit_ms);
  return peer_batch_sum(b);
}

/* The narrow, unsigned and long integers (C.Int8 to C.Long). Each echo gives back its argument, so a boundary value
   crosses both ways. Each cut takes an int64_t and returns its low bits as the narrow type: at -O1 the compiler
   returns the whole register, so the bits above the type are the argument's, which the caller must not read. */
int8_t peer_i8(int8_t x) { return x; }
int16_t peer_i16(int16_t x) { return x; }
uint8_t peer_u8(uint8_t x) { return x; }
uint16_t peer_u16(uint16_t x) { return x; }
uint32_t peer_u32(uint32_t x) { return x; }
long peer_long(long x) { return x; }
int8_t peer_cut_i8(int64_t x) { return (int8_t)x; }
int16_t peer_cut_i16(int64_t x) { return (int16_t)x; }
uint8_t peer_cut_u8(int64_t x) { return (uint8_t)x; }
uint16_t peer_cut_u16(int64_t x) { return (uint16_t)x; }
uint32_t peer_cut_u32(int64_t x) { return (uint32_t)x; }
/* The platform's long: its bits (32 on Windows, 64 elsewhere) and its limits. */
int32_t peer_long_bits(void) { return (int32_t)(sizeof(long) * 8); }
long peer_long_max(void) { return LONG_MAX; }
long peer_long_min(void) { return LONG_MIN; }

/* Each integer type through an out pointer, at the end of its range. */
void peer_out_ints(int8_t *a, int16_t *b, uint8_t *c, uint16_t *d, uint32_t *e, long *f) {
  *a = INT8_MIN;
  *b = INT16_MIN;
  *c = UINT8_MAX;
  *d = UINT16_MAX;
  *e = UINT32_MAX;
  *f = LONG_MIN;
}

/* A struct with a field of each integer type, laid out by the C rules: the long field sits at offset 16 on Linux and
   macOS (8 bytes, aligned to 8) and at 12 on Windows (4 bytes), so the pointer after it moves too. */
typedef struct {
  int8_t a;
  uint16_t b;
  int16_t c;
  uint8_t d;
  uint32_t e;
  long f;
  const void *p;
} peer_ints;

static char ints_text[256];

peer_ints peer_ints_max(void) {
  return (peer_ints){INT8_MAX, UINT16_MAX, INT16_MAX, UINT8_MAX, UINT32_MAX, LONG_MAX, ints_text};
}
/* Every field as C sees it, so the test checks the layout that the VM wrote. */
const char *peer_ints_text(peer_ints s) {
  snprintf(ints_text, sizeof ints_text, "a=%d b=%u c=%d d=%u e=%lu f=%ld p=%s", s.a, (unsigned)s.b, s.c, (unsigned)s.d,
           (unsigned long)s.e, s.f, s.p == ints_text ? "text" : s.p ? "other" : "null");
  return ints_text;
}

/* For Native.size_of, get_struct and put_struct: an array of structs with a long between an int32 and a double, so
   the layout differs by system: count at 4 and 16 bytes on Windows (LLP64), at 8 and 24 bytes on Linux and macOS. */
typedef struct {
  int32_t id;
  long count;
  double score;
} peer_row;

static char rows_text[256];

int64_t peer_row_size(void) { return (int64_t)sizeof(peer_row); }
/* Row k gets id k, count LONG_MAX - k and score k + 0.5. */
void peer_rows_fill(peer_row *rows, int32_t n) {
  for (int32_t k = 0; k < n; k++) rows[k] = (peer_row){k, LONG_MAX - k, k + 0.5};
}
/* Every row as C sees it, so the test checks the layout that the VM wrote. */
const char *peer_rows_text(const peer_row *rows, int32_t n) {
  size_t used = 0;
  rows_text[0] = '\0';
  for (int32_t k = 0; k < n && used < sizeof rows_text; k++) {
    int wrote = snprintf(rows_text + used, sizeof rows_text - used, "%s%d:%ld:%.2f", k ? " " : "", rows[k].id,
                         rows[k].count, rows[k].score);
    if (wrote < 0) break;
    used += (size_t)wrote;
  }
  return rows_text;
}

/* For callbacks (Native.callback): C calls the program back with every by-value type of a callback signature, reads
   each narrow result as its own type, takes a pointer that may be NULL, calls twice in a row, and calls from a thread
   of its own, where the VM runs nothing and the callback gives zero. */
typedef double (*peer_mix_fn)(int8_t, uint8_t, int16_t, uint16_t, uint32_t, int64_t, long, double, float, bool,
                              const char *, void *);
typedef int32_t (*peer_int_fn)(int32_t);

double peer_call_mix(peer_mix_fn fn, int32_t n) {
  double total = 0;
  for (int32_t i = 0; i < n; i++)
    total += fn((int8_t)-i, (uint8_t)(250 + i), (int16_t)-30000, (uint16_t)65000, UINT32_MAX - (uint32_t)i,
                (int64_t)1 << 40, -7L, 0.5 * i, 0.25f, i % 2 == 1, i % 2 ? "odd" : NULL, (void *)(intptr_t)(i + 1));
  return total;
}

/* -5 + 65535 + 1000000 (true) + 10 (2.5 * 4) + 4294967295 when each result keeps its type. */
int64_t peer_call_narrow(int8_t (*s)(void), uint16_t (*u)(void), bool (*b)(void), float (*f)(void),
                         uint32_t (*w)(void)) {
  return (int64_t)s() + (int64_t)u() + (b() ? 1000000 : 0) + (int64_t)(f() * 4) + (int64_t)w();
}

int32_t peer_call_maybe(peer_int_fn fn, int32_t x) { return fn ? fn(x) : -1; }

/* The second call shows what C got after the first: zero once that one failed. */
int32_t peer_call_twice(peer_int_fn fn, int32_t x) { return fn(x) * 1000 + fn(x + 1); }

typedef struct {
  peer_int_fn fn;
  int32_t x, got;
} peer_thread_call;

#ifdef _WIN32
static DWORD WINAPI thread_call(LPVOID arg) {
  peer_thread_call *c = arg;
  c->got = c->fn(c->x);
  return 0;
}

int32_t peer_call_on_thread(peer_int_fn fn, int32_t x) {
  peer_thread_call c = {fn, x, -1};
  HANDLE thread = CreateThread(NULL, 0, thread_call, &c, 0, NULL);
  if (!thread) return -2;
  WaitForSingleObject(thread, INFINITE);
  CloseHandle(thread);
  return c.got;
}
#else
static void *thread_call(void *arg) {
  peer_thread_call *c = arg;
  c->got = c->fn(c->x);
  return NULL;
}

int32_t peer_call_on_thread(peer_int_fn fn, int32_t x) {
  peer_thread_call c = {fn, x, -1};
  pthread_t thread;
  if (pthread_create(&thread, NULL, thread_call, &c) != 0) return -2;
  pthread_join(thread, NULL);
  return c.got;
}
#endif

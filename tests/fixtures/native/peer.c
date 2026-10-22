/* The independent peer of the native calls (tests/test_vm_native.py): a shared library that the test builds with the
   system C compiler, so each C type crosses the boundary through a real ABI. On Windows it is a DLL linked with
   ws2_32, and the "pipe" of the descriptor functions is a connected loopback TCP pair: Native.wait_* polls only
   sockets there. */
#define _GNU_SOURCE
#include <ctype.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <winsock2.h>
#include <windows.h>
#else
#include <dirent.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>
#endif

static char shout[64];
static int32_t bumps;
static atomic_int flag, returned, naps;

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

/* For compute defs, which run on a pool thread. peer_wait_flag returns 1 once peer_set_flag (a fast call from another
   task) has run, or 0 after LIMIT_MS milliseconds; each return is counted. */
int32_t peer_wait_flag(int32_t limit_ms) {
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

/* The text is in a buffer of the calling thread, which the next call on that thread overwrites. */
const char *peer_word(int32_t n) {
  static _Thread_local char word[8];
  memset(word, 'a' + n % 26, 3);
  word[3] = '\0';
  return word;
}

double peer_half(int64_t n) { return (double)n / 2.0; }

/* Sleeps MS milliseconds, then counts one nap. */
int32_t peer_nap(int32_t ms) {
  sleep_ms(ms);
  atomic_fetch_add(&naps, 1);
  return ms;
}

int32_t peer_naps(void) { return atomic_load(&naps); }

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

/* A value that is not a socket: a handle of the NUL device. */
int32_t peer_dev_null(void) {
  HANDLE h = CreateFileA("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
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

/* Opens the pipe and returns its read end, or -1. */
int32_t peer_pipe(void) { return pipe2(pipe_fds, O_NONBLOCK | O_CLOEXEC) == 0 ? pipe_fds[0] : -1; }
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

/* A descriptor that cannot be polled: /dev/null. */
int32_t peer_dev_null(void) { return open("/dev/null", O_RDONLY | O_CLOEXEC); }

/* The number of descriptors the process has open. */
int32_t peer_open_fds(void) {
  DIR *dir = opendir("/proc/self/fd");
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

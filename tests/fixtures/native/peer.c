/* The independent peer of the native calls (tests/test_vm_native.py): a shared library that the test builds with the
   system C compiler, so each C type crosses the boundary through a real ABI. */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static char shout[64];
static int32_t bumps;
static atomic_int flag, returned, naps;

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
    struct timespec nap = {0, 1000000L};
    while (!found && nanosleep(&nap, &nap) != 0) {}
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
  struct timespec nap = {ms / 1000, (long)(ms % 1000) * 1000000L};
  while (nanosleep(&nap, &nap) != 0) {}
  atomic_fetch_add(&naps, 1);
  return ms;
}

int32_t peer_naps(void) { return atomic_load(&naps); }

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

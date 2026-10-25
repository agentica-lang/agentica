/*
 * The Linux and macOS side of the standard output and error streams. vm/output.c owns the ring, the queue of writers
 * and the notices; this file decides how a descriptor is written, whether two are one target, does the writes, and
 * makes the in-memory stream of a notice. The Windows side is vm/stdio_windows.c. Core layer.
 * Design: docs/vm/10-io-scheduler.md §10.2.2.
 */
#ifndef _WIN32
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "core.h"
#include "stdio_diag.h"

#include <errno.h>

#if defined(__linux__) || defined(__APPLE__)
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __APPLE__
#include <poll.h>
#endif

#ifndef MSG_NOSIGNAL
/* SIGPIPE is ignored for the whole process (vm/launch.c), so a write to a closed socket fails with EPIPE anyway. */
#define MSG_NOSIGNAL 0
#endif

struct agc_stdio {
  agc_poller *poller;
  void (*done)(void *data, int status);
  void *data;
  uint64_t dev, ino;
  size_t low;
  bool socket;
};

struct agc_memstream {
  char *text;
  size_t len;
};

agc_stdio_flush_result agc_stdio_flush(FILE *stream) {
  uint8_t id = stream == stdout ? 1 : stream == stderr ? 2 : 0;
  agc_stdio_diag(AGC_DIAG_TRYLOCK_BEFORE, id, 0);
  int locked = ftrylockfile(stream);
  agc_stdio_diag(AGC_DIAG_TRYLOCK_AFTER, id, locked);
  if (locked != 0) return AGC_STDIO_BUSY;
  /* Keep the lock through fflush so another compute call cannot take it after the probe. */
  bool ok = true;
  while (true) {
    agc_stdio_diag(AGC_DIAG_FFLUSH_BEFORE, id, 0);
    int flushed = fflush(stream);
    int flush_errno = errno;
    agc_stdio_diag(AGC_DIAG_FFLUSH_AFTER, id, flushed ? flush_errno : 0);
    if (flushed == 0) break;
    if (flush_errno != EINTR) {
      ok = false;
      break;
    }
    clearerr(stream);
  }
  agc_stdio_diag(AGC_DIAG_UNLOCK_BEFORE, id, 0);
  funlockfile(stream);
  agc_stdio_diag(AGC_DIAG_UNLOCK_AFTER, id, 0);
  return ok ? AGC_STDIO_FLUSHED : AGC_STDIO_FLUSH_FAILED;
}

/* kqueue calls these two devices always ready and they never wait for a reader, so the pool writes them like a file. */
static bool never_waits(const struct stat *info) {
#ifdef __APPLE__
  if (!S_ISCHR(info->st_mode)) return false;
  const char *devices[] = {"/dev/null", "/dev/zero"};
  for (size_t k = 0; k < sizeof devices / sizeof devices[0]; k++) {
    struct stat device;
    if (stat(devices[k], &device) == 0 && info->st_rdev == device.st_rdev) return true;
  }
#else
  (void)info;
#endif
  return false;
}

bool agc_stdio_open(agc_vm *vm, agc_output *out, int fd) {
  struct stat info;
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || (flags & O_ACCMODE) == O_RDONLY || fstat(fd, &info) != 0) return false;
  bool disk = S_ISREG(info.st_mode) || S_ISBLK(info.st_mode) || never_waits(&info);
  bool socket = S_ISSOCK(info.st_mode);
  int use = fd;
  agc_poller *poller = NULL;
  if (!disk) {
    if (!socket && !S_ISFIFO(info.st_mode) && !S_ISCHR(info.st_mode)) return false;
    /* A socket is watched through a duplicate of the same description, whose flags the poller changes; they are put
       back so that the program that started this one does not find its descriptor non-blocking. */
    int again = socket ? fcntl(fd, F_DUPFD_CLOEXEC, 3) : agc_fd_reopen(fd, O_WRONLY);
    if (again < 0) return false;
    int err = 0;
    poller = agc_poller_open(vm, again, &err);
    if (socket) fcntl(again, F_SETFL, flags);
    if (poller) {
      use = again;
    } else {
      close(again);
      if (err != EPERM || socket) return false;
    }
  }
  agc_stdio *io = calloc(1, sizeof *io);
  if (!io) agc_out_of_memory();
  io->dev = (uint64_t)info.st_dev;
  io->ino = (uint64_t)info.st_ino;
  io->poller = poller;
  io->socket = socket && poller;
  out->fd = use;
  out->io = io;
  out->mode = poller ? AGC_WRITE_POLL : AGC_WRITE_DISK;
  return true;
}

/* The same device and inode: stdout and stderr given as one pipe, socket or file are one target. */
bool agc_stdio_same(const agc_output *first, int fd) {
  struct stat info;
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || (flags & O_ACCMODE) == O_RDONLY || fstat(fd, &info) != 0) return false;
  return first->io->dev == (uint64_t)info.st_dev && first->io->ino == (uint64_t)info.st_ino;
}

#ifdef __APPLE__
/* How much of N bytes one write may be, so that it cannot block: 0 when poll says the descriptor is not writable, -1
   with errno when poll fails. macOS keeps the description shared with the program that started this one blocking, and
   send with MSG_DONTWAIT still stalled the loop on such a socket (seen on CI). A write of at most PIPE_BUF to a pipe,
   or of SO_SNDLOWAT to a socket, cannot block once poll reports the descriptor writable. */
static ssize_t writable_chunk(agc_stdio *io, int fd, size_t n) {
  struct pollfd ask = {.fd = fd, .events = POLLOUT};
  int rc = poll(&ask, 1, 0);
  if (rc < 0) return errno == EINTR ? 0 : -1;
  if (rc == 0) return 0;
  size_t most = PIPE_BUF;
  if (io->socket) {
    if (!io->low) {
      int low = 0;
      socklen_t size = sizeof low;
      io->low = getsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &low, &size) == 0 && low > 0 ? (size_t)low : PIPE_BUF;
    }
    most = io->low;
  }
  return (ssize_t)(n < most ? n : most);
}
#endif

bool agc_stdio_try_first(const agc_output *s) { return s->mode == AGC_WRITE_POLL && s->io->socket; }

ssize_t agc_stdio_try(agc_output *s, const uint8_t *data, size_t n) {
  agc_stdio *io = s->io;
#ifdef __APPLE__
  if (io->poller) {
    ssize_t chunk = writable_chunk(io, s->fd, n);
    if (chunk <= 0) {
      if (chunk == 0) errno = EAGAIN;
      return -1;
    }
    n = (size_t)chunk;
  }
#endif
  return io->socket ? send(s->fd, data, n, MSG_DONTWAIT | MSG_NOSIGNAL) : write(s->fd, data, n);
}

ssize_t agc_stdio_write(int fd, const uint8_t *data, size_t n, agc_utf8_cut *cut) {
  (void)cut;
  return write(fd, data, n);
}

static void watch_ready(void *data, int status) {
  agc_stdio *io = data;
  agc_poller_pause(io->poller);
  io->done(io->data, status);
}

/* Calls DONE once the descriptor can be written. The ranges are not used: the loop writes what the descriptor takes. */
void agc_stdio_start(agc_output *s, const uint8_t *first, size_t first_len, const uint8_t *second, size_t second_len,
                     void (*done)(void *data, int status), void *data) {
  (void)first;
  (void)first_len;
  (void)second;
  (void)second_len;
  agc_stdio *io = s->io;
  io->done = done;
  io->data = data;
  agc_poller_wait(io->poller, true, watch_ready, io);
}

/* Unix closes a socket gently when the process exits: nothing to do. */
void agc_stdio_end(agc_output *out, agc_input *in) {
  (void)out;
  (void)in;
}

void agc_stdio_close(agc_stdio *io) {
  if (io->poller) {
    agc_poller_pause(io->poller);
    agc_poller_close(io->poller);
  }
  free(io);
}

FILE *agc_memstream_open(agc_memstream **ms) {
  agc_memstream *m = calloc(1, sizeof *m);
  if (!m) return NULL;
  FILE *file = open_memstream(&m->text, &m->len);
  if (!file) {
    free(m);
    return NULL;
  }
  *ms = m;
  return file;
}

bool agc_memstream_take(FILE *file, agc_memstream *m, char **text, size_t *len) {
  bool ok = fclose(file) == 0;
  *text = m->text;
  *len = m->len;
  free(m);
  return ok;
}
#endif
#endif

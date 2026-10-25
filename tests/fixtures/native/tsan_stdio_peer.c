/* Linux-only TSan fixture peer: it holds a FILE lock until TSan finalization signals it, then unlocks on the owner
   thread and parks without returning through the VM compute worker. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int parse_fd(const char *name, bool nonblocking) {
  const char *text = getenv(name);
  if (!text || !*text) return -1;
  errno = 0;
  char *end = NULL;
  long parsed = strtol(text, &end, 10);
  if (errno == ERANGE || !end || *end || parsed < 3 || parsed > INT_MAX) return -1;
  int fd = (int)parsed;
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0 || ((flags & O_NONBLOCK) != 0) != nonblocking) return -1;
  return fd;
}

static bool write_marker(int fd, const char *marker, size_t length) {
  size_t written = 0;
  while (written < length) {
    ssize_t count = write(fd, marker + written, length - written);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return false;
    written += (size_t)count;
  }
  return true;
}

static int open_marker(const char *path) {
  return open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
}

static _Noreturn void park_forever(int fd) {
  for (;;) {
    unsigned char byte;
    ssize_t count = read(fd, &byte, sizeof byte);
    if (count > 0 || (count < 0 && errno == EINTR)) continue;
    for (;;) pause();
  }
}

int32_t peer_hold_stdio_tsan(int32_t which, const char *lock_path, const char *release_path) {
  int release_fd = parse_fd("AGENTICA_TSAN_RELEASE_READ_FD", false);
  int gate_fd = parse_fd("AGENTICA_TSAN_PRIVATE_GATE_FD", false);
  if (release_fd < 0 || gate_fd < 0) return -1;
  /* Open VM-provided marker paths before shutdown; no borrowed C.String pointer survives the wait. */
  int lock_marker_fd = open_marker(lock_path);
  if (lock_marker_fd < 0) return -1;
  int release_marker_fd = open_marker(release_path);
  if (release_marker_fd < 0) {
    close(lock_marker_fd);
    return -1;
  }

  FILE *stream = which == 1 ? stdout : stderr;
  flockfile(stream);
  (void)fwrite("native-locked\n", 1, sizeof "native-locked\n" - 1, stream);
  if (!write_marker(lock_marker_fd, "locked", sizeof "locked" - 1)) {
    close(lock_marker_fd);
    close(release_marker_fd);
    park_forever(gate_fd);
  }
  close(lock_marker_fd);

  unsigned char release = 0;
  ssize_t count;
  do {
    count = read(release_fd, &release, sizeof release);
  } while (count < 0 && errno == EINTR);
  if (count != 1 || release != 0x52) {
    close(release_marker_fd);
    park_forever(gate_fd);
  }
  if (!write_marker(release_marker_fd, "released", sizeof "released" - 1)) {
    close(release_marker_fd);
    park_forever(gate_fd);
  }
  close(release_marker_fd);
  funlockfile(stream);
  park_forever(gate_fd);
}

int32_t peer_buffer_stdio_tsan(int32_t which) {
  FILE *stream = which == 1 ? stdout : stderr;
  return (int32_t)fwrite("native-free\n", 1, sizeof "native-free\n" - 1, stream);
}

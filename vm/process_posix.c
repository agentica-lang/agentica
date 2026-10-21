/*
 * Command search rules for POSIX systems, and the read of a child pipe beside
 * libuv. Platform adapter (process_os.h);
 * no VM state or scheduling. Every file may run, a name is only a name,
 * and PATH splits at ':'.
 */
#include "process_os.h"

#ifndef _WIN32
#include <errno.h>
#include <string.h>
#include <unistd.h>

bool agc_proc_is_path(const char *command, size_t size) { return memchr(command, '/', size) != NULL; }

bool agc_proc_name_ok(const char *command, size_t size) {
  (void)command;
  (void)size;
  return true;
}

bool agc_proc_next_dir(const char **cursor, const char **dir, size_t *size) {
  while (*cursor) {
    const char *at = *cursor;
    const char *end = strchr(at, ':');
    *cursor = end ? end + 1 : NULL;
    *dir = at;
    *size = end ? (size_t)(end - at) : strlen(at);
    if (*size) return true;
  }
  return false;
}

bool agc_proc_suffix_ok(const char *path) {
  (void)path;
  return true;
}

const char *const *agc_proc_suffixes(void) {
  static const char *const none[] = {NULL};
  return none;
}

bool agc_proc_drains(void) { return true; }

int64_t agc_proc_read_now(intptr_t fd, uint8_t *buf, size_t len) {
  for (;;) {
    ssize_t n = read((int)fd, buf, len);
    if (n >= 0) return n;
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return AGC_PROC_NOTHING;
    return -errno;
  }
}
#endif

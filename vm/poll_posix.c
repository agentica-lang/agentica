/*
 * The Linux and macOS side of the copy that a Native.wait_* poller polls (agc_poll_copy_open in core.h): a new open of
 * the file of the descriptor, else a duplicate whose flags are put back. vm/loop.c owns the poller. The Windows side is
 * vm/poll_windows.c. Core layer.
 */
#ifndef _WIN32
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "core.h"

#if defined(__linux__) || defined(__APPLE__)
#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* A terminal master (libuv's uv__tty_is_slave asks the same): opening its path again (/dev/ptmx) makes a new
   terminal. */
static bool pty_master(int fd) {
#ifdef __APPLE__
  char name[256];
  return ioctl(fd, TIOCPTYGNAME, name) == 0;
#else
  unsigned int number;
  return ioctl(fd, TIOCGPTN, &number) == 0;
#endif
}

/* A new open of the file of FD with its access mode (agc_fd_reopen), so FD keeps its flags; a duplicate, which shares
   them, when that cannot be done (a socket, a terminal master, an eventfd). SHARED says the copy is such a duplicate
   (agc_fd_reopen's duplicate of a macOS pipe is polled by poll(2), which leaves the flags alone). */
int agc_poll_copy_open(int fd, agc_poll_copy *copy) {
  copy->flags = fcntl(fd, F_GETFL);
  if (copy->flags < 0) return -errno;
  int again = pty_master(fd) ? -1 : agc_fd_reopen(fd, copy->flags & O_ACCMODE);
  copy->shared = again < 0;
  copy->fd = again >= 0 ? again : fcntl(fd, F_DUPFD_CLOEXEC, 3);
  return copy->fd < 0 ? -errno : 0;
}

/* uv_poll_init made the shared description non-blocking; the poll needs only readiness, so the native code gets its
   flags back (as vm/input.c does for stdin). */
void agc_poll_copied(const agc_poll_copy *copy) {
  if (copy->shared) (void)fcntl(copy->fd, F_SETFL, copy->flags);
}

void agc_poll_close(int fd) { close(fd); }

bool agc_poll_one_wait(void) { return false; }
#endif
#endif

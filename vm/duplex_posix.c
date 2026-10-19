/*
 * The child channel on POSIX systems. Platform adapter (duplex_os.h); no VM
 * state or scheduling. One socket pair: the child has it on descriptor 3 and
 * the parent can shut down its writing side with shutdown(2).
 */
#include "duplex_os.h"

#ifndef _WIN32
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <uv.h>

#define CHANNEL_FD 3

int agc_chan_pair(agc_chan_ends *ends) {
  int link[2];
  int rc = uv_socketpair(SOCK_STREAM, 0, link, 0, 0);
  if (rc) return rc;
  ends->read = ends->write = link[0];
  ends->child[0] = link[1];
  ends->child[1] = -1;
  ends->child_count = 1;
  return 0;
}

const char *agc_chan_marker(void) { return "3"; }

/* A socket or FIFO open for both reading and writing: an anonymous pipe end never is, and a regular file or a
   character device is not a channel. */
bool agc_chan_take(void (*before_close)(int fd, void *data), void *data, int *read, int *write) {
  struct stat info;
  if (fstat(CHANNEL_FD, &info) != 0 || !(S_ISFIFO(info.st_mode) || S_ISSOCK(info.st_mode))) return false;
  int mode = fcntl(CHANNEL_FD, F_GETFL);
  if (mode < 0 || (mode & O_ACCMODE) != O_RDWR) return false;
  int fd = fcntl(CHANNEL_FD, F_DUPFD_CLOEXEC, CHANNEL_FD);
  if (fd < 0) return false;
  before_close(CHANNEL_FD, data);
  close(CHANNEL_FD);
  *read = *write = fd;
  return true;
}
#endif

/*
 * How a child finds its channel on POSIX systems. Platform adapter
 * (duplex_os.h); no VM state or scheduling. The VM gives the two pipes of
 * agc_chan_pair (vm/duplex.c); a parent that is no VM may still give the one
 * socket of earlier versions.
 */
#include "duplex_os.h"

#ifndef _WIN32
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define READ_FD 3
#define WRITE_FD 4

/* A FIFO (a pipe) or a socket open for `access` (O_RDONLY, O_WRONLY or O_RDWR), or open both ways: a regular file or
   a character device is never a channel. */
static bool channel_end(int fd, int access) {
  struct stat info;
  if (fstat(fd, &info) != 0 || !(S_ISFIFO(info.st_mode) || S_ISSOCK(info.st_mode))) return false;
  int mode = fcntl(fd, F_GETFL);
  if (mode < 0) return false;
  mode &= O_ACCMODE;
  return mode == access || mode == O_RDWR;
}

/* "3,4": descriptor 3 to read and 4 to write (the pipes above, or the sockets of a parent that is no VM, such as
   node's 'pipe' slots). "3": the one socket of earlier versions, or a FIFO, open both ways on descriptor 3, which a
   parent that is no VM may still pass; it is duplicated, one descriptor per direction. In the split form the moved
   descriptors land above 4, since 3 and 4 are still open when they are made. */
bool agc_chan_take(const char *marker, void (*before_close)(int fd, void *data), void *data, int *read, int *write) {
  bool split = strcmp(marker, "3,4") == 0;
  if (split ? !channel_end(READ_FD, O_RDONLY) || !channel_end(WRITE_FD, O_WRONLY)
            : strcmp(marker, "3") != 0 || !channel_end(READ_FD, O_RDWR))
    return false;
  int in = fcntl(READ_FD, F_DUPFD_CLOEXEC, READ_FD);
  if (in < 0) return false;
  int out = fcntl(split ? WRITE_FD : in, F_DUPFD_CLOEXEC, READ_FD);
  if (out < 0) {
    close(in);
    return false;
  }
  before_close(READ_FD, data);
  close(READ_FD);
  if (split) {
    before_close(WRITE_FD, data);
    close(WRITE_FD);
  }
  *read = in;
  *write = out;
  return true;
}
#endif

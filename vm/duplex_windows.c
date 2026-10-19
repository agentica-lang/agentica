/*
 * The child channel on Windows. Platform adapter (duplex_os.h); no VM state
 * or scheduling. A byte pipe has no shutdown for one direction, so the channel
 * is two pipes: descriptor 3 carries the parent's lines to the child and 4 the
 * child's to the parent. Closing the parent's write end is the end of input.
 */
#include "duplex_os.h"

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <uv.h>
#include <windows.h>
#include <winternl.h>

#define READ_FD 3
#define WRITE_FD 4

/* The child ends are blocking, like those of stdin and stdout, so a child that is no VM can read and write them
   with plain calls; the parent's ends are the non-blocking ones that libuv drives. */
int agc_chan_pair(agc_chan_ends *ends) {
  int into[2], outof[2];
  int rc = uv_pipe(into, 0, UV_NONBLOCK_PIPE);
  if (rc) return rc;
  rc = uv_pipe(outof, UV_NONBLOCK_PIPE, 0);
  if (rc) {
    _close(into[0]);
    _close(into[1]);
    return rc;
  }
  ends->read = outof[0];
  ends->write = into[1];
  ends->child[0] = into[0];
  ends->child[1] = outof[1];
  ends->child_count = 2;
  return 0;
}

const char *agc_chan_value(void) { return "3,4"; }

/* True when the descriptor is a named pipe whose handle grants `right` (FILE_READ_DATA or FILE_WRITE_DATA). */
static bool pipe_with(int fd, ULONG right) {
  if (uv_guess_handle(fd) != UV_NAMED_PIPE) return false;
  HANDLE handle = (HANDLE)_get_osfhandle(fd);
  if (handle == INVALID_HANDLE_VALUE) return false;
  IO_STATUS_BLOCK block;
  ULONG granted = 0; /* the one field of FILE_ACCESS_INFORMATION: an ACCESS_MASK */
  return NtQueryInformationFile(handle, &block, &granted, sizeof granted, FileAccessInformation) >= 0 &&
         (granted & right);
}

/* A duplicate above the standard streams (a closed stdin leaves 0 free, and _dup takes the lowest) that no spawn
   passes on: handle lists already keep it from a grandchild, and this makes it explicit. */
static int moved(int fd) {
  int low[3], held = 0, taken;
  while ((taken = _dup(fd)) >= 0 && taken <= 2) low[held++] = taken;
  for (int k = 0; k < held; k++) _close(low[k]);
  if (taken < 0) return -1;
  if (!SetHandleInformation((HANDLE)_get_osfhandle(taken), HANDLE_FLAG_INHERIT, 0)) {
    _close(taken);
    return -1;
  }
  _setmode(taken, _O_BINARY);
  return taken;
}

bool agc_chan_take(void (*before_close)(int fd, void *data), void *data, int *read, int *write) {
  if (!pipe_with(READ_FD, FILE_READ_DATA) || !pipe_with(WRITE_FD, FILE_WRITE_DATA)) return false;
  int in = moved(READ_FD);
  if (in < 0) return false;
  int out = moved(WRITE_FD);
  if (out < 0) {
    _close(in);
    return false;
  }
  before_close(READ_FD, data);
  before_close(WRITE_FD, data);
  _close(READ_FD);
  _close(WRITE_FD);
  *read = in;
  *write = out;
  return true;
}
#endif

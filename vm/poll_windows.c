/*
 * The Windows side of the copy that a Native.wait_* poller polls (agc_poll_copy_open in core.h): the descriptor is a
 * Winsock SOCKET of the native code, and the copy a duplicate socket. vm/loop.c owns the poller. The Linux and macOS
 * side is vm/poll_posix.c. Core layer.
 */
#ifdef _WIN32
#include "core.h"

#include <limits.h>
#include <stdint.h>
#include <uv.h>
#include <windows.h>

/* The duplicate (WSADuplicateSocketW) shares FD's non-blocking mode, and any value that is not a socket fails there
   (ENOTSOCK). A copy above INT_MAX cannot be a poller's descriptor (EMFILE). */
int agc_poll_copy_open(int fd, agc_poll_copy *copy) {
  copy->flags = 0;
  copy->shared = true;
  WSAPROTOCOL_INFOW info;
  SOCKET dup = INVALID_SOCKET;
  if (WSADuplicateSocketW((SOCKET)(uintptr_t)(unsigned)fd, GetCurrentProcessId(), &info) == 0)
    dup = WSASocketW(FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, &info, 0,
                     WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
  if (dup == INVALID_SOCKET) return uv_translate_sys_error(WSAGetLastError());
  if (dup > (SOCKET)INT_MAX) {
    closesocket(dup);
    return UV_EMFILE;
  }
  copy->fd = (int)dup;
  return 0;
}

/* Winsock cannot read a socket's mode back, so the one that uv_poll set stays. */
void agc_poll_copied(const agc_poll_copy *copy) { (void)copy; }

void agc_poll_close(int fd) { closesocket((SOCKET)(uintptr_t)(unsigned)fd); }

bool agc_poll_one_wait(void) { return true; }
#endif

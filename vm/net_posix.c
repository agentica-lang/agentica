/*
 * Socket and pipe error numbers on POSIX systems: libuv's codes are the
 * negated errno values, so the number is the code negated; and the direct
 * send with send(2). Adapter for net_os.h.
 */
#include "net_os.h"

#ifndef _WIN32
#include <errno.h>
#include <sys/socket.h>
#include <sys/types.h>

/* One send(2) moves at most this much, as agc_stream_write's chunk. */
#define SEND_CHUNK ((size_t)1 << 30)

/* SIGPIPE is ignored for the whole run (launch.c), so a send to a closed peer fails with EPIPE where MSG_NOSIGNAL is
   missing (macOS). */
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

int agc_net_errno(int uv_error) { return -uv_error; }

int64_t agc_net_send(uintptr_t sock, const uint8_t *data, size_t len) {
  size_t sent = 0;
  while (sent < len) {
    size_t step = len - sent < SEND_CHUNK ? len - sent : SEND_CHUNK;
    ssize_t n = send((int)sock, data + sent, step, MSG_NOSIGNAL);
    if (n >= 0) {
      sent += (size_t)n;
      continue;
    }
    if (errno == EINTR) continue;
    if (sent) break;
    /* libuv's codes are the negated errno values here; EWOULDBLOCK is EAGAIN on Linux and macOS. */
    return errno == EWOULDBLOCK ? -EAGAIN : -errno;
  }
  return (int64_t)sent;
}
#endif

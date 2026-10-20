/*
 * Socket and pipe error numbers on Windows: libuv translates WSA and Win32
 * errors to its own codes (UV__E* in uv/errno.h), which no CRT function
 * names, so each code src/win/error.c can return maps to the errno of the
 * UCRT when it has one (POSIX supplement values such as ECONNREFUSED 107),
 * whose strerror has a text for it. Adapter for net_os.h.
 */
#include "net_os.h"

#ifdef _WIN32
#include <errno.h>
#include <uv.h>

int agc_net_errno(int uv_error) {
  switch (uv_error) {
    case UV_E2BIG: return E2BIG;
    case UV_EACCES: return EACCES;
    case UV_EADDRINUSE: return EADDRINUSE;
    case UV_EADDRNOTAVAIL: return EADDRNOTAVAIL;
    case UV_EAFNOSUPPORT: return EAFNOSUPPORT;
    case UV_EAGAIN: return EAGAIN;
    case UV_EALREADY: return EALREADY;
    case UV_EBADF: return EBADF;
    case UV_EBUSY: return EBUSY;
    case UV_ECANCELED: return ECANCELED;
    case UV_ECHARSET: return EILSEQ;
    case UV_ECONNABORTED: return ECONNABORTED;
    case UV_ECONNREFUSED: return ECONNREFUSED;
    case UV_ECONNRESET: return ECONNRESET;
    case UV_EEXIST: return EEXIST;
    case UV_EFAULT: return EFAULT;
    case UV_EHOSTUNREACH: return EHOSTUNREACH;
    case UV_EINTR: return EINTR;
    case UV_EINVAL: return EINVAL;
    case UV_EIO: return EIO;
    case UV_EISCONN: return EISCONN;
    case UV_EISDIR: return EISDIR;
    case UV_ELOOP: return ELOOP;
    case UV_EMFILE: return EMFILE;
    case UV_EMSGSIZE: return EMSGSIZE;
    case UV_ENAMETOOLONG: return ENAMETOOLONG;
    case UV_ENETDOWN: return ENETDOWN;
    case UV_ENETUNREACH: return ENETUNREACH;
    case UV_ENOBUFS: return ENOBUFS;
    case UV_ENOENT: return ENOENT;
    case UV_ENOMEM: return ENOMEM;
    case UV_ENOSPC: return ENOSPC;
    case UV_ENOTCONN: return ENOTCONN;
    case UV_ENOTEMPTY: return ENOTEMPTY;
    case UV_ENOTSOCK: return ENOTSOCK;
    case UV_ENOTSUP: return ENOTSUP;
    case UV_EPERM: return EPERM;
    case UV_EPIPE: return EPIPE;
    case UV_EPROTO: return EPROTO;
    case UV_EPROTONOSUPPORT: return EPROTONOSUPPORT;
    case UV_EROFS: return EROFS;
    case UV_ETIMEDOUT: return ETIMEDOUT;
    case UV_EXDEV: return EXDEV;
    /* UV_UNKNOWN, and the codes the UCRT has no errno for (UV_EFTYPE, UV_ESOCKTNOSUPPORT), keep a generic I/O
       error. */
    default: return EIO;
  }
}
/* TLS sockets stay off here: the TLS and HTTPS socket tests do not pass on Windows yet (step 11, part 2). */
bool agc_net_tls_enabled(void) { return false; }
#endif

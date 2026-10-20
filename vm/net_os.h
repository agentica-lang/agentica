/*
 * The error number a socket, pipe or spawn failure shows. libuv reports one
 * code set on every system; agc_system_error prints a C errno and its
 * strerror text. POSIX: libuv's code is the negated errno. Windows: libuv's
 * codes are its own, so each is mapped to the CRT's errno, whose strerror
 * names it. Also whether TLS sockets are on. Port interface: plain ints and
 * bools. Implemented by net_posix.c and net_windows.c.
 */
#ifndef AGC_NET_OS_H
#define AGC_NET_OS_H

#include <stdbool.h>

/* The positive C errno for a negative libuv error code. */
int agc_net_errno(int uv_error);

/* Whether TLS.connect, TLS.listen and HTTPS may open TLS sockets. The TLS adapter and the trust store build on every
 * system; Windows says no until its socket tests pass there (step 11, part 2). */
bool agc_net_tls_enabled(void);

#endif

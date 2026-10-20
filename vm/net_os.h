/*
 * The error number a socket, pipe or spawn failure shows. libuv reports one
 * code set on every system; agc_system_error prints a C errno and its
 * strerror text. POSIX: libuv's code is the negated errno. Windows: libuv's
 * codes are its own, so each is mapped to the CRT's errno, whose strerror
 * names it. Port interface: plain ints. Implemented by net_posix.c and
 * net_windows.c.
 */
#ifndef AGC_NET_OS_H
#define AGC_NET_OS_H

/* The positive C errno for a negative libuv error code. */
int agc_net_errno(int uv_error);

#endif

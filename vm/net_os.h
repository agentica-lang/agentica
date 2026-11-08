/*
 * The error number a socket, pipe or spawn failure shows, and the direct
 * send of a scheduler. libuv reports one code set on every system;
 * agc_system_error prints a C errno and its strerror text. POSIX: libuv's code
 * is the negated errno. Windows: libuv's codes are its own, so each is mapped
 * to the CRT's errno, whose strerror names it. Port interface: plain ints and
 * the socket as an integer. Implemented by net_posix.c and net_windows.c.
 */
#ifndef AGC_NET_OS_H
#define AGC_NET_OS_H

#include <stddef.h>
#include <stdint.h>

/* The positive C errno for a negative libuv error code. */
int agc_net_errno(int uv_error);

/* Sends from DATA on the non-blocking socket SOCK (an fd, or a Windows SOCKET) until the kernel takes no more: the
   count it took, or a negative libuv error code when the first send failed (UV_EAGAIN: the send buffer is full). A
   failure after some bytes returns their count; the next send meets it again. It calls no libuv function, so any
   thread may call it (vm/tcp.c, direct_send). */
int64_t agc_net_send(uintptr_t sock, const uint8_t *data, size_t len);

#endif

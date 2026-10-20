/*
 * Socket and pipe error numbers on POSIX systems: libuv's codes are the
 * negated errno values, so the number is the code negated.
 * Adapter for net_os.h.
 */
#include "net_os.h"

#ifndef _WIN32
int agc_net_errno(int uv_error) { return -uv_error; }

bool agc_net_tls_enabled(void) { return true; }
#endif

/*
 * The name the operating system gives itself, for System.os. POSIX: the
 * sysname of uname(2), read through libuv. Windows: "Windows_NT", fixed,
 * because libuv's Windows uv_os_uname also reads the registry and clears
 * every field when that fails. Implemented by system_posix.c and
 * system_windows.c.
 */
#ifndef AGC_SYSTEM_OS_H
#define AGC_SYSTEM_OS_H

#include <stdbool.h>
#include <stddef.h>

/* Copies the name into `out` (`size` bytes) and returns true, or returns false when the system does not say or the
   name does not fit. */
bool agc_system_sysname(char *out, size_t size);

#endif

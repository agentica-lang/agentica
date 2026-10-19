/*
 * The POSIX side of System.os: the sysname that uname(2) gives, through libuv.
 * It fails when uv_os_uname fails or the name does not fit the buffer.
 * Adapter for system_os.h.
 */
#ifndef _WIN32
#include "system_os.h"

#include <string.h>
#include <uv.h>

bool agc_system_sysname(char *out, size_t size) {
  uv_utsname_t info;
  if (uv_os_uname(&info) != 0 || strlen(info.sysname) >= size) return false;
  strcpy(out, info.sysname);
  return true;
}
#endif

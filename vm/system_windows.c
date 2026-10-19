/*
 * The Windows side of System.os: always "Windows_NT", the name libuv gives
 * a native build. No system call is made, so only a small buffer fails.
 * Adapter for system_os.h.
 */
#ifdef _WIN32
#include "system_os.h"

#include <string.h>

bool agc_system_sysname(char *out, size_t size) {
  const char *name = "Windows_NT";
  if (strlen(name) >= size) return false;
  strcpy(out, name);
  return true;
}
#endif

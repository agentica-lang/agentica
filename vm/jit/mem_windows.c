/*
 * The JIT's code memory on Windows (docs/future/22-jit.md §22, "Memory"): pages committed read-write with
 * VirtualAlloc, then sealed execute-read with VirtualProtect and FlushInstructionCache, so no page is ever writable
 * and executable at once. The Linux and macOS side is mem_posix.c. Core layer.
 */
#ifdef _WIN32
#include "jit.h"

#include <windows.h>

void *agc_jit_mem_map(size_t size) { return VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE); }

bool agc_jit_mem_seal(void *pages, size_t size) {
  DWORD old;
  if (!VirtualProtect(pages, size, PAGE_EXECUTE_READ, &old)) return false;
  return FlushInstructionCache(GetCurrentProcess(), pages, size) != 0;
}

void agc_jit_mem_unmap(void *pages, size_t size) {
  (void)size;
  VirtualFree(pages, 0, MEM_RELEASE);
}
#endif

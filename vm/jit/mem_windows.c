/*
 * The JIT's code memory on Windows (docs/vm/05-values-execution-builtins.md §6.4, "Code memory"): pages reserved with
 * VirtualAlloc, committed read-write when opened, then sealed execute-read with VirtualProtect and
 * FlushInstructionCache, so no page is ever writable and executable at once. The Linux and macOS side is mem_posix.c.
 * Core layer.
 */
#ifdef _WIN32
#include "jit.h"

#include <windows.h>

size_t agc_jit_mem_page(void) {
  SYSTEM_INFO info;
  GetSystemInfo(&info);
  return info.dwPageSize;
}

void *agc_jit_mem_reserve(size_t size) { return VirtualAlloc(NULL, size, MEM_RESERVE, PAGE_NOACCESS); }

bool agc_jit_mem_open(void *pages, size_t size) {
  return VirtualAlloc(pages, size, MEM_COMMIT, PAGE_READWRITE) != NULL;
}

bool agc_jit_mem_seal(void *pages, size_t size) {
  DWORD old;
  if (!VirtualProtect(pages, size, PAGE_EXECUTE_READ, &old)) return false;
  return FlushInstructionCache(GetCurrentProcess(), pages, size) != 0;
}

/* Windows has an emitter on x86-64 only, which fetches coherently. */
bool agc_jit_mem_sync_register(void) { return false; }

bool agc_jit_mem_sync_cores(void) { return false; }

void agc_jit_mem_unmap(void *pages, size_t size) {
  (void)size;
  VirtualFree(pages, 0, MEM_RELEASE);
}
#endif

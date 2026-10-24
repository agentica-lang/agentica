/*
 * The JIT's code memory on Linux and Intel macOS (docs/future/22-jit.md §22, "Memory"): anonymous pages mapped
 * read-write, then sealed read-execute with mprotect, so no page is ever writable and executable at once. Apple
 * arm64 instead reserves slices of one MAP_JIT arena (mem_apple.c). The Windows side is mem_windows.c. Core layer.
 */
#ifndef _WIN32
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#else
#define _DEFAULT_SOURCE
#endif
#include "jit.h"

#include <sys/mman.h>

/* mem_apple.c replaces these three on Apple arm64 (one MAP_JIT arena with a per-thread write lease). */
#if !defined(__APPLE__) || !defined(__aarch64__)
void *agc_jit_mem_map(size_t size) {
  void *pages = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  return pages == MAP_FAILED ? NULL : pages;
}

bool agc_jit_mem_seal(void *pages, size_t size) {
  if (mprotect(pages, size, PROT_READ | PROT_EXEC) != 0) return false;
  /* A no-op on x86-64, where the caches stay coherent; arm64 needs it before the first run. */
  __builtin___clear_cache((char *)pages, (char *)pages + size);
  return true;
}

void agc_jit_mem_unmap(void *pages, size_t size) { munmap(pages, size); }
#endif
#endif

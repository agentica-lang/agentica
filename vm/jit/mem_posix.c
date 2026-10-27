/*
 * The JIT's code memory on Linux and macOS (docs/vm/05-values-execution-builtins.md §6.4, "Code memory"): anonymous
 * pages reserved without access, opened read-write, then sealed read-execute with mprotect, so no page is ever writable
 * and executable at once. The Windows side is mem_windows.c. Core layer.
 */
#ifndef _WIN32
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#else
#define _DEFAULT_SOURCE
#endif
#include "jit.h"

#include <sys/mman.h>
#include <unistd.h>

size_t agc_jit_mem_page(void) {
  long page = sysconf(_SC_PAGESIZE);
  return page > 0 ? (size_t)page : 4096;
}

/* macOS on arm64 refuses executable pages without MAP_JIT; its emitter will map them so and switch them per thread
   with pthread_jit_write_protect_np in place of the mprotect below. No emitter runs there yet. Without access, the
   reservation takes address space only. */
void *agc_jit_mem_reserve(size_t size) {
  void *pages = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
  return pages == MAP_FAILED ? NULL : pages;
}

bool agc_jit_mem_open(void *pages, size_t size) { return mprotect(pages, size, PROT_READ | PROT_WRITE) == 0; }

bool agc_jit_mem_seal(void *pages, size_t size) {
  if (mprotect(pages, size, PROT_READ | PROT_EXEC) != 0) return false;
  /* A no-op on x86-64, where the caches stay coherent; arm64 needs it before the first run. */
  __builtin___clear_cache((char *)pages, (char *)pages + size);
  return true;
}

void agc_jit_mem_unmap(void *pages, size_t size) { munmap(pages, size); }
#endif

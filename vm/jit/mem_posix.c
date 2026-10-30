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

#if defined(__aarch64__) && defined(__linux__)
#include <stdint.h>
/* The cache maintenance that libgcc and compiler-rt call __clear_cache, defined here on Linux arm64, where the seal
   above and libffi's closure setup call it. The release links with zig cc against glibc 2.28, and zig's compiler_rt,
   the only other definition, is one object that also brings zig's stack protector, whose canary is a constant: with
   this definition the binary keeps glibc's __stack_chk_fail and its random canary (tools/release-check.sh checks).
   The sequence is the architecture's: clean each data cache line to the point of unification, then invalidate each
   instruction cache line, leaving out a step that CTR_EL0 says the hardware does itself (IDC, bit 28; DIC, bit 29). */
void __clear_cache(void *begin, void *end);
void __clear_cache(void *begin, void *end) {
  uint64_t ctr;
  __asm__ __volatile__("mrs %0, ctr_el0" : "=r"(ctr));
  uintptr_t start = (uintptr_t)begin, stop = (uintptr_t)end;
  if (!(ctr & (UINT64_C(1) << 28))) {
    uintptr_t line = (uintptr_t)4 << ((ctr >> 16) & 15);
    for (uintptr_t at = start & ~(line - 1); at < stop; at += line)
      __asm__ __volatile__("dc cvau, %0" : : "r"(at) : "memory");
  }
  __asm__ __volatile__("dsb ish" : : : "memory");
  if (!(ctr & (UINT64_C(1) << 29))) {
    uintptr_t line = (uintptr_t)4 << (ctr & 15);
    for (uintptr_t at = start & ~(line - 1); at < stop; at += line)
      __asm__ __volatile__("ic ivau, %0" : : "r"(at) : "memory");
    __asm__ __volatile__("dsb ish" : : : "memory");
  }
  __asm__ __volatile__("isb" : : : "memory");
}
#endif
#endif

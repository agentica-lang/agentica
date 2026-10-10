#include "agc.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef AGC_NO_GC
const char *__asan_default_options(void);
const char *__asan_default_options(void) { return "detect_leaks=0"; }
#else
#include <gc.h>
#endif

static const char oom_line[] = "agentica-vm: out of memory\n";

void agc_out_of_memory(void) {
  ssize_t ignored = write(2, oom_line, sizeof oom_line - 1);
  (void)ignored;
  _exit(70);
}

#ifndef AGC_NO_GC
static void *on_gc_oom(size_t size) {
  (void)size;
  agc_out_of_memory();
  return NULL;
}

static void on_gc_abort(const char *message) {
  (void)message;
  agc_out_of_memory();
}
#endif

void agc_init(void) {
#ifndef AGC_NO_GC
  static bool ready = false;
  if (ready) return;
  ready = true;
  GC_INIT();
  GC_set_oom_fn(on_gc_oom);
  GC_set_abort_func(on_gc_abort);
#endif
}

unsigned agc_gc_version(void) {
#ifdef AGC_NO_GC
  return 0;
#else
  return GC_get_version();
#endif
}

void *agc_alloc(size_t size) {
#ifdef AGC_NO_GC
  void *p = calloc(1, size ? size : 1);
#else
  void *p = GC_MALLOC(size ? size : 1);
#endif
  if (!p) agc_out_of_memory();
  return p;
}

void *agc_alloc_atomic(size_t size) {
#ifdef AGC_NO_GC
  void *p = calloc(1, size ? size : 1);
#else
  void *p = GC_MALLOC_ATOMIC(size ? size : 1);
#endif
  if (!p) agc_out_of_memory();
  return p;
}

size_t agc_size_add(size_t a, size_t b) {
  size_t r;
  if (__builtin_add_overflow(a, b, &r)) agc_out_of_memory();
  return r;
}

size_t agc_size_mul(size_t a, size_t b) {
  size_t r;
  if (__builtin_mul_overflow(a, b, &r)) agc_out_of_memory();
  return r;
}

agc_value agc_void(void) {
  agc_value v;
  memset(&v, 0, sizeof v);
  v.tag = AGC_T_VOID;
  return v;
}

agc_value agc_bool(bool b) {
  agc_value v;
  v.tag = AGC_T_BOOL;
  v.as.i = b;
  return v;
}

agc_value agc_int(int64_t i) {
  agc_value v;
  v.tag = AGC_T_INT;
  v.as.i = i;
  return v;
}

agc_value agc_string_value(agc_string *s) {
  agc_value v;
  v.tag = AGC_T_STRING;
  v.as.p = s;
  return v;
}

bool agc_is(agc_value v, agc_tag tag) { return v.tag == (uint32_t)tag; }

static _Noreturn void wrong_tag(agc_vm *vm, uint32_t span) {
  (void)span;
  agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: wrong value type", 0);
}

bool agc_as_bool(agc_vm *vm, agc_value v, uint32_t span) {
  if (v.tag != AGC_T_BOOL) wrong_tag(vm, span);
  return v.as.i != 0;
}

int64_t agc_as_int(agc_vm *vm, agc_value v, uint32_t span) {
  if (v.tag != AGC_T_INT) wrong_tag(vm, span);
  return v.as.i;
}

agc_string *agc_as_string(agc_vm *vm, agc_value v, uint32_t span) {
  if (v.tag != AGC_T_STRING) wrong_tag(vm, span);
  return v.as.p;
}

bool agc_utf8_chars(const uint8_t *s, size_t len, size_t *chars) {
  size_t count = 0, i = 0;
  while (i < len) {
    uint8_t c = s[i];
    size_t n;
    uint32_t cp;
    if (c < 0x80) {
      i++;
      count++;
      continue;
    } else if (c >= 0xC2 && c <= 0xDF) {
      n = 1;
      cp = c & 0x1F;
    } else if (c >= 0xE0 && c <= 0xEF) {
      n = 2;
      cp = c & 0x0F;
    } else if (c >= 0xF0 && c <= 0xF4) {
      n = 3;
      cp = c & 0x07;
    } else {
      return false;
    }
    if (len - i - 1 < n) return false;
    for (size_t k = 1; k <= n; k++) {
      uint8_t d = s[i + k];
      if ((d & 0xC0) != 0x80) return false;
      cp = (cp << 6) | (d & 0x3F);
    }
    if ((n == 2 && cp < 0x800) || (n == 3 && cp < 0x10000) || cp > 0x10FFFF ||
        (cp >= 0xD800 && cp <= 0xDFFF))
      return false;
    i += n + 1;
    count++;
  }
  *chars = count;
  return true;
}

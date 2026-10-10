#include "agc.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef AGC_NO_GC
const char *__asan_default_options(void);
const char *__asan_default_options(void) { return "detect_leaks=0:allocator_may_return_null=1"; }
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

#ifdef AGC_GC_STRESS
static void stress(void) {
  static unsigned count;
  if (++count % 64 == 0) GC_gcollect();
}
#else
static void stress(void) {}
#endif

void *agc_alloc(size_t size) {
  stress();
#ifdef AGC_NO_GC
  void *p = calloc(1, size ? size : 1);
#else
  void *p = GC_MALLOC(size ? size : 1);
#endif
  if (!p) agc_out_of_memory();
  return p;
}

void *agc_alloc_atomic(size_t size) {
  stress();
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

agc_value agc_nil(void) {
  agc_value v;
  v.tag = AGC_T_NIL;
  v.as.i = 0;
  return v;
}

agc_value agc_float(double f) {
  agc_value v;
  v.tag = AGC_T_FLOAT;
  v.as.f = f;
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

agc_string *agc_new_string(size_t bytes, size_t chars) {
  agc_string *s = agc_alloc_atomic(agc_size_add(sizeof(agc_string), bytes));
  s->bytes = bytes;
  s->chars = chars;
  return s;
}

agc_string *agc_make_string(const char *data, size_t bytes, size_t chars) {
  agc_string *s = agc_new_string(bytes, chars);
  if (bytes) memcpy(s->data, data, bytes);
  return s;
}

bool agc_is(agc_value v, agc_tag tag) { return v.tag == (uint32_t)tag; }

static _Noreturn void wrong_tag(agc_vm *vm) {
  agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: wrong value type", 0);
}

bool agc_as_bool(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_BOOL) wrong_tag(vm);
  return v.as.i != 0;
}

int64_t agc_as_int(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_INT) wrong_tag(vm);
  return v.as.i;
}

double agc_as_float(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_FLOAT) wrong_tag(vm);
  return v.as.f;
}

agc_string *agc_as_string(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_STRING) wrong_tag(vm);
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

static size_t put(char *out, size_t at, const char *text, size_t len) {
  memcpy(out + at, text, len);
  return at + len;
}

size_t agc_float_text(double x, char out[AGC_FLOAT_TEXT]) {
  if (isnan(x)) return put(out, 0, "+nan.0", 6);
  if (isinf(x)) return put(out, 0, x > 0 ? "+inf.0" : "-inf.0", 6);
  size_t at = 0;
  if (signbit(x)) {
    out[at++] = '-';
    x = -x;
  }
  if (x == 0) return put(out, at, "0.0", 3);
  char exact[800];
  int written = snprintf(exact, sizeof exact, "%.767e", x);
  char *mark = written > 0 && (size_t)written < sizeof exact ? strchr(exact, 'e') : NULL;
  char all[768];
  size_t total = 0;
  for (const char *c = exact; mark && c < mark; c++)
    if (*c >= '0' && *c <= '9' && total < sizeof all) all[total++] = *c;
  if (total != sizeof all) abort();
  int e = atoi(mark + 1);
  char digits[20];
  size_t n = 0;
  int digits_e = e;
  bool found = false;
  for (size_t precision = isnormal(x) ? 15 : 1; precision <= 17 && !found; precision++) {
    bool nearest_up = all[precision] >= '5';
    for (int attempt = 0; attempt < 2 && !found; attempt++) {
      memcpy(digits, all, precision);
      n = precision;
      digits_e = e;
      if (nearest_up != (attempt == 1)) {
        size_t k = n;
        while (k > 0 && digits[k - 1] == '9') digits[--k] = '0';
        if (k == 0) {
          digits[0] = '1';
          digits_e++;
        } else {
          digits[k - 1]++;
        }
      }
      char text[AGC_FLOAT_TEXT];
      snprintf(text, sizeof text, "%c.%.*se%d", digits[0], (int)n - 1, digits + 1, digits_e);
      found = strtod(text, NULL) == x;
    }
  }
  while (n > 1 && digits[n - 1] == '0') n--;
  e = digits_e;
  int exponent_digits = snprintf(NULL, 0, "%d", e < 0 ? -e : e);
  int positional = (int)n > e + 1 ? (int)n + 1 : e + 3;
  int scientific = (int)n + (n > 1) + 2 + exponent_digits;
  if (e < -4 || (e >= 0 && positional > 16 && positional > scientific)) {
    out[at++] = digits[0];
    if (n > 1) {
      out[at++] = '.';
      at = put(out, at, digits + 1, n - 1);
    }
    return at + (size_t)snprintf(out + at, AGC_FLOAT_TEXT - at, "e%c%d", e < 0 ? '-' : '+', e < 0 ? -e : e);
  }
  if (e < 0) {
    at = put(out, at, "0.", 2);
    for (int k = -1; k > e; k--) out[at++] = '0';
    return put(out, at, digits, n);
  }
  size_t whole = (size_t)e + 1;
  if (n > whole) {
    at = put(out, at, digits, whole);
    out[at++] = '.';
    return put(out, at, digits + whole, n - whole);
  }
  at = put(out, at, digits, n);
  for (size_t k = n; k < whole; k++) out[at++] = '0';
  return put(out, at, ".0", 2);
}

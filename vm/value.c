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
  _Exit(70);
}

#ifndef AGC_NO_GC
static void *on_gc_oom(size_t size) {
  (void)size;
  agc_out_of_memory();
  return NULL;
}

static const char gc_error_line[] = "agentica-vm: internal GC error\n";

static void on_gc_abort(const char *message) {
  (void)message;
  ssize_t ignored = write(2, gc_error_line, sizeof gc_error_line - 1);
  (void)ignored;
  _Exit(70);
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
  GC_set_warn_proc(GC_ignore_warn_proc);
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

agc_value agc_list_value(agc_list *l) {
  agc_value v;
  v.tag = AGC_T_LIST;
  v.as.p = l;
  return v;
}

agc_value agc_map_value(agc_map *m) {
  agc_value v;
  v.tag = AGC_T_MAP;
  v.as.p = m;
  return v;
}

agc_value agc_struct_value(agc_struct *s) {
  agc_value v;
  v.tag = AGC_T_STRUCT;
  v.as.p = s;
  return v;
}

agc_value agc_enum_value(agc_enum *e) {
  agc_value v;
  v.tag = AGC_T_ENUM;
  v.as.p = e;
  return v;
}

agc_value agc_result_value(bool ok, agc_value value) {
  agc_result *r = agc_alloc(sizeof(agc_result));
  r->ok = ok;
  r->value = value;
  agc_value v;
  v.tag = AGC_T_RESULT;
  v.as.p = r;
  return v;
}

agc_struct *agc_new_struct(uint32_t type, uint32_t n) {
  agc_struct *s = agc_alloc(agc_size_add(sizeof(agc_struct), agc_size_mul(n, sizeof(agc_value))));
  s->type = type;
  s->n = n;
  return s;
}

agc_enum *agc_new_enum(uint32_t variant, uint32_t n) {
  agc_enum *e = agc_alloc(agc_size_add(sizeof(agc_enum), agc_size_mul(n, sizeof(agc_value))));
  e->variant = variant;
  e->n = n;
  return e;
}

agc_list *agc_new_list(size_t len) {
  agc_list *l = agc_alloc(agc_size_add(sizeof(agc_list), agc_size_mul(len, sizeof(agc_value))));
  l->len = len;
  return l;
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

agc_list *agc_as_list(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_LIST) wrong_tag(vm);
  return v.as.p;
}

agc_map *agc_as_map(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_MAP) wrong_tag(vm);
  return v.as.p;
}

agc_struct *agc_as_struct(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_STRUCT) wrong_tag(vm);
  return v.as.p;
}

agc_enum *agc_as_enum(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_ENUM) wrong_tag(vm);
  return v.as.p;
}

agc_result *agc_as_result(agc_vm *vm, agc_value v) {
  if (v.tag != AGC_T_RESULT) wrong_tag(vm);
  return v.as.p;
}

size_t agc_utf8_width(uint8_t lead) { return lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4; }

size_t agc_utf8_valid(const uint8_t *s, size_t len) {
  if (len == 0) return 0;
  uint8_t c = s[0];
  size_t n;
  uint32_t cp;
  if (c < 0x80) {
    return 1;
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
    return 0;
  }
  if (len - 1 < n) return 0;
  for (size_t k = 1; k <= n; k++) {
    uint8_t d = s[k];
    if ((d & 0xC0) != 0x80) return 0;
    cp = (cp << 6) | (d & 0x3F);
  }
  if ((n == 2 && cp < 0x800) || (n == 3 && cp < 0x10000) || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
    return 0;
  return n + 1;
}

bool agc_utf8_chars(const uint8_t *s, size_t len, size_t *chars) {
  size_t count = 0, i = 0;
  while (i < len) {
    size_t n = agc_utf8_valid(s + i, len - i);
    if (n == 0) return false;
    i += n;
    count++;
  }
  *chars = count;
  return true;
}

static bool incomplete_tail(const uint8_t *s, size_t len) {
  uint8_t c = s[0];
  size_t width = c >= 0xC2 && c <= 0xDF ? 2 : c >= 0xE0 && c <= 0xEF ? 3 : c >= 0xF0 && c <= 0xF4 ? 4 : 0;
  if (width == 0 || len >= width) return false;
  for (size_t k = 1; k < len; k++)
    if ((s[k] & 0xC0) != 0x80) return false;
  if (len > 1 && ((c == 0xE0 && s[1] < 0xA0) || (c == 0xF0 && s[1] < 0x90))) return false;
  return true;
}

static size_t utf8_step(const uint8_t *s, size_t len, bool tail, size_t *valid) {
  size_t n = agc_utf8_valid(s, len);
  *valid = n;
  if (n) return n;
  return tail && incomplete_tail(s, len) ? len : 1;
}

agc_string *agc_utf8_decode(const uint8_t *data, size_t len, const char *replacement, bool tail) {
  size_t rlen = strlen(replacement), bytes = 0, chars = 0, n;
  for (size_t i = 0; i < len; chars++) {
    i += utf8_step(data + i, len - i, tail, &n);
    bytes = agc_size_add(bytes, n ? n : rlen);
  }
  agc_string *s = agc_new_string(bytes, chars);
  size_t at = 0;
  for (size_t i = 0; i < len;) {
    size_t step = utf8_step(data + i, len - i, tail, &n);
    if (n) {
      memcpy(s->data + at, data + i, n);
      at += n;
    } else {
      memcpy(s->data + at, replacement, rlen);
      at += rlen;
    }
    i += step;
  }
  return s;
}

static size_t put(char *out, size_t at, const char *text, size_t len) {
  memcpy(out + at, text, len);
  return at + len;
}

static int decimal_digits(double x, int precision, char *all) {
  char text[800];
  int written = snprintf(text, sizeof text, "%.*e", precision, x);
  char *mark = written > 0 && (size_t)written < sizeof text ? strchr(text, 'e') : NULL;
  int total = 0;
  for (const char *c = text; mark && c < mark; c++)
    if (*c >= '0' && *c <= '9' && total <= precision) all[total++] = *c;
  if (!mark || total != precision + 1) abort();
  return atoi(mark + 1);
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
  char all[768];
  int e = decimal_digits(x, 40, all);
  double scaled = ldexp(x, 34);
  bool carried = !(x < 1e40 && scaled == floor(scaled));
  for (int k = 18; k <= 40 && carried; k++)
    if (all[k] != '0') carried = false;
  if (carried) e = decimal_digits(x, 767, all);
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

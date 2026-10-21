/*
 * Native calls: Native.call, the builtin that every extern function of a
 * program lowers to (docs/grammar/06d-io-and-network.md, "Native code"), and
 * agc_ffi_refusal, the check at load. It reads the signature string, keeps
 * one prepared call per signature, converts Agentica values to C and back,
 * and leaves dlopen and libffi to the adapter (ffi_os.h). Service layer.
 */
#include "ffi_os.h"
#include "services.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The turn cost of one call, besides the size of its arguments and result: a fast call runs on the scheduler and
   cannot be stopped in the middle, so it is charged as a long builtin. */
#define FFI_CALL_COST 64
/* The most signatures one run prepares. A program has one per extern function; only hand-made bytecode can build
   more, so the cap bounds the table without limiting a real program. */
#define FFI_MAX_CALLS 65536

typedef struct {
  char *key;
  size_t key_len;
  uint64_t hash;
  agc_ffi_call *call;
  agc_c_type params[AGC_FFI_MAX_PARAMS];
  agc_c_type result;
  uint32_t count;
} ffi_entry;

/* The prepared calls of the run, by signature string, in malloc memory (no GC pointers): open addressing over a
   power-of-two table, kept at most half full. Native.call is a shared builtin, so in a shared VM it runs with
   rt->sync held and the table needs no lock of its own. Entries live until the process ends, like the libraries. */
typedef struct agc_ffi_cache {
  ffi_entry **slots;
  size_t size, used;
} agc_ffi_cache;

static uint64_t text_hash(const char *data, size_t len) {
  uint64_t h = 1469598103934665603ULL;
  for (size_t k = 0; k < len; k++) h = (h ^ (uint8_t)data[k]) * 1099511628211ULL;
  return h;
}

static bool c_type_of(char code, bool result, agc_c_type *out) {
  switch (code) {
    case 'i': *out = AGC_C_INT; return true;
    case 'l': *out = AGC_C_INT64; return true;
    case 'd': *out = AGC_C_DOUBLE; return true;
    case 'b': *out = AGC_C_BOOL; return true;
    case 's': *out = AGC_C_STRING; return true;
    case 'v': *out = AGC_C_VOID; return result;
    default: return false;
  }
}

static _Noreturn void bad_signature(agc_vm *vm, uint32_t span) {
  agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: bad native signature", span);
}

/* "CODES SYMBOL LIBRARY": the result code, then one code per parameter, a space, the C name, a space, and the library
   (which may hold spaces). The front end writes it (compiler/lower/lower_native.agc); the bytecode may hold anything,
   so every part is checked here. */
static ffi_entry *parse_signature(agc_vm *vm, const agc_string *text, uint32_t span) {
  const char *data = text->data;
  size_t len = text->bytes;
  const char *first = memchr(data, ' ', len);
  if (!first) bad_signature(vm, span);
  size_t codes = (size_t)(first - data);
  const char *symbol = first + 1;
  const char *second = memchr(symbol, ' ', len - codes - 1);
  if (!second || second == symbol || codes == 0 || codes - 1 > AGC_FFI_MAX_PARAMS) bad_signature(vm, span);
  ffi_entry *e = calloc(1, sizeof(ffi_entry));
  if (!e) agc_out_of_memory();
  if (!c_type_of(data[0], true, &e->result)) {
    free(e);
    bad_signature(vm, span);
  }
  e->count = (uint32_t)(codes - 1);
  for (uint32_t k = 0; k < e->count; k++) {
    if (!c_type_of(data[k + 1], false, &e->params[k])) {
      free(e);
      bad_signature(vm, span);
    }
  }
  size_t symbol_len = (size_t)(second - symbol);
  const char *library = second + 1;
  size_t library_len = len - (size_t)(library - data);
  char *symbol_text = malloc(symbol_len + 1), *library_text = malloc(library_len + 1);
  if (!symbol_text || !library_text) agc_out_of_memory();
  memcpy(symbol_text, symbol, symbol_len);
  symbol_text[symbol_len] = '\0';
  memcpy(library_text, library, library_len);
  library_text[library_len] = '\0';
  char error[512];
  /* A NUL inside the name would cut it short for the system loader: such a name opens nothing. */
  bool clean = !memchr(symbol, 0, symbol_len) && !memchr(library, 0, library_len) && library_len > 0;
  e->call = clean ? agc_ffi_prepare(library_text, symbol_text, e->result, e->params, e->count, error, sizeof error)
                  : NULL;
  if (!clean) snprintf(error, sizeof error, "a library or function name is empty or holds a NUL character");
  free(symbol_text);
  free(library_text);
  if (!e->call) {
    free(e);
    size_t n = strlen(error);
    agc_fail_text(vm, "RUNTIME-NATIVE-LOAD", agc_utf8_decode((const uint8_t *)error, n, "\xEF\xBF\xBD", false), span);
  }
  return e;
}

static void cache_grow(agc_ffi_cache *c) {
  size_t size = c->size ? c->size * 2 : 64;
  ffi_entry **slots = calloc(size, sizeof(ffi_entry *));
  if (!slots) agc_out_of_memory();
  for (size_t k = 0; k < c->size; k++) {
    ffi_entry *e = c->slots[k];
    if (!e) continue;
    size_t at = e->hash & (size - 1);
    while (slots[at]) at = (at + 1) & (size - 1);
    slots[at] = e;
  }
  free(c->slots);
  c->slots = slots;
  c->size = size;
}

static ffi_entry *find_call(agc_vm *vm, const agc_string *text, uint32_t span) {
  agc_runtime *rt = vm->rt;
  if (!rt->ffi) {
    rt->ffi = calloc(1, sizeof(agc_ffi_cache));
    if (!rt->ffi) agc_out_of_memory();
    cache_grow(rt->ffi);
  }
  agc_ffi_cache *c = rt->ffi;
  uint64_t hash = text_hash(text->data, text->bytes);
  size_t at = hash & (c->size - 1);
  for (ffi_entry *e = c->slots[at]; e; e = c->slots[at]) {
    if (e->hash == hash && e->key_len == text->bytes && memcmp(e->key, text->data, text->bytes) == 0) return e;
    at = (at + 1) & (c->size - 1);
  }
  if (c->used >= FFI_MAX_CALLS) agc_fail(vm, "RUNTIME-NATIVE-LOAD", "too many native signatures in one run", span);
  ffi_entry *e = parse_signature(vm, text, span);
  e->key = malloc(text->bytes ? text->bytes : 1);
  if (!e->key) agc_out_of_memory();
  memcpy(e->key, text->data, text->bytes);
  e->key_len = text->bytes;
  e->hash = hash;
  if ((c->used + 1) * 2 > c->size) cache_grow(c);
  at = hash & (c->size - 1);
  while (c->slots[at]) at = (at + 1) & (c->size - 1);
  c->slots[at] = e;
  c->used++;
  return e;
}

/* Checks argument V against its C type before anything is allocated, so a failure (agc_fail longjmps) leaks
   nothing. A C.Int that does not fit in 32 bits and a C.String with a NUL inside fail: C cannot take them, and
   cutting them short would call the function with another value. */
static void check_argument(agc_vm *vm, agc_c_type type, agc_value v, uint32_t span) {
  switch (type) {
    case AGC_C_INT: {
      int64_t n = agc_as_int(vm, v);
      if (n < INT32_MIN || n > INT32_MAX)
        agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "a C.Int argument does not fit in 32 bits", span);
      break;
    }
    case AGC_C_INT64: agc_as_int(vm, v); break;
    case AGC_C_DOUBLE: agc_as_float(vm, v); break;
    case AGC_C_BOOL: agc_as_bool(vm, v); break;
    case AGC_C_STRING: {
      const agc_string *s = agc_as_string(vm, v);
      if (s->bytes && memchr(s->data, 0, s->bytes))
        agc_fail(vm, "RUNTIME-INVALID-CHARACTER", "a C.String argument holds a NUL character", span);
      break;
    }
    case AGC_C_VOID: agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: a Void parameter", span);
  }
}

/* The C value of a checked argument. A C.String is a malloc'd copy, which the caller frees after the call. */
static agc_c_value c_argument(agc_vm *vm, agc_c_type type, agc_value v) {
  agc_c_value out = {0};
  switch (type) {
    case AGC_C_INT: out.i = (int32_t)agc_as_int(vm, v); break;
    case AGC_C_INT64: out.l = agc_as_int(vm, v); break;
    case AGC_C_DOUBLE: out.d = agc_as_float(vm, v); break;
    case AGC_C_BOOL: out.b = agc_as_bool(vm, v); break;
    case AGC_C_STRING: out.s = agc_cstr(agc_as_string(vm, v)); break;
    case AGC_C_VOID: break;
  }
  return out;
}

static agc_value result_value(agc_c_type type, const agc_c_value *r) {
  switch (type) {
    case AGC_C_INT: return agc_int(r->i);
    case AGC_C_INT64: return agc_int(r->l);
    case AGC_C_DOUBLE: return agc_float(r->d);
    case AGC_C_BOOL: return agc_bool(r->b);
    case AGC_C_STRING: {
      /* The function keeps the text it returns (Agentica copies it and frees nothing); NULL reads as "". Bytes that
         are not UTF-8 become U+FFFD, as in every String the VM builds from outside text. */
      const char *s = r->s ? r->s : "";
      return agc_string_value(agc_utf8_decode((const uint8_t *)s, strlen(s), "\xEF\xBF\xBD", false));
    }
    case AGC_C_VOID: break;
  }
  return agc_void();
}

/* Native.call(signature, arguments): one call of an extern function, on the scheduler. The arguments are a List with
   one value per parameter, of the Agentica type the checker gave it. Every argument is checked before the first
   C.String copy is made, and nothing between the copies and their free can fail. */
static agc_value builtin_native_call(agc_vm *vm, agc_value *args, uint32_t span) {
  /* The fuzzer runs hand-made bytecode with no_files: it must open no library. */
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
  ffi_entry *e = find_call(vm, agc_as_string(vm, args[0]), span);
  const agc_list *values = agc_as_list(vm, args[1]);
  if (agc_list_len(values) != e->count)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: wrong number of native arguments", span);
  for (uint32_t k = 0; k < e->count; k++) check_argument(vm, e->params[k], agc_list_get(values, k), span);
  agc_c_value in[AGC_FFI_MAX_PARAMS];
  for (uint32_t k = 0; k < e->count; k++) in[k] = c_argument(vm, e->params[k], agc_list_get(values, k));
  agc_c_value out = {0};
  agc_ffi_invoke(e->call, in, &out);
  for (uint32_t k = 0; k < e->count; k++)
    if (e->params[k] == AGC_C_STRING) free((char *)in[k].s);
  agc_charge(vm, FFI_CALL_COST);
  return result_value(e->result, &out);
}

const char *agc_ffi_refusal(const agc_program *program, bool deny, const char **message, uint32_t *span) {
  if (program->native_call == UINT32_MAX) return NULL;
  *span = program->native_function == UINT32_MAX ? 0 : program->functions[program->native_function].span;
  if (!agc_ffi_supported()) {
    *message = "this program declares extern functions, and native calls are not supported on this system yet";
    return "RUNTIME-NATIVE-UNSUPPORTED";
  }
  if (deny) {
    *message = "this program declares extern functions, and --deny-native refuses native code";
    return "RUNTIME-NATIVE-DENIED";
  }
  return NULL;
}

const agc_builtin agc_ffi_builtins[] = {
  {AGC_NATIVE_CALL, 2, builtin_native_call, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
};

const size_t agc_ffi_builtin_count = sizeof agc_ffi_builtins / sizeof agc_ffi_builtins[0];

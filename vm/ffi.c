/*
 * Native calls (docs/grammar/06d-io-and-network.md, "Native code"): Native.call, which every extern function lowers
 * to, and agc_ffi_refusal, the check at load. It reads the signature string, keeps one prepared call per signature,
 * converts values to C and back, runs a fast call on the scheduler and a compute call on the compute pool
 * (agc_io_compute), and leaves dlopen and libffi to the adapter (ffi_os.h). Also the resources that extern functions
 * return (agc_c_resource) with Native.close, Native.null and Native.null?, Native.pointer, the owned buffers of
 * Native.memory_pointer (and its block form) and Native.free, the reads and writes of memory (Native.get_string,
 * get_bytes, get_*, put_*, the array forms), and Native.wait_readable and wait_writable, the waits on a descriptor.
 * Service layer.
 */
#include "ffi_os.h"
#include "net_os.h"
#include "services.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The turn cost of one call, besides the size of its arguments and result: a fast call runs on the scheduler and
   cannot be stopped in the middle, so it is charged as a long builtin. */
#define FFI_CALL_COST 64
/* The word in front of the signature of a compute def (compiler/lower/lower_native.agc). */
#define COMPUTE_PREFIX "compute "
#define COMPUTE_PREFIX_LEN (sizeof COMPUTE_PREFIX - 1)
/* The most signatures one run prepares. A program has one per extern function; only hand-made bytecode can build
   more, so the cap bounds the table without limiting a real program. */
#define FFI_MAX_CALLS 65536
/* The largest owned buffer, 256 TiB: more than the user address space of every target with native calls (48-bit
   virtual addresses on x86_64 and arm64), so no allocator could serve it. A larger size is refused before calloc is
   asked, so the answer does not depend on the allocator: a sanitizer's allocator ends the process on such a request
   where libc returns NULL. */
#define BUFFER_MAX (UINT64_C(1) << 48)
/* The name an owned buffer inspects as: it is a C.Pointer to the program. */
#define BUFFER_NAME "C.Pointer"

/* A resource kind that a call makes: the prepared call of its free function (void free(void *)) and its name. */
typedef struct {
  agc_ffi_call *free;
  char *name;
} made_kind;

/* A prepared signature. An out parameter (out[k]) is not an argument of Native.call: C gets a pointer to a zeroed slot
   of type params[k] and writes its value there. For the others, arg[k] is the index of the argument in the List of
   Native.call (`inputs` of them). For a function that returns a resource, `free` is the prepared call of the
   resource's free function, `resource` the resource's name and `symbol` the C name of the function, which the error of
   a NULL result names; all three are NULL otherwise. `made` holds the kind of each out resource (NULL when the call has
   none). A function with out parameters (`outs` > 0) gives a List: the C result, unless Void, then each out value. */
typedef struct {
  char *key;
  size_t key_len;
  uint64_t hash;
  agc_ffi_call *call;
  agc_c_type params[AGC_FFI_MAX_PARAMS];
  bool out[AGC_FFI_MAX_PARAMS];
  uint8_t arg[AGC_FFI_MAX_PARAMS];
  agc_c_type result;
  uint32_t count, inputs, outs;
  bool compute;
  agc_ffi_call *free;
  char *resource, *symbol;
  made_kind *made;
} ffi_entry;

/* One compute call, in malloc memory: the C arguments copied on the scheduler (each C.String and C.Bytes a malloc'd
   copy), the resource of each resource argument and the owned buffer of each C.Pointer one (NULL for the others),
   which the call holds (`jobs`) until its end on a scheduler, and the result, which the pool thread stores with a
   malloc'd copy of a C.String result, made right after the call, before a later call can reuse the text the function
   returned. The entry is never freed, so the pool thread may read it. `slots` and `held` point into the same block,
   after `in`; the registry keeps each held resource alive. The slot of an out parameter is zeroed on the scheduler,
   written by C on the pool thread, and read only by `done` after `ran`. `ran` is set by the pool thread once the call
   is made: the work of a job cancelled while it waited is skipped (run_compute in vm/loop.c), and then `out` and the
   slots hold no result. */
typedef struct {
  const ffi_entry *entry;
  agc_c_value *slots;
  agc_c_resource **held;
  bool ran;
  agc_c_value out;
  agc_c_value in[];
} compute_call;

/* The free functions of a signature, in the library: the result's (index 0 when the result is a resource), then each
   out resource's, as named by the signature. */
typedef struct {
  const char *names[AGC_FFI_MAX_PARAMS + 1];
  size_t lens[AGC_FFI_MAX_PARAMS + 1];
  const char *kinds[AGC_FFI_MAX_PARAMS + 1];
  size_t kind_lens[AGC_FFI_MAX_PARAMS + 1];
  agc_ffi_call *calls[AGC_FFI_MAX_PARAMS + 1];
  uint32_t count;
} free_list;

/* How the copy of a C.Bytes argument went (copy_bytes). */
typedef enum { BYTES_OK, BYTES_RANGE, BYTES_TAG } bytes_outcome;

/* One Native.wait_readable or wait_writable, in malloc memory. The task's descriptor FD is never polled itself: the
   poller polls a new open of its file, or a duplicate (agc_poller_open_copy), which it owns and closes once its wait is
   over. So the native code keeps its descriptor whatever happens to the wait, a descriptor the loop already watches can
   still be waited on, and two tasks can wait on one descriptor (not on one Windows socket: EBUSY). The copy is made on
   the I/O thread when the job starts, so a descriptor closed before then fails the wait (EBADF). `more`, `ready`,
   `cancel`, `pause` and `drop` run on the I/O thread; `done` and `expired` on the scheduler that resumes the task,
   after the job's outcome has published what the I/O thread wrote. */
typedef struct {
  agc_vm *vm;
  agc_io_job *job;
  agc_poller *poller;
  /* The descriptor of the native code. */
  int fd;
  /* The errno of a poller that could not be made, else 0: a regular file cannot be polled (EPERM on Linux, EINVAL on
     macOS). */
  int err;
  bool writing;
} native_wait;

/* The kinds of item that the typed reads and writes move: Native.get_int8 to get_pointer, put_int8 to put_pointer, the
   array forms, get_bytes and put_bytes (ITEM_BYTE, written only from 0 to 255). ITEM_WIDTHS has the size of each. */
typedef enum {
  ITEM_INT8, ITEM_INT16, ITEM_INT32, ITEM_INT64, ITEM_UINT8, ITEM_UINT16, ITEM_UINT32, ITEM_FLOAT32, ITEM_FLOAT64,
  ITEM_POINTER, ITEM_BYTE
} item_kind;

/* What a memory builtin reads or writes: COUNT items of SIZE bytes at OFFSET bytes past its pointer. A bad offset
   fails at OFFSET_SPAN, and a bad count, or memory that runs past an owned buffer, at COUNT_SPAN. */
typedef struct {
  int64_t offset, count;
  size_t size;
  uint32_t offset_span, count_span;
} memory_ask;

/* The block form of Native.memory_pointer: the buffer it yields, and whether the block has been called. */
typedef struct {
  agc_stepper stepper;
  agc_value buffer;
  bool called;
} buffer_block;

/* The prepared calls of the run, by signature string, in malloc memory (no GC pointers): open addressing over a
   power-of-two table, kept at most half full. Native.call is a shared builtin, so in a shared VM it runs with
   rt->sync held and the table needs no lock of its own. Entries live until the process ends, like the libraries. */
typedef struct agc_ffi_cache {
  ffi_entry **slots;
  size_t size, used;
} agc_ffi_cache;

static const size_t ITEM_WIDTHS[] = {1, 2, 4, 8, 1, 2, 4, sizeof(float), sizeof(double), sizeof(void *), 1};

static uint64_t text_hash(const char *data, size_t len) {
  uint64_t h = 1469598103934665603ULL;
  for (size_t k = 0; k < len; k++) h = (h ^ (uint8_t)data[k]) * 1099511628211ULL;
  return h;
}

/* The C type of a code of the signature; a capital is an out parameter of that type (*OUT set), for the types that
   can be one. */
static bool c_type_of(char code, bool result, agc_c_type *type, bool *out) {
  *out = false;
  if (!result && code != '\0' && strchr("ILDFBPR", code)) {
    *out = true;
    code = (char)(code - 'A' + 'a');
  }
  switch (code) {
    case 'i': *type = AGC_C_INT; return true;
    case 'l': *type = AGC_C_INT64; return true;
    case 'd': *type = AGC_C_DOUBLE; return true;
    case 'f': *type = AGC_C_FLOAT; return true;
    case 'b': *type = AGC_C_BOOL; return true;
    case 's': *type = AGC_C_STRING; return true;
    case 'p': *type = AGC_C_POINTER; return true;
    case 'r': *type = AGC_C_RESOURCE; return true;
    case 'y': *type = AGC_C_BYTES; return !result;
    case 'v': *type = AGC_C_VOID; return result;
    default: return false;
  }
}

/* A malloc'd NUL-terminated copy of LEN bytes. */
static char *text_copy(const char *data, size_t len) {
  char *out = malloc(len + 1);
  if (!out) agc_out_of_memory();
  memcpy(out, data, len);
  out[len] = '\0';
  return out;
}

/* The next word of [*at, *at + *left) up to a space, which is skipped; false when no space is left or the word is
   empty. */
static bool next_word(const char **at, size_t *left, const char **word, size_t *len) {
  const char *space = memchr(*at, ' ', *left);
  if (!space || space == *at) return false;
  *word = *at;
  *len = (size_t)(space - *at);
  *left -= *len + 1;
  *at = space + 1;
  return true;
}

/* An ASCII identifier: the resource name is shown by IO.inspect, so it must be valid UTF-8 that no cut can split. */
static bool identifier(const char *text, size_t len) {
  for (size_t k = 0; k < len; k++) {
    char c = text[k];
    bool letter = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
    if (!letter && (k == 0 || c < '0' || c > '9')) return false;
  }
  return len > 0;
}

static _Noreturn void bad_signature(agc_vm *vm, uint32_t span) {
  agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: bad native signature", span);
}

static _Noreturn void load_failed(agc_vm *vm, const char *error, uint32_t span) {
  agc_string *text = agc_utf8_decode((const uint8_t *)error, strlen(error), "\xEF\xBF\xBD", false);
  agc_fail_text(vm, "RUNTIME-NATIVE-LOAD", text, span);
}

static void discard_frees(free_list *frees) {
  for (uint32_t k = 0; k < frees->count; k++)
    if (frees->calls[k]) agc_ffi_discard(frees->calls[k]);
}

/* "CODES SYMBOL LIBRARY": the result code, then one code per parameter (a capital for an out parameter), a space, the
   C name, a space, and the library (which may hold spaces), with "compute " in front for a compute def. A variadic
   function has a "." among the codes where its variadic part starts, after one parameter at least; the codes after it
   are never an out parameter, a C.Bool or a C.Float, which C would promote. Each resource the call makes adds two words
   after the C name, the C name of its free function and the resource's name, an identifier: the result's first (code
   r), then each out resource's (code R), in order. The front end writes it (compiler/lower/lower_native.agc); the
   bytecode may hold anything, so every part is checked here. */
static ffi_entry *parse_signature(agc_vm *vm, const agc_string *text, uint32_t span) {
  const char *at = text->data;
  size_t left = text->bytes;
  bool compute = left >= COMPUTE_PREFIX_LEN && memcmp(at, COMPUTE_PREFIX, COMPUTE_PREFIX_LEN) == 0;
  if (compute) {
    at += COMPUTE_PREFIX_LEN;
    left -= COMPUTE_PREFIX_LEN;
  }
  const char *codes, *symbol;
  size_t codes_len, symbol_len;
  if (!next_word(&at, &left, &codes, &codes_len) || !next_word(&at, &left, &symbol, &symbol_len))
    bad_signature(vm, span);
  /* The "." comes out of the codes; a second one is then an unknown code. */
  const char *mark = memchr(codes, '.', codes_len);
  uint32_t fixed = AGC_FFI_NOT_VARIADIC;
  char kinds[AGC_FFI_MAX_PARAMS + 1];
  size_t kinds_len = codes_len - (mark != NULL);
  if (kinds_len - 1 > AGC_FFI_MAX_PARAMS || (mark && mark - codes < 2)) bad_signature(vm, span);
  if (mark) {
    fixed = (uint32_t)(mark - codes - 1);
    memcpy(kinds, codes, (size_t)(mark - codes));
    memcpy(kinds + (mark - codes), mark + 1, codes_len - (size_t)(mark - codes) - 1);
  } else {
    memcpy(kinds, codes, codes_len);
  }
  agc_c_type result, params[AGC_FFI_MAX_PARAMS], c_params[AGC_FFI_MAX_PARAMS];
  bool out[AGC_FFI_MAX_PARAMS], result_out;
  if (!c_type_of(kinds[0], true, &result, &result_out)) bad_signature(vm, span);
  uint32_t count = (uint32_t)(kinds_len - 1), outs = 0;
  free_list frees;
  frees.count = 0;
  bool made = result == AGC_C_RESOURCE;
  if (made) frees.count++;
  for (uint32_t k = 0; k < count; k++) {
    if (!c_type_of(kinds[k + 1], false, &params[k], &out[k])) bad_signature(vm, span);
    if (k >= fixed && (out[k] || params[k] == AGC_C_BOOL || params[k] == AGC_C_FLOAT)) bad_signature(vm, span);
    /* C gets a pointer to the slot of an out parameter. */
    c_params[k] = out[k] ? AGC_C_POINTER : params[k];
    outs += out[k];
    if (out[k] && params[k] == AGC_C_RESOURCE) frees.count++;
  }
  for (uint32_t k = 0; k < frees.count; k++) {
    if (!next_word(&at, &left, &frees.names[k], &frees.lens[k]) ||
        !next_word(&at, &left, &frees.kinds[k], &frees.kind_lens[k]) ||
        !identifier(frees.kinds[k], frees.kind_lens[k]))
      bad_signature(vm, span);
    frees.calls[k] = NULL;
  }
  /* A NUL inside a name would cut it short for the system loader: such a name opens nothing. */
  bool nul = left == 0 || memchr(at, 0, left) || memchr(symbol, 0, symbol_len);
  for (uint32_t k = 0; k < frees.count && !nul; k++) nul = memchr(frees.names[k], 0, frees.lens[k]) != NULL;
  if (nul) load_failed(vm, "a library or function name is empty or holds a NUL character", span);
  char *library = text_copy(at, left), *symbol_text = text_copy(symbol, symbol_len);
  char error[512];
  agc_ffi_call *call = agc_ffi_prepare(library, symbol_text, result, c_params, count, fixed, error, sizeof error);
  bool prepared = call != NULL;
  for (uint32_t k = 0; k < frees.count && prepared; k++) {
    /* Each free function is in the same library and takes the pointer: void free(void *). */
    char *free_text = text_copy(frees.names[k], frees.lens[k]);
    const agc_c_type pointer = AGC_C_POINTER;
    frees.calls[k] =
        agc_ffi_prepare(library, free_text, AGC_C_VOID, &pointer, 1, AGC_FFI_NOT_VARIADIC, error, sizeof error);
    free(free_text);
    prepared = frees.calls[k] != NULL;
  }
  free(library);
  if (!prepared) {
    if (call) agc_ffi_discard(call);
    discard_frees(&frees);
    free(symbol_text);
    load_failed(vm, error, span);
  }
  ffi_entry *e = calloc(1, sizeof(ffi_entry));
  if (!e) agc_out_of_memory();
  e->compute = compute;
  e->call = call;
  e->result = result;
  e->count = count;
  e->outs = outs;
  memcpy(e->params, params, count * sizeof(agc_c_type));
  memcpy(e->out, out, count * sizeof(bool));
  uint32_t next = 0, kind = made ? 1 : 0;
  for (uint32_t k = 0; k < count; k++) {
    if (!out[k]) {
      e->arg[k] = (uint8_t)next++;
    } else if (params[k] == AGC_C_RESOURCE) {
      if (!e->made) {
        e->made = calloc(count, sizeof(made_kind));
        if (!e->made) agc_out_of_memory();
      }
      e->made[k] = (made_kind){frees.calls[kind], text_copy(frees.kinds[kind], frees.kind_lens[kind])};
      kind++;
    }
  }
  e->inputs = next;
  if (made) {
    e->free = frees.calls[0];
    e->resource = text_copy(frees.kinds[0], frees.kind_lens[0]);
    e->symbol = symbol_text;
  } else {
    free(symbol_text);
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

/* Runs FREE_CALL, a void free(void *), on POINTER unless it is NULL. */
static void free_pointer(agc_ffi_call *free_call, void *pointer) {
  if (!pointer) return;
  agc_c_value arg = {.p = pointer}, unused;
  agc_ffi_invoke(free_call, &arg, &unused);
}

/* Calls the free function of the resource, once; an owned buffer is malloc'd memory. */
static void call_free(agc_c_resource *res) {
  res->closed = res->freed = true;
  if (res->buffer) {
    free(res->pointer);
  } else {
    free_pointer(res->free, res->pointer);
  }
}

/* Frees the resource and drops its registry entry; under rt->sync, with no compute call holding it. */
static void free_resource(agc_vm *vm, agc_c_resource *res) {
  call_free(res);
  res->state->native = NULL;
  agc_unregister(vm, res->state);
}

/* Native.close and the end of the owning task (§14.5): the resource is closed and leaves its owner at once, and is
   freed now, or by the end of the last compute call that holds it (release_held). A closed resource is left alone. */
static void close_resource(agc_vm *vm, agc_c_resource *res) {
  agc_sync_assert(vm);
  if (res->closed) return;
  res->closed = true;
  agc_disown(res->state);
  if (!res->jobs) free_resource(vm, res);
}

static void close_owned(agc_vm *vm, agc_resource *r, agc_task *ender) {
  (void)ender;
  close_resource(vm, r->native);
}

/* The end of the run (release_handles) and the dropped result of a cancelled compute call (discard in vm/loop.c): the
   free runs unless a compute call still holds the resource, which the end of the run does not wait for. Neither needs
   rt->sync: discard drops a resource that compute_done made a moment before, which no other task has seen (at more
   than one scheduler it runs inside agc_io_service, which holds the lock anyway), and at the end of the run only one
   thread is left. */
static void release_resource(void *native) {
  agc_c_resource *res = native;
  if (!res->freed && !res->jobs) call_free(res);
}

/* A resource NAME around POINTER, freed by FREE_CALL and owned by the calling task (none for a detached compute call,
   whose result is dropped and so freed at once). A NULL pointer (an out resource that C left NULL) gives a resource
   that is closed already and was never registered: no close, owner's end or end of the run frees it, and a call that
   takes it is RUNTIME-NATIVE-CLOSED. */
static agc_value make_resource(agc_vm *vm, agc_ffi_call *free_call, const char *name, void *pointer) {
  agc_c_resource *res = agc_alloc(sizeof *res);
  res->pointer = pointer;
  res->free = free_call;
  res->name = name;
  res->size = 0;
  res->jobs = 0;
  res->closed = res->freed = pointer == NULL;
  res->buffer = false;
  res->state = NULL;
  if (pointer) {
    res->state = agc_register(vm, res, release_resource);
    agc_own(vm, res->state, close_owned);
  }
  return agc_c_resource_value(res);
}

/* The resource that a call returned, as Result ok; NULL is an error that names the function. */
static agc_value resource_result(agc_vm *vm, const ffi_entry *e, void *pointer) {
  if (!pointer) {
    char message[512];
    snprintf(message, sizeof message, "%s returned NULL", e->symbol);
    return agc_error_value(message);
  }
  return agc_result_value(true, make_resource(vm, e->free, e->resource, pointer));
}

/* The compute calls that held these resources are over: a resource closed meanwhile is freed by the last of them. */
static void release_held(agc_vm *vm, const ffi_entry *e, agc_c_resource **held) {
  agc_sync_assert(vm);
  for (uint32_t k = 0; k < e->count; k++) {
    agc_c_resource *res = held[k];
    if (res && --res->jobs == 0 && res->closed && !res->freed) free_resource(vm, res);
  }
}

/* The owned buffer that V is, or NULL when V is a plain C.Pointer: both are a C.Pointer to the program. Anything else
   (only hand-made bytecode passes it) is a wrong tag. */
static agc_c_resource *buffer_of(agc_vm *vm, agc_value v) {
  if (agc_is(v, AGC_T_C_POINTER)) return NULL;
  agc_c_resource *res = agc_as_c_resource(vm, v);
  if (!res->buffer) agc_wrong_tag(vm);
  return res;
}

/* The C pointer of a C.Pointer value: an owned buffer gives its memory. Whether a buffer is closed is checked apart. */
static void *pointer_of(agc_vm *vm, agc_value v) {
  agc_c_resource *res = buffer_of(vm, v);
  return res ? res->pointer : agc_as_c_pointer(vm, v);
}

/* Checks argument V against its C type before anything is allocated, so a failure (agc_fail longjmps) leaks
   nothing. A C.Int32 that does not fit in 32 bits and a C.String with a NUL inside fail: C cannot take them, and
   cutting them short would call the function with another value. The items of a C.Bytes are checked while they are
   copied (copy_bytes), and whether a resource or an owned buffer is closed before and after that (check_open). A
   C.Float takes any Float: one outside the range of a float becomes an infinity (IEEE 754, C11 Annex F). */
static void check_argument(agc_vm *vm, agc_c_type type, agc_value v, uint32_t span) {
  switch (type) {
    case AGC_C_INT: {
      int64_t n = agc_as_int(vm, v);
      if (n < INT32_MIN || n > INT32_MAX)
        agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "a C.Int32 argument does not fit in 32 bits", span);
      break;
    }
    case AGC_C_INT64: agc_as_int(vm, v); break;
    case AGC_C_DOUBLE:
    case AGC_C_FLOAT: agc_as_float(vm, v); break;
    case AGC_C_BOOL: agc_as_bool(vm, v); break;
    case AGC_C_STRING: {
      const agc_string *s = agc_as_string(vm, v);
      if (s->bytes && memchr(s->data, 0, s->bytes))
        agc_fail(vm, "RUNTIME-INVALID-CHARACTER", "a C.String argument holds a NUL character", span);
      /* The scan here and the copy in c_argument cost in proportion to the text. */
      agc_charge_bytes(vm, s->bytes);
      break;
    }
    case AGC_C_POINTER: (void)buffer_of(vm, v); break;
    case AGC_C_BYTES: agc_as_list(vm, v); break;
    case AGC_C_RESOURCE: agc_as_c_resource(vm, v); break;
    case AGC_C_VOID: agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: a Void parameter", span);
  }
}

/* The C value of a checked argument. A C.String is a malloc'd copy, which the caller frees after the call
   (free_copies); a C.Bytes is BYTES, its copy made before (copy_bytes), which free_copies frees too. */
static agc_c_value c_argument(agc_vm *vm, agc_c_type type, agc_value v, uint8_t *bytes) {
  agc_c_value out = {0};
  switch (type) {
    case AGC_C_INT: out.i = (int32_t)agc_as_int(vm, v); break;
    case AGC_C_INT64: out.l = agc_as_int(vm, v); break;
    case AGC_C_DOUBLE: out.d = agc_as_float(vm, v); break;
    /* An infinity when out of range: every target with native calls is IEEE 754 (C11 Annex F). */
    case AGC_C_FLOAT: out.f = (float)agc_as_float(vm, v); break;
    case AGC_C_BOOL: out.b = agc_as_bool(vm, v); break;
    case AGC_C_STRING: out.s = agc_cstr(agc_as_string(vm, v)); break;
    case AGC_C_POINTER: out.p = pointer_of(vm, v); break;
    case AGC_C_RESOURCE: out.p = agc_as_c_resource(vm, v)->pointer; break;
    case AGC_C_BYTES: out.p = bytes; break;
    case AGC_C_VOID: break;
  }
  return out;
}

/* A malloc'd copy of a C.Bytes argument into *OUT, made in one walk of the list. An item outside 0..255 (C cannot
   take it) or not an Int (invalid bytecode) gives no copy. It runs without rt->sync (a List is immutable) and never
   fails: the caller fails once it holds the lock again. */
static bytes_outcome copy_bytes(agc_vm *vm, const agc_list *bytes, uint8_t **out) {
  size_t n = agc_list_len(bytes);
  uint8_t *copy = malloc(n ? n : 1);
  if (!copy) agc_out_of_memory();
  for (size_t k = 0; k < n; k++) {
    agc_value item = agc_list_get(bytes, k);
    if (!agc_is(item, AGC_T_INT)) {
      free(copy);
      return BYTES_TAG;
    }
    int64_t byte = agc_as_int(vm, item);
    if (byte < 0 || byte > 255) {
      free(copy);
      return BYTES_RANGE;
    }
    copy[k] = (uint8_t)byte;
  }
  *out = copy;
  return BYTES_OK;
}

static void free_bytes(const ffi_entry *e, uint8_t **bytes) {
  for (uint32_t k = 0; k < e->count; k++) free(bytes[k]);
}

/* Copies the C.Bytes arguments of a call into BYTES (NULL for the other parameters); the caller has checked that
   each is a List. A long list takes long to walk, so the walk runs with rt->sync dropped (a shared builtin is called
   with it taken once), and the lock is taken again before anything shared is read. The turn is charged one unit per
   item. On a failure nothing is left allocated. */
static void copy_byte_arguments(agc_vm *vm, const ffi_entry *e, const agc_list *values, uint8_t **bytes,
                                uint32_t span) {
  bool any = false;
  for (uint32_t k = 0; k < e->count; k++) {
    bytes[k] = NULL;
    any = any || (e->params[k] == AGC_C_BYTES && !e->out[k]);
  }
  if (!any) return;
  bool unlock = vm->sync_depth == 1;
  if (unlock) agc_sync_drop(vm);
  bytes_outcome bad = BYTES_OK;
  uint64_t items = 0;
  for (uint32_t k = 0; k < e->count && bad == BYTES_OK; k++) {
    if (e->params[k] != AGC_C_BYTES || e->out[k]) continue;
    const agc_list *list = agc_as_list(vm, agc_list_get(values, e->arg[k]));
    items += agc_list_len(list);
    bad = copy_bytes(vm, list, &bytes[k]);
  }
  if (unlock) agc_sync_take(vm);
  agc_charge(vm, items);
  if (bad == BYTES_OK) return;
  free_bytes(e, bytes);
  if (bad == BYTES_TAG) agc_wrong_tag(vm);
  agc_fail(vm, "RUNTIME-INVALID-NUMBER", "a C.Bytes item is not a byte (0 to 255)", span);
}

/* The resource or owned buffer that argument K holds (a resource parameter, or a C.Pointer one given a buffer), or
   NULL. */
static agc_c_resource *held_by(agc_vm *vm, const ffi_entry *e, const agc_list *values, uint32_t k) {
  if (e->out[k]) return NULL;
  if (e->params[k] == AGC_C_RESOURCE) return agc_as_c_resource(vm, agc_list_get(values, e->arg[k]));
  if (e->params[k] == AGC_C_POINTER) return buffer_of(vm, agc_list_get(values, e->arg[k]));
  return NULL;
}

/* A closed resource or owned buffer fails: its pointer is freed, or about to be. Under rt->sync. The call checks once
   before the byte copies (BYTES NULL), so a closed resource fails first, and once after them, with the lock taken
   again, so no close comes between this check and the call; a failure then frees the copies. */
static void check_open(agc_vm *vm, const ffi_entry *e, const agc_list *values, uint8_t **bytes, uint32_t span) {
  for (uint32_t k = 0; k < e->count; k++) {
    agc_c_resource *res = held_by(vm, e, values, k);
    if (res && res->closed) {
      if (bytes) free_bytes(e, bytes);
      agc_fail(vm, "RUNTIME-NATIVE-CLOSED", "a native call takes a resource that is closed", span);
    }
  }
}

/* A String copy of the N bytes of C memory at P (NULL when N is 0). Bytes that are not UTF-8 become U+FFFD, as in
   every String the VM builds from outside text. */
static agc_value text_value(const uint8_t *p, size_t n) {
  return agc_string_value(agc_utf8_decode(n ? p : (const uint8_t *)"", n, "\xEF\xBF\xBD", false));
}

static agc_value result_value(agc_vm *vm, const ffi_entry *e, const agc_c_value *r) {
  switch (e->result) {
    case AGC_C_INT: return agc_int(r->i);
    case AGC_C_INT64: return agc_int(r->l);
    case AGC_C_DOUBLE: return agc_float(r->d);
    case AGC_C_FLOAT: return agc_float(r->f);
    case AGC_C_BOOL: return agc_bool(r->b);
    case AGC_C_STRING: {
      /* The function keeps the text it returns (Agentica copies it and frees nothing); NULL reads as "". */
      const char *s = r->s ? r->s : "";
      return text_value((const uint8_t *)s, strlen(s));
    }
    case AGC_C_POINTER: return agc_c_pointer_value(r->p);
    case AGC_C_RESOURCE: return resource_result(vm, e, r->p);
    case AGC_C_BYTES:
    case AGC_C_VOID: break;
  }
  return agc_void();
}

/* The value of the out parameter K from its slot, which C wrote (or left zeroed). A C.Bool is read as the byte C
   wrote, so a slot that does not hold 0 or 1 is never read as a _Bool. */
static agc_value out_value(agc_vm *vm, const ffi_entry *e, uint32_t k, const agc_c_value *slot) {
  switch (e->params[k]) {
    case AGC_C_INT: return agc_int(slot->i);
    case AGC_C_INT64: return agc_int(slot->l);
    case AGC_C_DOUBLE: return agc_float(slot->d);
    case AGC_C_FLOAT: return agc_float(slot->f);
    case AGC_C_BOOL: {
      uint8_t byte;
      memcpy(&byte, slot, 1);
      return agc_bool(byte != 0);
    }
    case AGC_C_POINTER: return agc_c_pointer_value(slot->p);
    case AGC_C_RESOURCE: return make_resource(vm, e->made[k].free, e->made[k].name, slot->p);
    case AGC_C_STRING:
    case AGC_C_BYTES:
    case AGC_C_VOID: break;
  }
  return agc_void();
}

/* The value of a call: the C result, or for a function with out parameters the List of the fields of its record (the
   C result unless Void, then each out value from its slot). */
static agc_value call_value(agc_vm *vm, const ffi_entry *e, const agc_c_value *r, const agc_c_value *slots) {
  if (!e->outs) return result_value(vm, e, r);
  agc_value items[AGC_FFI_MAX_PARAMS + 1];
  size_t n = 0;
  if (e->result != AGC_C_VOID) items[n++] = result_value(vm, e, r);
  for (uint32_t k = 0; k < e->count; k++)
    if (e->out[k]) items[n++] = out_value(vm, e, k, &slots[k]);
  return agc_list_value(agc_list_from_array(items, n));
}

/* The resources that a compute call with out parameters made, when nobody takes its value (the task was cancelled):
   each pointer that is not NULL is freed here, once, and no value is made. */
static void drop_made(const ffi_entry *e, const agc_c_value *r, const agc_c_value *slots) {
  if (e->result == AGC_C_RESOURCE) free_pointer(e->free, r->p);
  for (uint32_t k = 0; k < e->count; k++)
    if (e->out[k] && e->params[k] == AGC_C_RESOURCE) free_pointer(e->made[k].free, slots[k].p);
}

static void free_copies(const ffi_entry *e, agc_c_value *in) {
  for (uint32_t k = 0; k < e->count; k++)
    if (!e->out[k] && (e->params[k] == AGC_C_STRING || e->params[k] == AGC_C_BYTES)) free(in[k].p);
}

static void compute_free(void *data) {
  compute_call *c = data;
  free_copies(c->entry, c->in);
  if (c->ran && c->entry->result == AGC_C_STRING) free((char *)c->out.s);
  free(c);
}

/* On a pool thread: C values only, no GC memory. */
static void compute_work(void *data) {
  compute_call *c = data;
  agc_ffi_invoke(c->entry->call, c->in, &c->out);
  if (c->entry->result == AGC_C_STRING && c->out.s) {
    size_t n = strlen(c->out.s);
    char *copy = malloc(n + 1);
    if (!copy) agc_out_of_memory();
    memcpy(copy, c->out.s, n + 1);
    c->out.s = copy;
  }
  c->ran = true;
}

/* On the scheduler that resumes the task, with rt->sync held (the kind is `locked`): the held resources are let go and
   the result becomes a value there. For a cancelled task it runs too and the value is dropped (the detached end of the
   job), a resource result with it; a call whose work was skipped (cancelled while it waited) has no result, so it
   gives Void, which the detached end drops. A job dropped without this half (its pool work could not start, or the
   run is over) keeps its holds: the task fails, and a resource that the job held is never freed, a leak and never a
   use after free. */
static agc_value compute_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  compute_call *c = data;
  const ffi_entry *e = c->entry;
  release_held(vm, e, c->held);
  agc_value v = agc_void();
  /* A call with out parameters gives a List, which the detached end (discard in vm/loop.c) does not look into, so its
     resources are freed here when nobody takes the value. Invariant (the one agc_own relies on too): `done` runs with
     vm->in_turn set exactly when a task takes the value (agc_io_finish, from resume in the task's turn); a detached
     job's `done` runs from end_detached, which the drain and agc_io_service call only between turns. The job's own
     `detached` flag is private to vm/loop.c and reaches no half. */
  if (c->ran && e->outs && !vm->in_turn)
    drop_made(e, &c->out, c->slots);
  else if (c->ran)
    v = call_value(vm, e, &c->out, c->slots);
  compute_free(c);
  return v;
}

/* Never reached: the job has no deadline and nothing else wakes the task. Should it be, there is no value of the
   call's type to give, so the run ends with RUNTIME-INTERNAL; the job stays (the work may still use its data), which
   the end of the run does not mind. */
static agc_value compute_expired(agc_vm *vm, void *data, agc_value context) {
  (void)data;
  (void)context;
  agc_fail(vm, "RUNTIME-INTERNAL", "a compute call ended without its result", 0);
}

static const agc_io_kind compute_io = {compute_work, compute_done, compute_expired, compute_free, false, "compute",
                                       NULL, true, NULL};

/* Native.call(signature, arguments): one call of an extern function, on the scheduler, or for a compute def on the
   compute pool while the task waits. The arguments are a List with one value per parameter, of the Agentica type the
   checker gave it. Every argument is checked before the first copy is made; then the C.Bytes arguments are copied,
   with rt->sync dropped (copy_byte_arguments), and the resources are checked open with the lock taken again, so none
   closes before the call. Nothing between the other copies and their free (or the start of the compute job, which
   then owns them) can fail. A shared builtin: it runs with rt->sync held, which the resources need. */
static agc_value builtin_native_call(agc_vm *vm, agc_value *args, uint32_t span) {
  /* The fuzzer runs hand-made bytecode with no_files: it must open no library. */
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
  ffi_entry *e = find_call(vm, agc_as_string(vm, args[0]), span);
  const agc_list *values = agc_as_list(vm, args[1]);
  if (agc_list_len(values) != e->inputs)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: wrong number of native arguments", span);
  for (uint32_t k = 0; k < e->count; k++)
    if (!e->out[k]) check_argument(vm, e->params[k], agc_list_get(values, e->arg[k]), span);
  /* The loop is made first: a loop that cannot start fails here, before the copies exist. */
  if (e->compute) (void)agc_io_loop(vm);
  check_open(vm, e, values, NULL, span);
  uint8_t *bytes[AGC_FFI_MAX_PARAMS];
  copy_byte_arguments(vm, e, values, bytes, span);
  check_open(vm, e, values, bytes, span);
  agc_charge(vm, FFI_CALL_COST);
  if (e->compute) {
    /* in, then the slots, then held: one block. */
    size_t in_size = agc_size_mul(agc_size_mul(e->count, 2), sizeof(agc_c_value));
    size_t held_size = agc_size_mul(e->count, sizeof(agc_c_resource *));
    compute_call *c = malloc(agc_size_add(agc_size_add(sizeof(compute_call), in_size), held_size));
    if (!c) agc_out_of_memory();
    c->entry = e;
    c->slots = c->in + e->count;
    c->held = (agc_c_resource **)(void *)(c->slots + e->count);
    c->ran = false;
    memset(&c->out, 0, sizeof c->out);
    for (uint32_t k = 0; k < e->count; k++) {
      c->held[k] = NULL;
      memset(&c->slots[k], 0, sizeof c->slots[k]);
      if (e->out[k]) {
        c->in[k].p = &c->slots[k];
        continue;
      }
      c->in[k] = c_argument(vm, e->params[k], agc_list_get(values, e->arg[k]), bytes[k]);
      c->held[k] = held_by(vm, e, values, k);
      if (c->held[k]) c->held[k]->jobs++;
    }
    agc_io_compute(vm, &compute_io, c);
    return agc_void();
  }
  agc_c_value in[AGC_FFI_MAX_PARAMS], slots[AGC_FFI_MAX_PARAMS];
  for (uint32_t k = 0; k < e->count; k++) {
    if (e->out[k]) {
      memset(&slots[k], 0, sizeof slots[k]);
      in[k].p = &slots[k];
    } else {
      in[k] = c_argument(vm, e->params[k], agc_list_get(values, e->arg[k]), bytes[k]);
    }
  }
  agc_c_value out = {0};
  agc_ffi_invoke(e->call, in, &out);
  free_copies(e, in);
  return call_value(vm, e, &out, slots);
}

/* Native.close(resource): see close_resource. */
static agc_value builtin_native_close(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  close_resource(vm, agc_as_c_resource(vm, args[0]));
  return agc_void();
}

static agc_value builtin_native_null(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)vm;
  (void)args;
  (void)span;
  return agc_c_pointer_value(NULL);
}

/* Native.null?(pointer): an owned buffer is never NULL, even once freed. */
static agc_value builtin_native_null_p(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_bool(!buffer_of(vm, args[0]) && agc_as_c_pointer(vm, args[0]) == NULL);
}

/* Native.pointer(address): the C.Pointer with this integer value, such as SQLITE_TRANSIENT, (void *)-1. */
static agc_value builtin_native_pointer(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_c_pointer_value((void *)(intptr_t)agc_as_int(vm, args[0]));
}

/* Native.memory_pointer(size): a new owned buffer of SIZE zeroed bytes (calloc), which the calling task owns like a
   resource: Native.free, the owner's end or the end of the run frees it. The program sees a C.Pointer. The fuzzer's
   hand-made bytecode (no_files) may not make one, as it may not call. */
static agc_value builtin_memory_pointer(agc_vm *vm, agc_value *args, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
  int64_t size = agc_as_int(vm, args[0]);
  if (size < 0) agc_fail(vm, "RUNTIME-INVALID-COUNT", "size must be nonnegative", span + 1);
  /* The GC struct first: a failed allocation then leaks no memory of calloc. A size the system cannot give is the
     program's error, not the VM's out of memory. */
  agc_c_resource *res = agc_alloc(sizeof *res);
  void *memory = (uint64_t)size <= BUFFER_MAX && (uint64_t)size < SIZE_MAX ? calloc(size ? (size_t)size : 1, 1) : NULL;
  if (!memory) agc_fail(vm, "RUNTIME-INVALID-COUNT", "the system cannot give a buffer of this size", span + 1);
  /* Zeroing the memory grows with the size, as the copy of a C.String argument does. */
  agc_charge_bytes(vm, (size_t)size);
  res->pointer = memory;
  res->free = NULL;
  res->name = BUFFER_NAME;
  res->size = (size_t)size;
  res->jobs = 0;
  res->closed = res->freed = false;
  res->buffer = true;
  res->state = agc_register(vm, res, release_resource);
  agc_own(vm, res->state, close_owned);
  return agc_c_resource_value(res);
}

/* The first step calls the block with the buffer; the second frees the buffer, as Native.free does, and ends the call
   with what the block returned, an error Result from a `try` included. Ownership wins: a buffer that the block handed
   to another task (Task.spawn_owning) is left to its new owner, whose end frees it. A runtime failure in the block
   never comes back here: it ends the task, and the owner's end frees the buffer. */
static agc_step buffer_block_step(agc_vm *vm, agc_stepper *self, agc_value last) {
  buffer_block *b = (buffer_block *)self;
  if (!b->called) {
    b->called = true;
    return (agc_step){.kind = AGC_STEP_CALL, .value = b->buffer, .fn = agc_void()};
  }
  /* The stepper is not `unlocked`, so this step runs with rt->sync held, which the owner check and close_resource
     need. A buffer freed in the block has no owner any more and is left as it is. */
  if (agc_task_owns(vm, b->buffer)) close_resource(vm, agc_as_c_resource(vm, b->buffer));
  return (agc_step){.kind = AGC_STEP_END, .value = last};
}

/* Native.memory_pointer(size) do |buf| ... end, Ruby ffi's MemoryPointer.new(size) { |p| ... }: a new owned buffer
   for the block, freed when the block ends; the call returns the block's value. */
static agc_value builtin_memory_pointer_block(agc_vm *vm, agc_value *args, uint32_t span) {
  buffer_block *b = agc_alloc(sizeof *b);
  b->buffer = builtin_memory_pointer(vm, args, span);
  b->stepper.step = buffer_block_step;
  agc_task_stepper(vm, &b->stepper);
  return agc_void();
}

/* Native.free(pointer): frees an owned buffer once, as Native.close frees a resource; a C.Pointer that C gave is not
   the program's to free. */
static agc_value builtin_native_free(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_c_resource *res = buffer_of(vm, args[0]);
  if (!res) agc_fail(vm, "RUNTIME-NATIVE-NOT-OWNED", "Native.free takes a buffer of Native.memory_pointer", span + 1);
  close_resource(vm, res);
  return agc_void();
}

/* The address of what a memory builtin reads or writes (ASK) at the pointer P, its first argument (span + 1). The
   fuzzer's hand-made bytecode (no_files) may not touch memory, as it may not call. An owned buffer knows its size: a
   freed one is RUNTIME-NATIVE-CLOSED, and any byte before or past it RUNTIME-NATIVE-BOUNDS, so nothing outside it is
   ever read or written. A C.Pointer of C has no size: NULL fails unless nothing is asked for (a count of 0, the C way
   to say "empty": SQLite gives NULL for an empty blob), a negative offset fails, and any other address is used as it
   is. Native code is trusted: memory that C does not own is undefined behavior, like a wrong signature. Then a
   negative count fails. The memory rows are not shared: a read at a C pointer runs beside the other schedulers. For an
   owned buffer this takes rt->sync (*LOCKED set), so no free comes between the check and the copy; the caller drops it
   after the copy (memory_done), and a failure in between leaves it to agc_sync_reset. */
static uint8_t *memory_at(agc_vm *vm, agc_value p, memory_ask ask, uint32_t span, bool *locked) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
  agc_c_resource *res = buffer_of(vm, p);
  *locked = res != NULL;
  if (res) agc_sync_take(vm);
  uint8_t *base = res ? res->pointer : agc_as_c_pointer(vm, p);
  if (res && res->closed) agc_fail(vm, "RUNTIME-NATIVE-CLOSED", "the owned buffer is freed", span + 1);
  if (!base && ask.count != 0) agc_fail(vm, "RUNTIME-NATIVE-NULL", "a memory access at a NULL C.Pointer", span + 1);
  if (ask.offset < 0) agc_fail(vm, "RUNTIME-NATIVE-BOUNDS", "a memory offset must be nonnegative", ask.offset_span);
  if (ask.count < 0) agc_fail(vm, "RUNTIME-INVALID-COUNT", "length must be nonnegative", ask.count_span);
  uint64_t bytes;
  bool over = __builtin_mul_overflow((uint64_t)ask.count, (uint64_t)ask.size, &bytes);
  if (res && (uint64_t)ask.offset > res->size)
    agc_fail(vm, "RUNTIME-NATIVE-BOUNDS", "the offset is past the end of the owned buffer", ask.offset_span);
  if (res && (over || bytes > res->size - (uint64_t)ask.offset))
    agc_fail(vm, "RUNTIME-NATIVE-BOUNDS", "the memory runs past the end of the owned buffer", ask.count_span);
  /* A count this large at a C pointer cannot be memory C owns. A smaller wrong one is trusted; a read sizes its list
     before it reads C memory, so a count too large for the VM's memory ends the run there (out of memory). */
  if (!res && (over || bytes > (uint64_t)PTRDIFF_MAX))
    agc_fail(vm, "RUNTIME-NATIVE-BOUNDS", "the memory is larger than any C object", ask.count_span);
  /* Integer arithmetic: the address of a C pointer is C's to vouch for, and NULL (with nothing asked) stays NULL. */
  return base ? (uint8_t *)(uintptr_t)((uintptr_t)base + (uint64_t)ask.offset) : NULL;
}

/* Gives back rt->sync that memory_at took for an owned buffer, once the copy is made. */
static void memory_done(agc_vm *vm, bool locked) {
  if (locked) agc_sync_drop(vm);
}

/* The text at OFFSET bytes past the pointer P (Native.get_string(pointer, offset)): a copy up to the first NUL. In an
   owned buffer the text must end before the buffer does. */
static agc_value text_until_nul(agc_vm *vm, agc_value p, int64_t offset, uint32_t offset_span, uint32_t span) {
  agc_c_resource *res = buffer_of(vm, p);
  bool locked;
  const uint8_t *at = memory_at(vm, p, (memory_ask){offset, res ? 0 : 1, 1, offset_span, offset_span}, span, &locked);
  const uint8_t *nul = res ? memchr(at, 0, res->size - (size_t)offset) : at + strlen((const char *)at);
  if (!nul) agc_fail(vm, "RUNTIME-NATIVE-BOUNDS", "the owned buffer holds no NUL byte to end the text", span + 1);
  agc_value text = text_value(at, (size_t)(nul - at));
  memory_done(vm, locked);
  return text;
}

/* Native.get_string(pointer, offset) and get_string(pointer, offset, length), Ruby ffi's get_string: the text from
   OFFSET bytes past the pointer up to its NUL, or exactly LENGTH bytes. */
static agc_value builtin_get_string(agc_vm *vm, agc_value *args, uint32_t span) {
  return text_until_nul(vm, args[0], agc_as_int(vm, args[1]), span + 2, span);
}

static agc_value builtin_get_string_length(agc_vm *vm, agc_value *args, uint32_t span) {
  memory_ask ask = {agc_as_int(vm, args[1]), agc_as_int(vm, args[2]), 1, span + 2, span + 3};
  bool locked;
  const uint8_t *at = memory_at(vm, args[0], ask, span, &locked);
  agc_value text = text_value(at, (size_t)ask.count);
  memory_done(vm, locked);
  return text;
}

/* The item of KIND at AT, which may be unaligned (memcpy). */
static agc_value load_item(item_kind kind, const uint8_t *at) {
  switch (kind) {
    case ITEM_INT8: { int8_t x; memcpy(&x, at, sizeof x); return agc_int(x); }
    case ITEM_INT16: { int16_t x; memcpy(&x, at, sizeof x); return agc_int(x); }
    case ITEM_INT32: { int32_t x; memcpy(&x, at, sizeof x); return agc_int(x); }
    case ITEM_INT64: { int64_t x; memcpy(&x, at, sizeof x); return agc_int(x); }
    case ITEM_UINT8:
    case ITEM_BYTE: { uint8_t x; memcpy(&x, at, sizeof x); return agc_int(x); }
    case ITEM_UINT16: { uint16_t x; memcpy(&x, at, sizeof x); return agc_int(x); }
    case ITEM_UINT32: { uint32_t x; memcpy(&x, at, sizeof x); return agc_int(x); }
    case ITEM_FLOAT32: { float x; memcpy(&x, at, sizeof x); return agc_float(x); }
    case ITEM_FLOAT64: { double x; memcpy(&x, at, sizeof x); return agc_float(x); }
    case ITEM_POINTER: { void *x; memcpy(&x, at, sizeof x); return agc_c_pointer_value(x); }
  }
  return agc_void();
}

/* Checks V before an item of KIND is written: an Int that fits in the item's bits read as signed or as unsigned (an
   int8 takes -128 to 255, the same bits; a byte of put_bytes only 0 to 255), a Float (a float32 takes any, one outside
   the range of a float becomes an infinity), or a C.Pointer (an owned buffer, unless freed, gives its address). */
static void check_item(agc_vm *vm, item_kind kind, agc_value v, uint32_t span) {
  if (kind == ITEM_FLOAT32 || kind == ITEM_FLOAT64) {
    (void)agc_as_float(vm, v);
  } else if (kind == ITEM_POINTER) {
    agc_c_resource *res = buffer_of(vm, v);
    if (!res) (void)agc_as_c_pointer(vm, v);
    if (res && res->closed) agc_fail(vm, "RUNTIME-NATIVE-CLOSED", "the owned buffer is freed", span);
  } else if (kind == ITEM_BYTE) {
    int64_t n = agc_as_int(vm, v);
    if (n < 0 || n > 255) agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "a byte must be 0 to 255", span);
  } else {
    int64_t n = agc_as_int(vm, v);
    unsigned bits = (unsigned)ITEM_WIDTHS[kind] * 8;
    if (bits < 64 && (n < -(INT64_C(1) << (bits - 1)) || n > (INT64_C(1) << bits) - 1))
      agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "the value does not fit in the memory item", span);
  }
}

/* Writes the checked V as the item of KIND at AT, which may be unaligned. An Int keeps its low bits, so 255 and -1 give
   one int8. */
static void store_item(agc_vm *vm, item_kind kind, uint8_t *at, agc_value v) {
  switch (kind) {
    case ITEM_INT8:
    case ITEM_UINT8:
    case ITEM_BYTE: { uint8_t x = (uint8_t)agc_as_int(vm, v); memcpy(at, &x, sizeof x); break; }
    case ITEM_INT16:
    case ITEM_UINT16: { uint16_t x = (uint16_t)agc_as_int(vm, v); memcpy(at, &x, sizeof x); break; }
    case ITEM_INT32:
    case ITEM_UINT32: { uint32_t x = (uint32_t)agc_as_int(vm, v); memcpy(at, &x, sizeof x); break; }
    case ITEM_INT64: { int64_t x = agc_as_int(vm, v); memcpy(at, &x, sizeof x); break; }
    /* Out of range, the conversion gives an infinity: every target with native calls is IEEE 754 (C11 Annex F). */
    case ITEM_FLOAT32: { float x = (float)agc_as_float(vm, v); memcpy(at, &x, sizeof x); break; }
    case ITEM_FLOAT64: { double x = agc_as_float(vm, v); memcpy(at, &x, sizeof x); break; }
    case ITEM_POINTER: { void *x = pointer_of(vm, v); memcpy(at, &x, sizeof x); break; }
  }
}

/* Native.get_KIND(pointer, offset): the item at OFFSET bytes past the pointer. */
static agc_value get_one(agc_vm *vm, agc_value *args, uint32_t span, item_kind kind) {
  memory_ask ask = {agc_as_int(vm, args[1]), 1, ITEM_WIDTHS[kind], span + 2, span + 2};
  bool locked;
  agc_value v = load_item(kind, memory_at(vm, args[0], ask, span, &locked));
  memory_done(vm, locked);
  return v;
}

/* Native.put_KIND(pointer, offset, value): writes VALUE at OFFSET bytes past the pointer. */
static agc_value put_one(agc_vm *vm, agc_value *args, uint32_t span, item_kind kind) {
  memory_ask ask = {agc_as_int(vm, args[1]), 1, ITEM_WIDTHS[kind], span + 2, span + 2};
  bool locked;
  uint8_t *at = memory_at(vm, args[0], ask, span, &locked);
  /* A buffer stored as a pointer is checked open under rt->sync too. */
  if (!locked && kind == ITEM_POINTER && buffer_of(vm, args[2])) {
    agc_sync_take(vm);
    locked = true;
  }
  check_item(vm, kind, args[2], span + 3);
  store_item(vm, kind, at, args[2]);
  memory_done(vm, locked);
  return agc_void();
}

/* Native.get_array_of_KIND(pointer, offset, count): a List of COUNT items from OFFSET bytes past the pointer. */
static agc_value get_array(agc_vm *vm, agc_value *args, uint32_t span, item_kind kind) {
  memory_ask ask = {agc_as_int(vm, args[1]), agc_as_int(vm, args[2]), ITEM_WIDTHS[kind], span + 2, span + 3};
  bool locked;
  const uint8_t *at = memory_at(vm, args[0], ask, span, &locked);
  size_t n = (size_t)ask.count;
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&b, load_item(kind, at + k * ask.size));
  agc_list *items = agc_list_builder_finish(&b);
  memory_done(vm, locked);
  return agc_list_value(items);
}

/* Native.put_array_of_KIND(pointer, offset, list): writes the items of LIST from OFFSET bytes past the pointer. Every
   item is checked before the first is written, so a bad one leaves the memory as it was. */
static agc_value put_array(agc_vm *vm, agc_value *args, uint32_t span, item_kind kind) {
  const agc_list *items = agc_as_list(vm, args[2]);
  size_t n = agc_list_len(items);
  memory_ask ask = {agc_as_int(vm, args[1]), (int64_t)n, ITEM_WIDTHS[kind], span + 2, span + 3};
  bool locked;
  uint8_t *at = memory_at(vm, args[0], ask, span, &locked);
  agc_list_cursor c;
  agc_value v;
  agc_list_cursor_begin(&c, items, 0);
  while (agc_list_cursor_next(&c, &v)) check_item(vm, kind, v, span + 3);
  agc_list_cursor_begin(&c, items, 0);
  for (size_t k = 0; agc_list_cursor_next(&c, &v); k++) store_item(vm, kind, at + k * ask.size, v);
  memory_done(vm, locked);
  return agc_void();
}

/* Native.put_string(pointer, offset, text): the bytes of TEXT and a NUL after them at OFFSET bytes past the pointer,
   an owned C string; a NUL inside TEXT would cut it short for C, so it fails, as for a C.String argument. */
static agc_value builtin_put_string(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_string *text = agc_as_string(vm, args[2]);
  memory_ask ask = {agc_as_int(vm, args[1]), (int64_t)text->bytes + 1, 1, span + 2, span + 3};
  bool locked;
  uint8_t *at = memory_at(vm, args[0], ask, span, &locked);
  if (text->bytes && memchr(text->data, 0, text->bytes))
    agc_fail(vm, "RUNTIME-INVALID-CHARACTER", "the text holds a NUL character", span + 3);
  if (text->bytes) memcpy(at, text->data, text->bytes);
  at[text->bytes] = 0;
  memory_done(vm, locked);
  return agc_void();
}

static agc_value builtin_get_int8(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_one(vm, args, span, ITEM_INT8);
}
static agc_value builtin_get_int16(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_one(vm, args, span, ITEM_INT16);
}
static agc_value builtin_get_int32(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_one(vm, args, span, ITEM_INT32);
}
static agc_value builtin_get_int64(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_one(vm, args, span, ITEM_INT64);
}
static agc_value builtin_get_uint8(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_one(vm, args, span, ITEM_UINT8);
}
static agc_value builtin_get_uint16(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_one(vm, args, span, ITEM_UINT16);
}
static agc_value builtin_get_uint32(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_one(vm, args, span, ITEM_UINT32);
}
static agc_value builtin_get_float32(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_one(vm, args, span, ITEM_FLOAT32);
}
static agc_value builtin_get_float64(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_one(vm, args, span, ITEM_FLOAT64);
}
static agc_value builtin_get_pointer(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_one(vm, args, span, ITEM_POINTER);
}
static agc_value builtin_put_int8(agc_vm *vm, agc_value *args, uint32_t span) {
  return put_one(vm, args, span, ITEM_INT8);
}
static agc_value builtin_put_int16(agc_vm *vm, agc_value *args, uint32_t span) {
  return put_one(vm, args, span, ITEM_INT16);
}
static agc_value builtin_put_int32(agc_vm *vm, agc_value *args, uint32_t span) {
  return put_one(vm, args, span, ITEM_INT32);
}
static agc_value builtin_put_int64(agc_vm *vm, agc_value *args, uint32_t span) {
  return put_one(vm, args, span, ITEM_INT64);
}
static agc_value builtin_put_float32(agc_vm *vm, agc_value *args, uint32_t span) {
  return put_one(vm, args, span, ITEM_FLOAT32);
}
static agc_value builtin_put_float64(agc_vm *vm, agc_value *args, uint32_t span) {
  return put_one(vm, args, span, ITEM_FLOAT64);
}
static agc_value builtin_put_pointer(agc_vm *vm, agc_value *args, uint32_t span) {
  return put_one(vm, args, span, ITEM_POINTER);
}
static agc_value builtin_get_ints32(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_array(vm, args, span, ITEM_INT32);
}
static agc_value builtin_get_ints64(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_array(vm, args, span, ITEM_INT64);
}
static agc_value builtin_get_floats32(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_array(vm, args, span, ITEM_FLOAT32);
}
static agc_value builtin_get_floats64(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_array(vm, args, span, ITEM_FLOAT64);
}
static agc_value builtin_put_ints32(agc_vm *vm, agc_value *args, uint32_t span) {
  return put_array(vm, args, span, ITEM_INT32);
}
static agc_value builtin_put_ints64(agc_vm *vm, agc_value *args, uint32_t span) {
  return put_array(vm, args, span, ITEM_INT64);
}
static agc_value builtin_put_floats32(agc_vm *vm, agc_value *args, uint32_t span) {
  return put_array(vm, args, span, ITEM_FLOAT32);
}
static agc_value builtin_put_floats64(agc_vm *vm, agc_value *args, uint32_t span) {
  return put_array(vm, args, span, ITEM_FLOAT64);
}
/* Native.get_bytes(pointer, offset, length) and put_bytes(pointer, offset, bytes), Ruby ffi's get_bytes and put_bytes
   with a List of bytes for their String. */
static agc_value builtin_get_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return get_array(vm, args, span, ITEM_BYTE);
}
static agc_value builtin_put_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  return put_array(vm, args, span, ITEM_BYTE);
}

/* An error or a hang-up on the descriptor ends the wait as readiness does: as with poll(2), the next call of the
   native code does not block and reports the error itself (a refused connect, for example). */
static void wait_ready(void *data, int status) {
  (void)status;
  native_wait *w = data;
  agc_poller_pause(w->poller);
  agc_io_ready(w->job);
}

/* The job's START, on the I/O thread, before its deadline is armed (agc_io_start_then). */
static bool wait_begin(void *data, agc_io_job *job) {
  native_wait *w = data;
  w->job = job;
  int err = 0;
  w->poller = agc_poller_open_copy(w->vm, w->fd, &err);
  if (!w->poller) {
    /* ERR is libuv's code, negated: the errno on POSIX, mapped to one on Windows. */
    w->err = err ? agc_net_errno(-err) : EIO;
    agc_io_ready(job);
    return false;
  }
  agc_poller_wait(w->poller, w->writing, wait_ready, w);
  return true;
}

static void wait_drop(void *data) {
  native_wait *w = data;
  if (w->poller) agc_poller_close(w->poller);
  free(w);
}

static agc_value wait_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  native_wait *w = data;
  agc_value v = w->err ? agc_system_error(vm, "native: cannot wait on the descriptor", w->err)
                       : agc_result_value(true, agc_void());
  wait_drop(w);
  return v;
}

/* The deadline passed; `pause` has stopped the poll on the I/O thread already, and `drop` frees the data later. */
static agc_value wait_expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_error_value("native: timed out");
}

static void wait_pause(void *data) {
  native_wait *w = data;
  if (w->poller) agc_poller_pause(w->poller);
}

/* A cancel (or the deadline of a detached job): the poll stops and the job can be dropped. A job whose poller could
   not be made has ended already. */
static bool wait_cancel(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  (void)deadline;
  native_wait *w = data;
  if (!w->poller) return false;
  agc_poller_pause(w->poller);
  return true;
}

static const agc_io_kind wait_io = {NULL, wait_done, wait_expired, wait_drop, true, "native_wait", wait_cancel, false,
                                    wait_pause};

/* Native.wait_readable(fd, timeout_ms) and wait_writable: the task parks on a job while the I/O thread polls the
   descriptor, until it is ready (ok), the timeout passes (`native: timed out`) or the task is cancelled. A program
   that calls them is refused at load like one with extern functions (agc_ffi_refusal), so a build without native
   calls never reaches the builtin. */
static agc_value native_wait_on(agc_vm *vm, agc_value *args, uint32_t span, bool writing) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
  int64_t fd = agc_as_int(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  if (timeout <= 0) return agc_error_value("native: timeout must be positive milliseconds");
  if (fd < 0 || fd > INT_MAX) return agc_error_value("native: invalid descriptor");
  native_wait *w = malloc(sizeof *w);
  if (!w) agc_out_of_memory();
  *w = (native_wait){vm, NULL, NULL, (int)fd, 0, writing};
  agc_io_start_then(vm, &wait_io, w, agc_void(), timeout, wait_begin);
  return agc_void();
}

static agc_value builtin_wait_readable(agc_vm *vm, agc_value *args, uint32_t span) {
  return native_wait_on(vm, args, span, false);
}

static agc_value builtin_wait_writable(agc_vm *vm, agc_value *args, uint32_t span) {
  return native_wait_on(vm, args, span, true);
}

const char *agc_ffi_refusal(const agc_program *program, bool deny, const char **message, uint32_t *span) {
  if (program->native_import == UINT32_MAX) return NULL;
  *span = program->native_function == UINT32_MAX ? 0 : program->functions[program->native_function].span;
  if (!agc_ffi_supported()) {
    *message = "this program uses native code (extern functions or Native.* builtins), which is not supported on this "
               "system yet";
    return "RUNTIME-NATIVE-UNSUPPORTED";
  }
  if (deny) {
    *message = "this program uses native code (extern functions or Native.* builtins), and --deny-native (or any "
               "--deny-* flag) refuses it";
    return "RUNTIME-NATIVE-DENIED";
  }
  return NULL;
}

const agc_builtin agc_ffi_builtins[] = {
  {AGC_NATIVE_CALL, 2, builtin_native_call, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Native.close", 1, builtin_native_close, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"Native.null", 0, builtin_native_null, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.null?", 1, builtin_native_null_p, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.pointer", 1, builtin_native_pointer, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.get_string", 2, builtin_get_string, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.get_string", 3, builtin_get_string_length, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.get_bytes", 3, builtin_get_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.memory_pointer", 1, builtin_memory_pointer, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"Native.memory_pointer", 2, builtin_memory_pointer_block, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"Native.free", 1, builtin_native_free, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"Native.get_int8", 2, builtin_get_int8, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.get_int16", 2, builtin_get_int16, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.get_int32", 2, builtin_get_int32, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.get_int64", 2, builtin_get_int64, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.get_uint8", 2, builtin_get_uint8, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.get_uint16", 2, builtin_get_uint16, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.get_uint32", 2, builtin_get_uint32, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.get_float32", 2, builtin_get_float32, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.get_float64", 2, builtin_get_float64, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.get_pointer", 2, builtin_get_pointer, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.put_int8", 3, builtin_put_int8, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.put_int16", 3, builtin_put_int16, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.put_int32", 3, builtin_put_int32, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.put_int64", 3, builtin_put_int64, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.put_float32", 3, builtin_put_float32, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.put_float64", 3, builtin_put_float64, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.put_pointer", 3, builtin_put_pointer, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.put_string", 3, builtin_put_string, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.get_array_of_int32", 3, builtin_get_ints32, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.get_array_of_int64", 3, builtin_get_ints64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.get_array_of_float32", 3, builtin_get_floats32, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.get_array_of_float64", 3, builtin_get_floats64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.put_array_of_int32", 3, builtin_put_ints32, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.put_array_of_int64", 3, builtin_put_ints64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.put_array_of_float32", 3, builtin_put_floats32, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.put_array_of_float64", 3, builtin_put_floats64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.put_bytes", 3, builtin_put_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Native.wait_readable", 2, builtin_wait_readable, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Native.wait_writable", 2, builtin_wait_writable, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
};

const size_t agc_ffi_builtin_count = sizeof agc_ffi_builtins / sizeof agc_ffi_builtins[0];

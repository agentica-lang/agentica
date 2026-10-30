/*
 * Native calls (docs/grammar/06d-io-and-network.md, "Native code"): Native.call, which every extern function lowers
 * to, Native.load and agc_ffi_refusal. It prepares one call per signature, converts values both ways, and runs a fast
 * call on the scheduler and a compute call on the compute pool; dlopen and libffi are the adapter's (ffi_os.h). Also
 * the resources of extern functions (agc_c_resource) and Native.close, null, pointer and address, the owned buffers
 * and their views, the memory reads and writes (Native.get_*, put_*, size_of), Native.wait_readable and wait_writable,
 * and Native.callback, which runs a function in the task of the native call that C calls it from. Service layer.
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
/* The free word of a resource kind declared `free: C.Function`: no C name holds a dot. */
#define BY_POINTER "C.Function"
#define BY_POINTER_LEN (sizeof BY_POINTER - 1)
/* The mark in front of the free word of a resource kind declared `free_ref:`: its free function takes the address
   of the pointer (void free(void **)). No C name starts with it. */
#define BY_REF '&'
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
/* The limits of a struct of a signature: how deep it nests and how many fields it has, nested ones counted. The front
   end refuses more (PARSE-EXTERN-ARITY), so only hand-made bytecode reaches them; with at most 8 bytes per field,
   no struct within them is larger than STRUCT_MAX_SIZE, which is checked too. */
#define STRUCT_MAX_DEPTH 16
#define STRUCT_MAX_FIELDS 1024
#define STRUCT_MAX_SIZE 16384
/* The bytes a struct argument takes in the memory of a call: each starts at a multiple of 16, which no C struct of a
   signature needs more than. */
#define STRUCT_ROUND(size) (((size) + 15) & ~(size_t)15)

/* How agc_ffi_end tells a stop signal (agc_io_stop_signal, which the driver passes): nonzero once one came. */
typedef struct {
  int (*signal)(void);
} stop_check;

/* The resources and owned buffers that running compute calls hold, gathered at the end of the run (running_holds). */
typedef struct {
  const agc_c_resource **items;
  size_t count, cap;
} held_set;

/* The frees of one step of agc_ffi_end, copied out of GC memory for the thread that makes them, in order. */
typedef struct {
  agc_ffi_call *free;
  void *at, *pointer;
  bool buffer, by_ref, callback;
} end_free;

typedef struct {
  size_t count;
  end_free items[];
} end_frees;

/* A resource kind that a call makes: the prepared call of its free function (void free(void *)) and its name. A kind
   declared `free: C.Function` (by_pointer) frees through the address that the call got: its call has no symbol. A
   kind declared `free_ref:` (by_ref) gives its free function the address of the pointer instead. */
typedef struct {
  agc_ffi_call *free;
  char *name;
  bool by_pointer, by_ref;
} made_kind;

/* A prepared signature. An out parameter (out[k]) is not an argument of Native.call: C gets a pointer to a zeroed slot
   of type params[k] and writes its value there. An optional one (optional[k], an Optional of a callback) is a resource
   given as an Optional: none passes NULL. For the others, arg[k] is the index of the argument in the List of
   Native.call (`inputs` of them). For a function that returns a resource, `free` is the prepared call of the resource's
   free function (`free_by_ref` when it takes the pointer's address), `resource` the resource's name and `symbol`
   the C name of the function, which the error of a NULL result names; all three are NULL otherwise. `made` holds the
   kind of each out resource (NULL when the call has none). A function with out parameters (`outs` > 0) gives a List:
   the C result, unless Void, then each out value. `params` and the rest index the C parameters only. A call through a C
   function pointer (`by_pointer`, code c) takes the function's address as argument 0, and the free function of the
   resources it makes of a `free: C.Function` kind (`free_by_pointer` for the result's) as argument `free_input` (code
   e), -1 when it has none; neither goes to C. A struct parameter has its layout in structs[k] (NULL for the others) and
   a struct result in `result_struct`; a call copies its struct arguments into `struct_bytes` of memory (each at a
   multiple of 16), then gives the result's buffer. `holds` counts what a compute call may hold: one per C parameter,
   then one per C.Pointer field of each struct argument, in order. A `layout` entry is no signature but the layout code
   of one struct ("{N:CODES}") for Native.size_of, get_struct and put_struct: only `result_struct` is set, laid out
   without a call. */
typedef struct {
  char *key;
  size_t key_len;
  uint64_t hash;
  agc_ffi_call *call;
  agc_c_type params[AGC_FFI_MAX_PARAMS];
  bool out[AGC_FFI_MAX_PARAMS];
  bool optional[AGC_FFI_MAX_PARAMS];
  uint8_t arg[AGC_FFI_MAX_PARAMS];
  agc_c_type result;
  agc_c_struct *structs[AGC_FFI_MAX_PARAMS];
  agc_c_struct *result_struct;
  size_t struct_bytes;
  uint32_t count, inputs, outs, holds;
  bool compute, by_pointer, free_by_pointer, free_by_ref, layout;
  int32_t free_input;
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
   slots hold no result. `fn` is the address a call through a function pointer calls (else NULL) and `free_at` the free
   function of the resources it makes of a `free: C.Function` kind (else NULL). `held` has `holds` entries, the owned
   buffers in the C.Pointer fields of struct arguments after those of the parameters. `structs` (at a multiple of 16
   in the block) holds the struct arguments, copied on the scheduler, then the buffer of a struct result, which `out.p`
   points at. */
typedef struct {
  const ffi_entry *entry;
  void *fn, *free_at;
  agc_c_value *slots;
  agc_c_resource **held;
  uint8_t *structs;
  uint32_t span;
  bool ran, refused;
  _Atomic int phase;
  agc_c_value out;
  agc_c_value in[];
} compute_call;

/* The phase of a compute call: QUEUED until a pool thread takes it, then RUNNING while C runs and FINISHED after. The
   end of the run moves every queued call to ABANDONED (agc_ffi_stop_queued) and a pool thread then skips it: one CAS
   decides, so a call is either made in full or never. */
enum { CALL_QUEUED, CALL_RUNNING, CALL_FINISHED, CALL_ABANDONED };

/* The native call that runs on this thread now (current_site), which a callback that C makes runs in. A fast call sets
   it around its C call and puts back the one it found, so a call that a callback makes nests. A compute call sets one
   with no `vm` on its pool thread, where no callback can run: a callback there only sets `refused`, and C gets zero. A
   thread that C started has none, and C gets zero there too. Once a callback has failed (`failed`) every later one of
   the call gives zero at once, and the call raises the failure when C returns: the outcome that the callback's run
   kept, or CODE and MESSAGE when its value could not go back to C. */
typedef struct native_site {
  agc_vm *vm;
  uint32_t span;
  bool failed, refused;
  const char *code, *message;
  agc_outcome outcome;
  struct native_site *outer;
} native_site;

static _Thread_local native_site *current_site; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

/* What a callback runs (Native.callback): the function value, the C types of its signature and its resource. In GC
   memory, kept alive by the resource (agc_c_resource.callback) while C may call it. */
typedef struct {
  agc_c_resource *res;
  agc_value fn;
  agc_c_type result;
  agc_c_type params[AGC_FFI_MAX_PARAMS];
  uint32_t count;
} callback_data;

/* Set once the process has made a callback. From then on a fast call holds its resources, as a compute call does: a
   callback lets rt->sync go while it runs, and it, or another task, may close them while C uses them. */
static _Atomic bool callbacks_made; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

/* The callbacks closed while they ran, whose last run has ended: libffi's frames of that run were still on the stack,
   so the free waits until C has returned from the native call (free_dying). Under rt->sync; the registry keeps each
   one alive. */
static struct {
  agc_c_resource **items;
  size_t count, cap;
} dying; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

/* The free functions of a signature, in the library: the result's (index 0 when the result is a resource), then each
   out resource's, as named by the signature (without the & of a free_ref: kind, which sets by_ref). */
typedef struct {
  const char *names[AGC_FFI_MAX_PARAMS + 1];
  size_t lens[AGC_FFI_MAX_PARAMS + 1];
  const char *kinds[AGC_FFI_MAX_PARAMS + 1];
  size_t kind_lens[AGC_FFI_MAX_PARAMS + 1];
  agc_ffi_call *calls[AGC_FFI_MAX_PARAMS + 1];
  bool by_pointer[AGC_FFI_MAX_PARAMS + 1];
  bool by_ref[AGC_FFI_MAX_PARAMS + 1];
  uint32_t count;
} free_list;

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

/* The kinds of item that the typed reads and writes move: Native.get_int8 to get_pointer, put_int8 to put_pointer, and
   the array forms. ITEM_WIDTHS has the size of each. */
typedef enum {
  ITEM_INT8, ITEM_INT16, ITEM_INT32, ITEM_INT64, ITEM_UINT8, ITEM_UINT16, ITEM_UINT32, ITEM_FLOAT32, ITEM_FLOAT64,
  ITEM_POINTER
} item_kind;

/* What a memory builtin reads or writes: COUNT items of SIZE bytes at OFFSET bytes past its pointer. A bad offset
   fails at OFFSET_SPAN, and a bad count, or memory that runs past an owned buffer, at COUNT_SPAN. */
typedef struct {
  int64_t offset, count;
  size_t size;
  uint32_t offset_span, count_span;
} memory_ask;

/* The block form of Native.memory_pointer and Native.from_string: the buffer it yields, and whether the block has
   been called. */
typedef struct {
  agc_stepper stepper;
  agc_value buffer;
  bool called;
} buffer_block;

/* The prepared calls of the run, by signature string, and the struct layouts of Native.size_of, get_struct and
   put_struct, by layout code, in malloc memory (no GC pointers): open addressing over a
   power-of-two table, kept at most half full. Native.call is a shared builtin, so in a shared VM it runs with
   rt->sync held and the table needs no lock of its own. Entries live until the process ends, like the libraries. */
typedef struct agc_ffi_cache {
  ffi_entry **slots;
  size_t size, used;
} agc_ffi_cache;

static const size_t ITEM_WIDTHS[] = {1, 2, 4, 8, 1, 2, 4, sizeof(float), sizeof(double), sizeof(void *)};

static uint64_t text_hash(const char *data, size_t len) {
  uint64_t h = 1469598103934665603ULL;
  for (size_t k = 0; k < len; k++) h = (h ^ (uint8_t)data[k]) * 1099511628211ULL;
  return h;
}

/* The integer type of a code of the signature or of a struct layout: i C.Int32, l C.Int64, g C.Int8, h C.Int16,
   u C.UInt8, w C.UInt16, j C.UInt32 and n C.Long. False for any other code. */
static bool int_type_of(char code, agc_c_type *type) {
  switch (code) {
    case 'i': *type = AGC_C_INT; return true;
    case 'l': *type = AGC_C_INT64; return true;
    case 'g': *type = AGC_C_INT8; return true;
    case 'h': *type = AGC_C_INT16; return true;
    case 'u': *type = AGC_C_UINT8; return true;
    case 'w': *type = AGC_C_UINT16; return true;
    case 'j': *type = AGC_C_UINT32; return true;
    case 'n': *type = AGC_C_LONG; return true;
    default: return false;
  }
}

/* The case labels of the integer types of a signature, the types whose int_bits is not 0. */
#define INT_CASES                                                                                                     \
  case AGC_C_INT:                                                                                                     \
  case AGC_C_INT64:                                                                                                   \
  case AGC_C_INT8:                                                                                                    \
  case AGC_C_INT16:                                                                                                   \
  case AGC_C_UINT8:                                                                                                   \
  case AGC_C_UINT16:                                                                                                  \
  case AGC_C_UINT32:                                                                                                  \
  case AGC_C_LONG

/* The bits of an integer type of a signature (C.Long has the platform's: 32 on Windows, 64 elsewhere), 0 for the other
   types. */
static unsigned int_bits(agc_c_type type) {
  switch (type) {
    case AGC_C_INT8:
    case AGC_C_UINT8: return 8;
    case AGC_C_INT16:
    case AGC_C_UINT16: return 16;
    case AGC_C_INT:
    case AGC_C_UINT32: return 32;
    case AGC_C_INT64: return 64;
    case AGC_C_LONG: return (unsigned)(sizeof(long) * CHAR_BIT);
    default: return 0;
  }
}

/* The one range rule of every integer that the VM writes into C, an argument, a struct field or a memory item of
   Native.put_*: N fits in BITS read as signed or as unsigned (8 bits take -128 to 255). C then gets N's low bits, so
   -1 and 255 are the same int8_t or uint8_t, as in C. */
static bool fits_bits(int64_t n, unsigned bits) {
  return bits >= 64 || (n >= -(INT64_C(1) << (bits - 1)) && n <= (INT64_C(1) << bits) - 1);
}

/* The C integer of TYPE at AT (a value slot or a struct field), which may be unaligned: a signed type is
   sign-extended and an unsigned one zero-extended, so a C.UInt32 above 2^31 is a positive Int. */
static agc_value int_load(agc_c_type type, const void *at) {
  bool sign = type != AGC_C_UINT8 && type != AGC_C_UINT16 && type != AGC_C_UINT32;
  switch (int_bits(type)) {
    case 8: {
      int8_t s;
      uint8_t u;
      memcpy(&s, at, sizeof s);
      memcpy(&u, at, sizeof u);
      return agc_int(sign ? (int64_t)s : (int64_t)u);
    }
    case 16: {
      int16_t s;
      uint16_t u;
      memcpy(&s, at, sizeof s);
      memcpy(&u, at, sizeof u);
      return agc_int(sign ? (int64_t)s : (int64_t)u);
    }
    case 32: {
      int32_t s;
      uint32_t u;
      memcpy(&s, at, sizeof s);
      memcpy(&u, at, sizeof u);
      return agc_int(sign ? (int64_t)s : (int64_t)u);
    }
    default: {
      int64_t s;
      memcpy(&s, at, sizeof s);
      return agc_int(s);
    }
  }
}

/* Writes N, which fits_bits has checked, as the C integer of TYPE at AT, which may be unaligned: its low bits. */
static void int_store(agc_c_type type, int64_t n, void *at) {
  switch (int_bits(type)) {
    case 8: {
      uint8_t x = (uint8_t)n;
      memcpy(at, &x, sizeof x);
      break;
    }
    case 16: {
      uint16_t x = (uint16_t)n;
      memcpy(at, &x, sizeof x);
      break;
    }
    case 32: {
      uint32_t x = (uint32_t)n;
      memcpy(at, &x, sizeof x);
      break;
    }
    default: memcpy(at, &n, sizeof n); break;
  }
}

/* The C type of a code of the signature; a capital is an out parameter of that type (*OUT set), for the types that
   can be one. */
static bool c_type_of(char code, bool result, agc_c_type *type, bool *out) {
  *out = false;
  if (!result && code != '\0' && strchr("ILGHUWJNDFBPR", code)) {
    *out = true;
    code = (char)(code - 'A' + 'a');
  }
  if (int_type_of(code, type)) return true;
  switch (code) {
    case 'd': *type = AGC_C_DOUBLE; return true;
    case 'f': *type = AGC_C_FLOAT; return true;
    case 'b': *type = AGC_C_BOOL; return true;
    case 's': *type = AGC_C_STRING; return true;
    case 'p': *type = AGC_C_POINTER; return true;
    case 'r': *type = AGC_C_RESOURCE; return true;
    case 'y': *type = AGC_C_BYTES; return !result;
    case 'v': *type = AGC_C_VOID; return result;
    case '{': *type = AGC_C_STRUCT; return true;
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

/* The String of a message of the system loader, whose bytes (a path, the OS text) may not be UTF-8: those become
   U+FFFD. */
static agc_string *loader_text(const char *error) {
  return agc_utf8_decode((const uint8_t *)error, strlen(error), "\xEF\xBF\xBD", false);
}

static _Noreturn void load_failed(agc_vm *vm, const char *error, uint32_t span) {
  agc_fail_text(vm, "RUNTIME-NATIVE-LOAD", loader_text(error), span);
}

/* The length of the struct "{...}" at the start of TEXT (LEN bytes), up to its closing brace, or 0 when its braces do
   not close or nest deeper than STRUCT_MAX_DEPTH. Every layout comes through here, so no recursion over one nests
   deeper than that. */
static size_t group_length(const char *text, size_t len) {
  uint32_t depth = 0;
  for (size_t k = 0; k < len; k++) {
    if (text[k] == '{' && ++depth > STRUCT_MAX_DEPTH) return 0;
    if (text[k] == '}' && --depth == 0) return k + 1;
  }
  return 0;
}

static void struct_free(agc_c_struct *s) { // NOLINT(misc-no-recursion)
  if (!s) return;
  for (uint32_t k = 0; k < s->count; k++) struct_free(s->nested[k]);
  free(s);
}

/* The layout of the struct "{N:CODES}" at *AT, whose braces group_length has checked, before END; *AT moves past it. N
   is a struct of the program P with one field per code: an integer code (int_type_of), d, f, b, p or a nested struct.
   *LEAVES counts the fields of the whole tree, nested ones included. NULL when any part is wrong, with nothing left
   allocated. */
static agc_c_struct *struct_parse(const agc_program *p, const char **at, const char *end, uint32_t *leaves) { // NOLINT(misc-no-recursion)
  const char *c = *at + 1;
  uint32_t index = 0, digits = 0;
  for (; c < end && *c >= '0' && *c <= '9' && digits < 9; c++, digits++) index = index * 10 + (uint32_t)(*c - '0');
  if (!digits || c == end || *c != ':' || !p || index >= p->struct_count) return NULL;
  c++;
  uint32_t count = 0;
  for (const char *f = c; f < end && *f != '}'; count++) {
    size_t len = *f == '{' ? group_length(f, (size_t)(end - f)) : 1;
    if (!len) return NULL;
    f += len;
  }
  if (!count || count != p->structs[index].count) return NULL;
  agc_c_struct *s = calloc(1, sizeof *s + count * (sizeof(size_t) + sizeof(agc_c_struct *) + sizeof(agc_c_type)));
  if (!s) agc_out_of_memory();
  s->offsets = (size_t *)(void *)(s + 1);
  s->nested = (agc_c_struct **)(void *)(s->offsets + count);
  s->types = (agc_c_type *)(void *)(s->nested + count);
  s->count = count;
  s->index = index;
  bool good = true;
  for (uint32_t k = 0; k < count && good; k++) {
    agc_c_type type = AGC_C_VOID;
    switch (*c) {
      case 'd': type = AGC_C_DOUBLE; break;
      case 'f': type = AGC_C_FLOAT; break;
      case 'b': type = AGC_C_BOOL; break;
      case 'p': type = AGC_C_POINTER; break;
      case '{': type = AGC_C_STRUCT; break;
      default: (void)int_type_of(*c, &type); break;
    }
    s->types[k] = type;
    if (type == AGC_C_STRUCT) {
      s->nested[k] = struct_parse(p, &c, end, leaves);
      good = s->nested[k] != NULL;
      if (good) s->pointers += s->nested[k]->pointers;
    } else {
      good = type != AGC_C_VOID && ++*leaves <= STRUCT_MAX_FIELDS;
      s->pointers += type == AGC_C_POINTER;
      c++;
    }
  }
  if (!good || c == end || *c != '}') {
    struct_free(s);
    return NULL;
  }
  *at = c + 1;
  return s;
}

/* The layout of the struct that is exactly the LEN bytes at TEXT, or NULL. */
static agc_c_struct *layout_of(agc_vm *vm, const char *text, size_t len) {
  const char *at = text;
  uint32_t leaves = 0;
  agc_c_struct *s = struct_parse(vm->rt->program, &at, text + len, &leaves);
  if (s && at != text + len) {
    struct_free(s);
    return NULL;
  }
  return s;
}

static void discard_frees(free_list *frees) {
  for (uint32_t k = 0; k < frees->count; k++)
    if (frees->calls[k]) agc_ffi_discard(frees->calls[k]);
}

static void free_layouts(agc_c_struct *result_struct, agc_c_struct **structs, uint32_t count) {
  struct_free(result_struct);
  for (uint32_t k = 0; k < count; k++) struct_free(structs[k]);
}

/* Whether every struct of a prepared signature is at most STRUCT_MAX_SIZE bytes. */
static bool layouts_fit(const agc_c_struct *result_struct, agc_c_struct *const *structs, uint32_t count) {
  bool fit = !result_struct || result_struct->size <= STRUCT_MAX_SIZE;
  for (uint32_t k = 0; k < count; k++) fit = fit && (!structs[k] || structs[k]->size <= STRUCT_MAX_SIZE);
  return fit;
}

/* "CODES SYMBOL LIBRARY": the result code, then one code per parameter (a capital for an out parameter), a space, the C
   name, a space, and the library (which may hold spaces), with "compute " in front for a compute def. A variadic
   function has a "." among the codes where its variadic part starts, after one C parameter at least; the codes after it
   are never an out parameter, a C.Bool, a C.Float or an integer narrower than an int, which C would promote. Each
   resource the call makes adds two words after the C name, the C name of its free function and the resource's name, an
   identifier: the result's first (code r), then each out resource's (code R), in order. A free word that starts with &
   (`free_ref:`) names a function that takes the address of the pointer, void free(void **). A call through a C
   function pointer has the code c first: the argument is the address to call, and SYMBOL (the def's name) is only
   shown. The code e, only as the last code (a "." may follow), is the argument that holds the free function of each
   resource the call makes whose free word is C.Function; the call has one exactly when such a resource needs it. A
   struct passed or returned by value is one code "{N:CODES}": N is its index in the program's struct table and CODES
   has one code per field, in the struct's field order, an integer code, d, f, b, p or a nested struct; it is never an
   out parameter or after the ".". The front end writes it (compiler/lower/lower_native.agc); the bytecode may hold
   anything, so every part is checked here. */
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
  /* The codes, one item each: a letter, or a struct up to its closing brace (GROUPS has where each starts and its
     length). The "." comes out of them, after the result and one parameter at least; a second one is then an unknown
     code. BEFORE counts the parameter codes in front of it. */
  uint32_t before = UINT32_MAX, items = 0;
  char kinds[AGC_FFI_MAX_PARAMS + 1] = {0};
  const char *groups[AGC_FFI_MAX_PARAMS + 1];
  size_t group_lens[AGC_FFI_MAX_PARAMS + 1];
  for (size_t k = 0; k < codes_len;) {
    if (codes[k] == '.' && before == UINT32_MAX && items >= 2) {
      before = items - 1;
      k++;
      continue;
    }
    size_t len = codes[k] == '{' ? group_length(codes + k, codes_len - k) : 1;
    if (items == AGC_FFI_MAX_PARAMS + 1 || len == 0) bad_signature(vm, span);
    kinds[items] = codes[k];
    groups[items] = codes + k;
    group_lens[items++] = len;
    k += len;
  }
  agc_c_type result, params[AGC_FFI_MAX_PARAMS], c_params[AGC_FFI_MAX_PARAMS];
  bool out[AGC_FFI_MAX_PARAMS], optional[AGC_FFI_MAX_PARAMS] = {false}, result_out;
  uint8_t arg[AGC_FFI_MAX_PARAMS];
  /* The item of each C parameter, for the layout of a struct. */
  uint32_t item_of[AGC_FFI_MAX_PARAMS];
  if (!c_type_of(kinds[0], true, &result, &result_out)) bad_signature(vm, span);
  uint32_t total = items - 1, count = 0, outs = 0, inputs = 0, fixed = AGC_FFI_NOT_VARIADIC;
  int32_t free_input = -1;
  bool by_pointer = false;
  free_list frees;
  frees.count = 0;
  bool made = result == AGC_C_RESOURCE;
  if (made) frees.count++;
  /* COUNT is the number of C parameters so far; the c and e arguments are not passed to C. */
  for (uint32_t k = 0; k < total; k++) {
    if (k == before) fixed = count;
    char code = kinds[k + 1];
    if (code == 'c' && k == 0) {
      by_pointer = true;
      inputs++;
      continue;
    }
    if (code == 'e' && k + 1 == total && k < before) {
      free_input = (int32_t)inputs++;
      continue;
    }
    /* An Optional of a callback (code o): a resource, or none for NULL. */
    optional[count] = code == 'o';
    if (optional[count]) {
      params[count] = AGC_C_RESOURCE;
      out[count] = false;
    } else if (!c_type_of(code, false, &params[count], &out[count])) {
      bad_signature(vm, span);
    }
    bool promoted = params[count] == AGC_C_BOOL || params[count] == AGC_C_FLOAT ||
                    (int_bits(params[count]) && int_bits(params[count]) < 32);
    if (k >= before && (out[count] || promoted || params[count] == AGC_C_STRUCT)) bad_signature(vm, span);
    item_of[count] = k + 1;
    /* C gets a pointer to the slot of an out parameter. */
    c_params[count] = out[count] ? AGC_C_POINTER : params[count];
    if (!out[count]) arg[count] = (uint8_t)inputs++;
    outs += out[count];
    if (out[count] && params[count] == AGC_C_RESOURCE) frees.count++;
    count++;
  }
  if (before == total) fixed = count;
  if (before != UINT32_MAX && fixed == 0) bad_signature(vm, span);
  bool any_by_pointer = false;
  for (uint32_t k = 0; k < frees.count; k++) {
    if (!next_word(&at, &left, &frees.names[k], &frees.lens[k]) ||
        !next_word(&at, &left, &frees.kinds[k], &frees.kind_lens[k]) ||
        !identifier(frees.kinds[k], frees.kind_lens[k]))
      bad_signature(vm, span);
    frees.by_ref[k] = frees.names[k][0] == BY_REF;
    if (frees.by_ref[k]) {
      frees.names[k]++;
      frees.lens[k]--;
    }
    frees.by_pointer[k] = frees.lens[k] == BY_POINTER_LEN && memcmp(frees.names[k], BY_POINTER, BY_POINTER_LEN) == 0;
    /* A free_ref: kind is always a C name: a lone & or &C.Function is no signature of the front end. */
    if (frees.by_ref[k] && (frees.lens[k] == 0 || frees.by_pointer[k])) bad_signature(vm, span);
    any_by_pointer = any_by_pointer || frees.by_pointer[k];
    frees.calls[k] = NULL;
  }
  if (any_by_pointer != (free_input >= 0)) bad_signature(vm, span);
  /* A NUL inside a name would cut it short for the system loader: such a name opens nothing. */
  bool nul = left == 0 || memchr(at, 0, left) || memchr(symbol, 0, symbol_len);
  for (uint32_t k = 0; k < frees.count && !nul; k++) nul = memchr(frees.names[k], 0, frees.lens[k]) != NULL;
  if (nul) load_failed(vm, "a library or function name is empty or holds a NUL character", span);
  agc_c_struct *result_struct = NULL, *structs[AGC_FFI_MAX_PARAMS] = {NULL};
  bool laid_out = result != AGC_C_STRUCT || (result_struct = layout_of(vm, groups[0], group_lens[0])) != NULL;
  for (uint32_t k = 0; k < count && laid_out; k++)
    if (params[k] == AGC_C_STRUCT)
      laid_out = (structs[k] = layout_of(vm, groups[item_of[k]], group_lens[item_of[k]])) != NULL;
  if (!laid_out) {
    free_layouts(result_struct, structs, count);
    bad_signature(vm, span);
  }
  char *library = text_copy(at, left), *symbol_text = text_copy(symbol, symbol_len);
  char error[512];
  agc_ffi_call *call = agc_ffi_prepare(library, by_pointer ? NULL : symbol_text, result, c_params, count, fixed,
                                       result_struct, structs, error, sizeof error);
  if (call && !layouts_fit(result_struct, structs, count)) {
    agc_ffi_discard(call);
    free(library);
    free(symbol_text);
    free_layouts(result_struct, structs, count);
    bad_signature(vm, span);
  }
  bool prepared = call != NULL;
  for (uint32_t k = 0; k < frees.count && prepared; k++) {
    /* Each free function is in the same library, or at the address the call gets, and takes the pointer, or its
       address: void free(void *) or void free(void **), both one pointer to libffi. */
    char *free_text = frees.by_pointer[k] ? NULL : text_copy(frees.names[k], frees.lens[k]);
    const agc_c_type pointer = AGC_C_POINTER;
    frees.calls[k] = agc_ffi_prepare(library, free_text, AGC_C_VOID, &pointer, 1, AGC_FFI_NOT_VARIADIC, NULL, NULL,
                                     error, sizeof error);
    free(free_text);
    prepared = frees.calls[k] != NULL;
  }
  free(library);
  if (!prepared) {
    if (call) agc_ffi_discard(call);
    discard_frees(&frees);
    free(symbol_text);
    free_layouts(result_struct, structs, count);
    load_failed(vm, error, span);
  }
  ffi_entry *e = calloc(1, sizeof(ffi_entry));
  if (!e) agc_out_of_memory();
  e->compute = compute;
  e->by_pointer = by_pointer;
  e->free_input = free_input;
  e->call = call;
  e->result = result;
  e->count = count;
  e->outs = outs;
  memcpy(e->params, params, count * sizeof(agc_c_type));
  memcpy(e->out, out, count * sizeof(bool));
  memcpy(e->optional, optional, count * sizeof(bool));
  memcpy(e->structs, structs, count * sizeof(agc_c_struct *));
  e->result_struct = result_struct;
  e->holds = count;
  for (uint32_t k = 0; k < count; k++) {
    if (!structs[k]) continue;
    e->struct_bytes += STRUCT_ROUND(structs[k]->size);
    e->holds += structs[k]->pointers;
  }
  if (result_struct) e->struct_bytes += AGC_FFI_RESULT_SIZE(result_struct->size);
  uint32_t kind = made ? 1 : 0;
  for (uint32_t k = 0; k < count; k++) {
    if (!out[k]) {
      e->arg[k] = arg[k];
    } else if (params[k] == AGC_C_RESOURCE) {
      if (!e->made) {
        e->made = calloc(count, sizeof(made_kind));
        if (!e->made) agc_out_of_memory();
      }
      e->made[k] = (made_kind){frees.calls[kind], text_copy(frees.kinds[kind], frees.kind_lens[kind]),
                               frees.by_pointer[kind], frees.by_ref[kind]};
      kind++;
    }
  }
  e->inputs = inputs;
  if (made) {
    e->free = frees.calls[0];
    e->free_by_pointer = frees.by_pointer[0];
    e->free_by_ref = frees.by_ref[0];
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

/* The entry of the layout code TEXT, exactly one struct "{N:CODES}" (parse_signature has the codes), laid out as a
   struct argument is, at most STRUCT_MAX_SIZE bytes. Its braces go through group_length first, as a struct of a
   signature does, so the depth limit is the same. */
static ffi_entry *parse_layout(agc_vm *vm, const agc_string *text, uint32_t span) {
  bool grouped = text->bytes && text->data[0] == '{' && group_length(text->data, text->bytes) == text->bytes;
  agc_c_struct *s = grouped ? layout_of(vm, text->data, text->bytes) : NULL;
  if (s && (!agc_ffi_layout(s) || s->size > STRUCT_MAX_SIZE)) {
    struct_free(s);
    s = NULL;
  }
  if (!s) bad_signature(vm, span);
  ffi_entry *e = calloc(1, sizeof(ffi_entry));
  if (!e) agc_out_of_memory();
  e->layout = true;
  e->result_struct = s;
  return e;
}

/* The prepared signature TEXT, or with LAYOUT the layout entry of a struct, from the cache of the run. One cache holds
   both, so an entry of the other kind is bad bytecode. */
static ffi_entry *find_entry(agc_vm *vm, const agc_string *text, bool layout, uint32_t span) {
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
    if (e->hash == hash && e->key_len == text->bytes && memcmp(e->key, text->data, text->bytes) == 0) {
      if (e->layout != layout) bad_signature(vm, span);
      return e;
    }
    at = (at + 1) & (c->size - 1);
  }
  if (c->used >= FFI_MAX_CALLS) agc_fail(vm, "RUNTIME-NATIVE-LOAD", "too many native signatures in one run", span);
  ffi_entry *e = layout ? parse_layout(vm, text, span) : parse_signature(vm, text, span);
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

/* Runs FREE_CALL on the pointer in SLOT unless it is NULL: the function at AT, or the prepared one when AT is NULL. A
   void free(void *) gets the pointer; a void free(void **) (BY_REF, free_ref:) gets SLOT, where C may write NULL. */
static void free_pointer(agc_ffi_call *free_call, void *at, bool by_ref, void **slot) {
  if (!*slot) return;
  agc_c_value arg = {.p = by_ref ? (void *)slot : *slot}, unused;
  agc_ffi_invoke(free_call, at, &arg, &unused);
}

/* Frees the pointer in SLOT: an owned buffer (BUFFER) is malloc'd memory, a callback (CALLBACK) gives back its
   closure, which AT is, and a resource goes to FREE_CALL as in free_pointer. */
static void free_native(bool buffer, bool callback, agc_ffi_call *free_call, void *at, bool by_ref, void **slot) {
  if (buffer) {
    free(*slot);
  } else if (callback) {
    agc_ffi_closure_free(at);
    *slot = NULL;
  } else {
    free_pointer(free_call, at, by_ref, slot);
  }
}

/* Calls the free function of the resource, once. */
static void call_free(agc_c_resource *res) {
  res->closed = res->freed = true;
  free_native(res->buffer, res->callback != NULL, res->free, res->free_at, res->by_ref, &res->pointer);
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

static void make_end_frees(void *data) {
  end_frees *batch = data;
  for (size_t k = 0; k < batch->count; k++) {
    end_free *f = &batch->items[k];
    free_native(f->buffer, f->callback, f->free, f->at, f->by_ref, &f->pointer);
  }
}

static int newest_first(const void *a, const void *b) {
  uint64_t x = (*(agc_resource *const *)a)->id, y = (*(agc_resource *const *)b)->id;
  return x < y ? 1 : x > y ? -1 : 0;
}

static void abandon_queued(void *data, void *arg) {
  (void)arg;
  compute_call *c = data;
  int queued = CALL_QUEUED;
  (void)atomic_compare_exchange_strong(&c->phase, &queued, CALL_ABANDONED);
}

void agc_ffi_stop_queued(agc_vm *vm) { agc_io_compute_each(vm, abandon_queued, NULL); }

static void add_running_holds(void *data, void *arg) {
  const compute_call *c = data;
  held_set *set = arg;
  if (atomic_load(&c->phase) != CALL_RUNNING) return;
  for (uint32_t k = 0; k < c->entry->holds; k++) {
    if (!c->held[k]) continue;
    if (set->count == set->cap) {
      set->cap = set->cap ? agc_size_mul(set->cap, 2) : 16;
      set->items = realloc(set->items, agc_size_mul(set->cap, sizeof *set->items));
      if (!set->items) agc_out_of_memory();
    }
    set->items[set->count++] = c->held[k];
  }
}

/* What the compute calls that run now hold. A queued call never runs any more (agc_ffi_stop_queued) and a finished one
   is done with its pointers, so neither counts. */
static held_set running_holds(agc_vm *vm) {
  held_set set = {NULL, 0, 0};
  agc_io_compute_each(vm, add_running_holds, &set);
  return set;
}

static bool in_held_set(const held_set *set, const agc_c_resource *res) {
  for (size_t k = 0; k < set->count; k++)
    if (set->items[k] == res) return true;
  return false;
}

/* Whether no running compute call holds a resource or owned buffer that is still to free, or a stop signal came
   (ARG is agc_ffi_end's stop_check): then the end waits no longer. */
static bool holds_released(agc_vm *vm, void *arg) {
  const stop_check *stop = arg;
  if (stop->signal()) return true;
  held_set set = running_holds(vm);
  bool released = true;
  for (size_t k = 0; k < set.count && released; k++) released = set.items[k]->freed;
  free(set.items);
  return released;
}

/* Frees, on a thread apart and within BY, the resources and owned buffers of ITEMS (the registry, newest first) that
   are still to free, up to the first that a running compute call still holds: that one and every older one are left,
   since an older one may be what it points into (a database under its statement); *SKIPPED tells whether it stopped
   so. Each is marked freed here, before its free runs, so the end of a compute call that the loop finishes meanwhile
   (release_held, discard) does not free it again. True when every free of the step has run. A view (Native.offset)
   has no registry entry: its parent stands for it. */
static bool end_step(agc_vm *vm, agc_resource **items, size_t count, bool *skipped, uint64_t by) {
  held_set busy = running_holds(vm);
  end_frees *batch = malloc(agc_size_add(sizeof *batch, agc_size_mul(count, sizeof(end_free))));
  if (!batch) agc_out_of_memory();
  batch->count = 0;
  for (size_t k = 0; k < count; k++) {
    agc_resource *r = items[k];
    if (r->release != release_resource || !r->native) continue;
    agc_c_resource *res = r->native;
    if (res->freed) continue;
    if (in_held_set(&busy, res)) {
      *skipped = true;
      break;
    }
    /* Marked freed now: on a timeout or a failure below the free never runs, which the exit that follows does not
       mind. */
    res->closed = res->freed = true;
    batch->items[batch->count++] =
        (end_free){res->free, res->free_at, res->pointer, res->buffer, res->by_ref, res->callback != NULL};
  }
  free(busy.items);
  if (!batch->count) {
    free(batch);
    return true;
  }
  bool done = agc_io_run_aside(vm, make_end_frees, batch, by);
  if (done) free(batch);
  return done;
}

bool agc_ffi_end(agc_vm *vm, int (*stop_signal)(void)) {
  /* agc_io_flush_files, which runs first, set the deadline. */
  uint64_t by = vm->rt->flush_by;
  size_t count;
  agc_resource **items = agc_registry_copy(vm, &count);
  if (!count) return true;
  qsort(items, count, sizeof *items, newest_first);
  /* One pass, newest first, as at a task's end, after the running calls that hold a resource have returned: an older
     resource that a held one points into (a database under its statement) is never freed while C still uses it. */
  stop_check stop = {stop_signal};
  (void)agc_io_wait_for(vm, holds_released, &stop, by);
  bool skipped = false;
  bool done = end_step(vm, items, count, &skipped, by);
  /* After a stop signal what a running call holds is left on purpose: no timeout to report. */
  return done && (!skipped || stop_signal());
}

/* A resource NAME around POINTER, freed by FREE_CALL (at the address FREE_AT unless NULL; with the address of the
   pointer when BY_REF) and owned by the calling task (none for a detached compute call, whose result is dropped and so
   freed at once). A NULL pointer (an out resource that C left NULL) gives a resource that is closed already and was
   never registered: no close, owner's end or end of the run frees it, and a call that takes it is
   RUNTIME-NATIVE-CLOSED. */
static agc_value make_resource(agc_vm *vm, agc_ffi_call *free_call, void *free_at, bool by_ref, const char *name,
                               void *pointer) {
  agc_c_resource *res = agc_alloc(sizeof *res);
  res->parent = NULL;
  res->pointer = pointer;
  res->free = free_call;
  res->free_at = free_at;
  res->by_ref = by_ref;
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

/* The address that frees a resource of a kind: FREE_AT, the free function that the call got (code e), for a kind
   declared free: C.Function (BY_POINTER), else NULL, so its prepared call by name runs. */
static void *free_target(bool by_pointer, void *free_at) { return by_pointer ? free_at : NULL; }

/* The resource that a call returned, as Result ok; NULL is an error that names the function. FREE_AT is the free
   function that the call got (code e), else NULL. */
static agc_value resource_result(agc_vm *vm, const ffi_entry *e, void *pointer, void *free_at) {
  if (!pointer) {
    char message[512];
    snprintf(message, sizeof message, "%s returned NULL", e->symbol);
    return agc_error_value(message);
  }
  return agc_result_value(true, make_resource(vm, e->free, free_target(e->free_by_pointer, free_at),
                                              e->free_by_ref, e->resource, pointer));
}

/* The compute calls that held these resources are over: a resource closed meanwhile is freed by the last of them. */
static void release_held(agc_vm *vm, const ffi_entry *e, agc_c_resource **held) {
  agc_sync_assert(vm);
  for (uint32_t k = 0; k < e->holds; k++) {
    agc_c_resource *res = held[k];
    if (res && --res->jobs == 0 && res->closed && !res->freed) free_resource(vm, res);
  }
}

/* Frees the callbacks of `dying`, once C has returned from a native call: none of them runs any more. */
static void free_dying(agc_vm *vm) {
  agc_sync_assert(vm);
  for (size_t k = 0; k < dying.count; k++) free_resource(vm, dying.items[k]);
  dying.count = 0;
}

/* The owned buffer that V is, or NULL when V is a plain C.Pointer: both are a C.Pointer to the program. Anything else
   (only hand-made bytecode passes it) is a wrong tag. */
static agc_c_resource *buffer_of(agc_vm *vm, agc_value v) {
  if (agc_is(v, AGC_T_C_POINTER)) return NULL;
  agc_c_resource *res = agc_as_c_resource(vm, v);
  if (!res->buffer) agc_wrong_tag(vm);
  return res;
}

/* The buffer of Native.memory_pointer that RES shows: its parent for a view (Native.offset), else RES itself. Its
   `closed` and `jobs` stand for every view of it. */
static agc_c_resource *root_of(agc_c_resource *res) { return res && res->parent ? res->parent : res; }

/* The resource of an optional argument V (ffi_entry.optional), or NULL for none. Any other value, or an owned buffer
   in it, is a wrong tag: only hand-made bytecode passes one. */
static agc_c_resource *optional_resource(agc_vm *vm, agc_value v) {
  const agc_program *p = vm->rt->program;
  const agc_enum *o = agc_as_enum(vm, v);
  if (p->optional == UINT32_MAX || o->variant < p->optional || o->variant > p->optional + 1) agc_wrong_tag(vm);
  if (o->variant == p->optional) return NULL;
  if (o->n != 1) agc_wrong_tag(vm);
  agc_c_resource *res = agc_as_c_resource(vm, o->payload[0]);
  if (res->buffer) agc_wrong_tag(vm);
  return res;
}

/* The C pointer of a C.Pointer value: an owned buffer gives its memory. Whether a buffer is closed is checked apart. */
static void *pointer_of(agc_vm *vm, agc_value v) {
  agc_c_resource *res = buffer_of(vm, v);
  return res ? res->pointer : agc_as_c_pointer(vm, v);
}

/* Checks argument V against its C type before anything is allocated, so a failure (agc_fail longjmps) leaks
   nothing. An integer outside fits_bits of its type and a C.String with a NUL inside fail: C cannot take them, and
   cutting them short would call the function with another value. The items of a C.Bytes are checked while they are
   copied (copy_bytes), and whether a resource or an owned buffer is closed before and after that (check_open). A
   C.Float takes any Float: one outside the range of a float becomes an infinity (IEEE 754, C11 Annex F). A struct
   (LAYOUT) is a struct value of the program's type that the layout names, whose fields are checked the same way. */
static void check_argument(agc_vm *vm, agc_c_type type, const agc_c_struct *layout, agc_value v, uint32_t span) { // NOLINT(misc-no-recursion)
  switch (type) {
    INT_CASES:
      if (!fits_bits(agc_as_int(vm, v), int_bits(type)))
        agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "an integer argument does not fit in the bits of its C type", span);
      break;
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
    case AGC_C_BYTES: (void)agc_as_bytes(vm, v); break;
    /* A resource parameter takes a resource of an extern block, never an owned buffer or a view of one: only
       hand-made bytecode passes one, and held_by and c_argument read a resource as its own. */
    case AGC_C_RESOURCE:
      if (agc_as_c_resource(vm, v)->buffer) agc_wrong_tag(vm);
      break;
    case AGC_C_STRUCT: {
      const agc_struct *st = agc_as_struct(vm, v);
      if (st->type != layout->index || st->n != layout->count) agc_wrong_tag(vm);
      for (uint32_t k = 0; k < layout->count; k++)
        check_argument(vm, layout->types[k], layout->nested[k], st->fields[k], span);
      break;
    }
    case AGC_C_VOID: agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: a Void parameter", span);
  }
}

/* Writes the checked struct V into BASE at the offsets of LAYOUT. A C.Bool is the byte 0 or 1 (C's bool is one byte on
   every target with native calls) and a C.Float the float nearest the Float, as for an argument. */
static void struct_write(agc_vm *vm, const agc_c_struct *layout, agc_value v, uint8_t *base) { // NOLINT(misc-no-recursion)
  const agc_struct *st = agc_as_struct(vm, v);
  for (uint32_t k = 0; k < layout->count; k++) {
    uint8_t *at = base + layout->offsets[k];
    agc_value field = st->fields[k];
    if (int_bits(layout->types[k])) {
      int_store(layout->types[k], agc_as_int(vm, field), at);
      continue;
    }
    switch (layout->types[k]) {
      case AGC_C_DOUBLE: {
        double x = agc_as_float(vm, field);
        memcpy(at, &x, sizeof x);
        break;
      }
      case AGC_C_FLOAT: {
        float x = (float)agc_as_float(vm, field);
        memcpy(at, &x, sizeof x);
        break;
      }
      case AGC_C_BOOL: *at = agc_as_bool(vm, field) ? 1 : 0; break;
      case AGC_C_POINTER: {
        void *p = pointer_of(vm, field);
        memcpy(at, &p, sizeof p);
        break;
      }
      case AGC_C_STRUCT: struct_write(vm, layout->nested[k], field, at); break;
      default: break;
    }
  }
}

/* The struct value of the program's type that LAYOUT names, read from the C struct at BASE: a C.Bool field is read as
   the byte C wrote, as an out C.Bool is. */
static agc_value struct_value(const agc_c_struct *layout, const uint8_t *base) { // NOLINT(misc-no-recursion)
  agc_struct *st = agc_new_struct(layout->index, layout->count);
  for (uint32_t k = 0; k < layout->count; k++) {
    const uint8_t *at = base + layout->offsets[k];
    agc_value field = agc_void();
    if (int_bits(layout->types[k])) {
      st->fields[k] = int_load(layout->types[k], at);
      continue;
    }
    switch (layout->types[k]) {
      case AGC_C_DOUBLE: {
        double x;
        memcpy(&x, at, sizeof x);
        field = agc_float(x);
        break;
      }
      case AGC_C_FLOAT: {
        float x;
        memcpy(&x, at, sizeof x);
        field = agc_float(x);
        break;
      }
      case AGC_C_BOOL: field = agc_bool(*at != 0); break;
      case AGC_C_POINTER: {
        void *p;
        memcpy(&p, at, sizeof p);
        field = agc_c_pointer_value(p);
        break;
      }
      case AGC_C_STRUCT: field = struct_value(layout->nested[k], at); break;
      default: break;
    }
    st->fields[k] = field;
  }
  return agc_struct_value(st);
}

/* The C value of a checked argument. A C.String is a malloc'd copy, which the caller frees after the call
   (free_copies); a C.Bytes is BYTES, its copy made before (copy_bytes), which free_copies frees too. A struct (LAYOUT)
   is copied into MEMORY, its place in the memory of the call, and C gets a pointer to it. */
static agc_c_value c_argument(agc_vm *vm, agc_c_type type, const agc_c_struct *layout, agc_value v, uint8_t *bytes,
                              uint8_t *memory) {
  agc_c_value out = {0};
  switch (type) {
    INT_CASES: int_store(type, agc_as_int(vm, v), &out); break;
    case AGC_C_DOUBLE: out.d = agc_as_float(vm, v); break;
    /* An infinity when out of range: every target with native calls is IEEE 754 (C11 Annex F). */
    case AGC_C_FLOAT: out.f = (float)agc_as_float(vm, v); break;
    case AGC_C_BOOL: out.b = agc_as_bool(vm, v); break;
    case AGC_C_STRING: out.s = agc_cstr(agc_as_string(vm, v)); break;
    case AGC_C_POINTER: out.p = pointer_of(vm, v); break;
    case AGC_C_RESOURCE: out.p = agc_as_c_resource(vm, v)->pointer; break;
    case AGC_C_BYTES: out.p = bytes; break;
    case AGC_C_STRUCT:
      struct_write(vm, layout, v, memory);
      out.p = memory;
      break;
    case AGC_C_VOID: break;
  }
  return out;
}

/* The C value of the checked argument K of E (not an out one), as c_argument gives it; an optional one is its
   resource's pointer, or NULL for none. */
static agc_c_value entry_argument(agc_vm *vm, const ffi_entry *e, const agc_list *values, uint32_t k, uint8_t *bytes,
                                  uint8_t *memory) {
  agc_value v = agc_list_get(values, e->arg[k]);
  if (e->optional[k]) {
    const agc_c_resource *res = optional_resource(vm, v);
    return (agc_c_value){.p = res ? res->pointer : NULL};
  }
  return c_argument(vm, e->params[k], e->structs[k], v, bytes, memory);
}

/* A malloc'd copy of the Bytes argument V into *OUT. It runs without rt->sync (a Bytes is immutable) and adds the
   bytes to *DATA, which the caller charges. */
static void copy_bytes(agc_vm *vm, agc_value v, uint8_t **out, size_t *data) {
  const agc_bytes *b = agc_as_bytes(vm, v);
  uint8_t *copy = malloc(b->len ? b->len : 1);
  if (!copy) agc_out_of_memory();
  if (b->len) memcpy(copy, b->data, b->len);
  *data += b->len;
  *out = copy;
}

static void free_bytes(const ffi_entry *e, uint8_t **bytes) {
  for (uint32_t k = 0; k < e->count; k++) free(bytes[k]);
}

/* Copies the C.Bytes arguments of a call into BYTES (NULL for the other parameters); the caller has checked that
   each is a Bytes. A long copy takes long, so it runs with rt->sync dropped (a shared builtin is called with it taken
   once), and the lock is taken again before anything shared is read. The turn is charged by size. */
static void copy_byte_arguments(agc_vm *vm, const ffi_entry *e, const agc_list *values, uint8_t **bytes) {
  bool any = false;
  for (uint32_t k = 0; k < e->count; k++) {
    bytes[k] = NULL;
    any = any || (e->params[k] == AGC_C_BYTES && !e->out[k]);
  }
  if (!any) return;
  bool unlock = vm->sync_depth == 1;
  if (unlock) agc_sync_drop(vm);
  size_t data = 0;
  for (uint32_t k = 0; k < e->count; k++) {
    if (e->params[k] != AGC_C_BYTES || e->out[k]) continue;
    copy_bytes(vm, agc_list_get(values, e->arg[k]), &bytes[k], &data);
  }
  if (unlock) agc_sync_take(vm);
  agc_charge_bytes(vm, data);
}

/* The resource or owned buffer that argument K holds (a resource parameter, or a C.Pointer one given a buffer), or
   NULL. A view gives its parent: the call holds the memory through it. */
static agc_c_resource *held_by(agc_vm *vm, const ffi_entry *e, const agc_list *values, uint32_t k) {
  if (e->out[k]) return NULL;
  if (e->optional[k]) return optional_resource(vm, agc_list_get(values, e->arg[k]));
  if (e->params[k] == AGC_C_RESOURCE) return agc_as_c_resource(vm, agc_list_get(values, e->arg[k]));
  if (e->params[k] == AGC_C_POINTER) return root_of(buffer_of(vm, agc_list_get(values, e->arg[k])));
  return NULL;
}

/* Stores in HELD[*N] on the owned buffer (or NULL) of each C.Pointer field of the checked struct V (LAYOUT), nested
   ones included, in order; a compute call holds them as it holds its parameters'. */
static void struct_held(agc_vm *vm, const agc_c_struct *layout, agc_value v, agc_c_resource **held, uint32_t *n) { // NOLINT(misc-no-recursion)
  if (!layout->pointers) return;
  const agc_struct *st = agc_as_struct(vm, v);
  for (uint32_t k = 0; k < layout->count; k++) {
    if (layout->types[k] == AGC_C_POINTER) held[(*n)++] = root_of(buffer_of(vm, st->fields[k]));
    if (layout->types[k] == AGC_C_STRUCT) struct_held(vm, layout->nested[k], st->fields[k], held, n);
  }
}

/* Whether a C.Pointer field of the checked struct V (LAYOUT), nested ones included, holds an owned buffer that is
   closed. */
static bool struct_closed(agc_vm *vm, const agc_c_struct *layout, agc_value v) { // NOLINT(misc-no-recursion)
  if (!layout->pointers) return false;
  const agc_struct *st = agc_as_struct(vm, v);
  bool closed = false;
  for (uint32_t k = 0; k < layout->count && !closed; k++) {
    agc_c_resource *res = layout->types[k] == AGC_C_POINTER ? root_of(buffer_of(vm, st->fields[k])) : NULL;
    closed = (res && res->closed) ||
             (layout->types[k] == AGC_C_STRUCT && struct_closed(vm, layout->nested[k], st->fields[k]));
  }
  return closed;
}

/* A closed resource or owned buffer fails, also in a C.Pointer field of a struct: its pointer is freed, or about to
   be. Under rt->sync. The call checks once before the byte copies (BYTES NULL), so a closed resource fails first, and
   once after them, with the lock taken again, so no close comes between this check and the call; a failure then frees
   the copies. */
static void check_open(agc_vm *vm, const ffi_entry *e, const agc_list *values, uint8_t **bytes, uint32_t span) {
  for (uint32_t k = 0; k < e->count; k++) {
    agc_c_resource *res = held_by(vm, e, values, k);
    bool in_struct = e->structs[k] && struct_closed(vm, e->structs[k], agc_list_get(values, e->arg[k]));
    if ((res && res->closed) || in_struct) {
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

static agc_value result_value(agc_vm *vm, const ffi_entry *e, const agc_c_value *r, void *free_at) {
  switch (e->result) {
    INT_CASES: return int_load(e->result, r);
    case AGC_C_DOUBLE: return agc_float(r->d);
    case AGC_C_FLOAT: return agc_float(r->f);
    case AGC_C_BOOL: return agc_bool(r->b);
    case AGC_C_STRING: {
      /* The function keeps the text it returns (Agentica copies it and frees nothing); NULL reads as "". */
      const char *s = r->s ? r->s : "";
      return text_value((const uint8_t *)s, strlen(s));
    }
    case AGC_C_POINTER: return agc_c_pointer_value(r->p);
    case AGC_C_RESOURCE: return resource_result(vm, e, r->p, free_at);
    case AGC_C_STRUCT: return struct_value(e->result_struct, r->p);
    case AGC_C_BYTES:
    case AGC_C_VOID: break;
  }
  return agc_void();
}

/* The value of the out parameter K from its slot, which C wrote (or left zeroed). A C.Bool is read as the byte C
   wrote, so a slot that does not hold 0 or 1 is never read as a _Bool. */
static agc_value out_value(agc_vm *vm, const ffi_entry *e, uint32_t k, const agc_c_value *slot, void *free_at) {
  switch (e->params[k]) {
    INT_CASES: return int_load(e->params[k], slot);
    case AGC_C_DOUBLE: return agc_float(slot->d);
    case AGC_C_FLOAT: return agc_float(slot->f);
    case AGC_C_BOOL: {
      uint8_t byte;
      memcpy(&byte, slot, 1);
      return agc_bool(byte != 0);
    }
    case AGC_C_POINTER: return agc_c_pointer_value(slot->p);
    case AGC_C_RESOURCE: {
      const made_kind *kind = &e->made[k];
      return make_resource(vm, kind->free, free_target(kind->by_pointer, free_at), kind->by_ref, kind->name,
                           slot->p);
    }
    case AGC_C_STRING:
    case AGC_C_BYTES:
    case AGC_C_STRUCT:
    case AGC_C_VOID: break;
  }
  return agc_void();
}

/* The value of a call: the C result, or for a function with out parameters the List of the fields of its record (the
   C result unless Void, then each out value from its slot). FREE_AT is the free function that the call got. */
static agc_value call_value(agc_vm *vm, const ffi_entry *e, const agc_c_value *r, const agc_c_value *slots,
                            void *free_at) {
  if (!e->outs) return result_value(vm, e, r, free_at);
  agc_value items[AGC_FFI_MAX_PARAMS + 1];
  size_t n = 0;
  if (e->result != AGC_C_VOID) items[n++] = result_value(vm, e, r, free_at);
  for (uint32_t k = 0; k < e->count; k++)
    if (e->out[k]) items[n++] = out_value(vm, e, k, &slots[k], free_at);
  return agc_list_value(agc_list_from_array(items, n));
}

/* The resources that a compute call with out parameters made, when nobody takes its value (the task was cancelled):
   each pointer that is not NULL is freed here, once, and no value is made. */
static void drop_made(const ffi_entry *e, const agc_c_value *r, const agc_c_value *slots, void *free_at) {
  if (e->result == AGC_C_RESOURCE) {
    void *pointer = r->p;
    free_pointer(e->free, free_target(e->free_by_pointer, free_at), e->free_by_ref, &pointer);
  }
  for (uint32_t k = 0; k < e->count; k++) {
    if (!e->out[k] || e->params[k] != AGC_C_RESOURCE) continue;
    const made_kind *kind = &e->made[k];
    void *pointer = slots[k].p;
    free_pointer(kind->free, free_target(kind->by_pointer, free_at), kind->by_ref, &pointer);
  }
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
  int queued = CALL_QUEUED;
  if (!atomic_compare_exchange_strong(&c->phase, &queued, CALL_RUNNING)) return;
  native_site site = {.outer = current_site};
  current_site = &site;
  agc_ffi_invoke(c->entry->call, c->fn, c->in, &c->out);
  current_site = site.outer;
  c->refused = site.refused;
  if (c->entry->result == AGC_C_STRING && c->out.s) {
    size_t n = strlen(c->out.s);
    char *copy = malloc(n + 1);
    if (!copy) agc_out_of_memory();
    memcpy(copy, c->out.s, n + 1);
    c->out.s = copy;
  }
  c->ran = true;
  atomic_store(&c->phase, CALL_FINISHED);
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
  bool refused = c->refused && vm->in_turn;
  if (c->ran && (refused || (e->outs && !vm->in_turn)))
    drop_made(e, &c->out, c->slots, c->free_at);
  else if (c->ran)
    v = call_value(vm, e, &c->out, c->slots, c->free_at);
  uint32_t span = c->span;
  compute_free(c);
  /* C called a callback on the pool thread, where it gave zero: the call's result may be wrong, so the task fails. */
  if (refused)
    agc_fail(vm, "RUNTIME-NATIVE-CALLBACK", "a compute def ran a callback on the compute pool, where none can run",
             span);
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

/* The address of the C function that argument V (a C.Pointer) holds, for a call through a function pointer or a free
   function of a resource: NULL is refused, and so is an owned buffer, whose memory holds no function. Any other
   address is trusted, as a signature is: a wrong one is undefined behavior. */
static void *function_at(agc_vm *vm, agc_value v, uint32_t span) {
  if (buffer_of(vm, v))
    agc_fail(vm, "RUNTIME-NATIVE-BOUNDS", "a C.Function argument is an owned buffer, which holds no function", span);
  void *fn = agc_as_c_pointer(vm, v);
  if (!fn) agc_fail(vm, "RUNTIME-NATIVE-NULL", "a C.Function argument is NULL", span);
  return fn;
}

/* Fills HELD (e->holds entries) with what a call holds, in order: the resource or owned buffer of each parameter
   (held_by), then those in the C.Pointer fields of the struct arguments, and counts the call in the `jobs` of each. */
static void hold_arguments(agc_vm *vm, const ffi_entry *e, const agc_list *values, agc_c_resource **held) {
  uint32_t holds = e->count;
  for (uint32_t k = 0; k < e->count; k++) {
    held[k] = held_by(vm, e, values, k);
    if (e->structs[k]) struct_held(vm, e->structs[k], agc_list_get(values, e->arg[k]), held, &holds);
  }
  for (uint32_t k = 0; k < e->holds; k++)
    if (held[k]) held[k]->jobs++;
}

/* Native.call(signature, arguments): one call of an extern function, on the scheduler, or for a compute def on the
   compute pool while the task waits. The arguments are a List with one value per parameter, of the Agentica type the
   checker gave it. Every argument is checked before the first copy is made; then the C.Bytes arguments are copied,
   with rt->sync dropped (copy_byte_arguments), and the resources are checked open with the lock taken again, so none
   closes before the call. Nothing between the other copies and their free (or the start of the compute job, which
   then owns them) can fail. A shared builtin: it runs with rt->sync held, which the resources need. */
static agc_value builtin_native_call(agc_vm *vm, agc_value *args, uint32_t span) {
  /* The fuzzer runs hand-made bytecode with no_files: it must open no library. */
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
  ffi_entry *e = find_entry(vm, agc_as_string(vm, args[0]), false, span);
  const agc_list *values = agc_as_list(vm, args[1]);
  if (agc_list_len(values) != e->inputs)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: wrong number of native arguments", span);
  void *fn = e->by_pointer ? function_at(vm, agc_list_get(values, 0), span) : NULL;
  void *free_at = e->free_input >= 0 ? function_at(vm, agc_list_get(values, (size_t)e->free_input), span) : NULL;
  for (uint32_t k = 0; k < e->count; k++) {
    if (e->optional[k])
      (void)optional_resource(vm, agc_list_get(values, e->arg[k]));
    else if (!e->out[k])
      check_argument(vm, e->params[k], e->structs[k], agc_list_get(values, e->arg[k]), span);
  }
  /* A compute call parks, which a callback cannot (agc_task_parking): refused before the copies exist. */
  if (e->compute && vm->task->callbacks)
    agc_fail(vm, "RUNTIME-NATIVE-CALLBACK", "a callback of native code cannot wait for a compute call", span);
  /* The loop is made first: a loop that cannot start fails here, before the copies exist. */
  if (e->compute) (void)agc_io_loop(vm);
  check_open(vm, e, values, NULL, span);
  uint8_t *bytes[AGC_FFI_MAX_PARAMS];
  copy_byte_arguments(vm, e, values, bytes);
  check_open(vm, e, values, bytes, span);
  agc_charge(vm, FFI_CALL_COST);
  /* The struct arguments are copied in proportion to their size. */
  agc_charge_bytes(vm, e->struct_bytes);
  if (e->compute) {
    /* in, then the slots, then held, then the structs at a multiple of 16: one block (malloc aligns it for any C
       object). */
    size_t in_size = agc_size_mul(agc_size_mul(e->count, 2), sizeof(agc_c_value));
    size_t held_size = agc_size_mul(e->holds, sizeof(agc_c_resource *));
    size_t structs_at = STRUCT_ROUND(agc_size_add(agc_size_add(sizeof(compute_call), in_size), held_size));
    compute_call *c = malloc(agc_size_add(structs_at, e->struct_bytes));
    if (!c) agc_out_of_memory();
    c->entry = e;
    c->fn = fn;
    c->free_at = free_at;
    c->slots = c->in + e->count;
    c->held = (agc_c_resource **)(void *)(c->slots + e->count);
    c->structs = (uint8_t *)c + structs_at;
    c->ran = false;
    atomic_init(&c->phase, CALL_QUEUED);
    memset(&c->out, 0, sizeof c->out);
    memset(c->structs, 0, e->struct_bytes);
    c->span = span;
    c->refused = false;
    size_t used = 0;
    for (uint32_t k = 0; k < e->count; k++) {
      memset(&c->slots[k], 0, sizeof c->slots[k]);
      if (e->out[k]) {
        c->in[k].p = &c->slots[k];
        continue;
      }
      uint8_t *memory = e->structs[k] ? c->structs + used : NULL;
      c->in[k] = entry_argument(vm, e, values, k, bytes[k], memory);
      if (e->structs[k]) used += STRUCT_ROUND(e->structs[k]->size);
    }
    hold_arguments(vm, e, values, c->held);
    if (e->result_struct) c->out.p = c->structs + used;
    agc_io_compute(vm, &compute_io, c);
    return agc_void();
  }
  agc_c_value in[AGC_FFI_MAX_PARAMS], slots[AGC_FFI_MAX_PARAMS];
  /* The memory of the struct arguments and of a struct result; zeroed, so padding bytes hold no old data. */
  uint8_t *structs = e->struct_bytes ? calloc(1, e->struct_bytes) : NULL;
  if (e->struct_bytes && !structs) agc_out_of_memory();
  size_t used = 0;
  for (uint32_t k = 0; k < e->count; k++) {
    if (e->out[k]) {
      memset(&slots[k], 0, sizeof slots[k]);
      in[k].p = &slots[k];
    } else {
      uint8_t *memory = e->structs[k] ? structs + used : NULL;
      in[k] = entry_argument(vm, e, values, k, bytes[k], memory);
      if (e->structs[k]) used += STRUCT_ROUND(e->structs[k]->size);
    }
  }
  agc_c_value out = {0};
  if (e->result_struct) out.p = structs + used;
  agc_c_resource **held = NULL;
  if (e->holds && atomic_load_explicit(&callbacks_made, memory_order_relaxed)) {
    held = malloc(agc_size_mul(e->holds, sizeof *held));
    if (!held) agc_out_of_memory();
    hold_arguments(vm, e, values, held);
  }
  native_site site = {.vm = vm, .span = span, .outer = current_site};
  current_site = &site;
  agc_ffi_invoke(e->call, fn, in, &out);
  current_site = site.outer;
  if (held) {
    release_held(vm, e, held);
    free(held);
  }
  if (dying.count) free_dying(vm);
  free_copies(e, in);
  if (site.failed) {
    /* The call fails as the callback did: what it made is freed and no value is made. */
    drop_made(e, &out, slots, free_at);
    free(structs);
    if (site.code) agc_fail(vm, site.code, site.message, span);
    agc_raise(vm, &site.outcome);
  }
  agc_value v = call_value(vm, e, &out, slots, free_at);
  free(structs);
  return v;
}

/* Native.close(resource): see close_resource. A view has no owner to close it; only hand-made bytecode passes one. */
static agc_value builtin_native_close(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_c_resource *res = agc_as_c_resource(vm, args[0]);
  if (res->parent) agc_wrong_tag(vm);
  close_resource(vm, res);
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

/* Whether the resource or owned buffer RES (for a view, its parent) is closed, read under rt->sync, which the caller
   does not hold. */
static bool buffer_closed(agc_vm *vm, agc_c_resource *res) {
  agc_sync_take(vm);
  bool closed = root_of(res)->closed;
  agc_sync_drop(vm);
  return closed;
}

/* Native.closed?(value): true when the program can no longer use VALUE: a resource closed by Native.close or by the
   end of the task that owned it, an out resource that C left NULL (closed from the start), and an owned buffer that
   Native.free or its owner's end freed. A live resource or buffer is false, and so is a C.Pointer of C, NULL included:
   it is not the program's to close (Native.null? tests NULL). A resource closed while a compute call still holds it is
   true at once, though its free waits for the call. `closed` only ever goes from false to true, under rt->sync
   (close_resource), so the read takes rt->sync as memory_at does; the row stays a leaf, since it takes and drops the
   lock itself and does nothing else. A view is closed when its parent is. */
static agc_value builtin_native_closed_p(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  if (agc_is(args[0], AGC_T_C_POINTER)) return agc_bool(false);
  return agc_bool(buffer_closed(vm, agc_as_c_resource(vm, args[0])));
}

/* Native.pointer(address): the C.Pointer with this integer value, such as SQLITE_TRANSIENT, (void *)-1. */
static agc_value builtin_native_pointer(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_c_pointer_value((void *)(intptr_t)agc_as_int(vm, args[0]));
}

/* Native.address(pointer), the inverse of Native.pointer: the integer value of the pointer, for a difference of two
   pointers into one block, a comparison with a sentinel or a log line. A freed buffer is RUNTIME-NATIVE-CLOSED: its
   address may already be another block's. */
static agc_value builtin_native_address(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_c_resource *res = buffer_of(vm, args[0]);
  if (res && buffer_closed(vm, res)) agc_fail(vm, "RUNTIME-NATIVE-CLOSED", "the owned buffer is freed", span + 1);
  return agc_int((int64_t)(intptr_t)(res ? res->pointer : agc_as_c_pointer(vm, args[0])));
}

/* Native.offset(pointer, n): the pointer N bytes further. A C pointer gives the plain sum, wrapping as an address
   does; C vouches for it, as for any pointer it gives. An owned buffer gives a view: the same memory from byte N to the
   buffer's end (N from 0 to its size, else RUNTIME-NATIVE-BOUNDS), with the bounds checks of a buffer. The view keeps
   its parent (the buffer of Native.memory_pointer, also for a view of a view), which owns the memory: the parent's
   free closes the view, a compute call that takes the view holds the parent (held_by), and Native.free of a view is
   RUNTIME-NATIVE-NOT-OWNED. The view is allocated first, so a failure after it leaves only garbage; its pointer is
   computed after the check, and a parent freed later fails every use of the view before the pointer is read. */
static agc_value builtin_native_offset(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_c_resource *res = buffer_of(vm, args[0]);
  int64_t n = agc_as_int(vm, args[1]);
  if (!res) return agc_c_pointer_value((void *)((uintptr_t)agc_as_c_pointer(vm, args[0]) + (uintptr_t)n));
  agc_c_resource *view = agc_alloc(sizeof *view);
  if (buffer_closed(vm, res)) agc_fail(vm, "RUNTIME-NATIVE-CLOSED", "the owned buffer is freed", span + 1);
  if (n < 0 || (uint64_t)n > res->size)
    agc_fail(vm, "RUNTIME-NATIVE-BOUNDS", "the offset is outside the owned buffer", span + 2);
  view->parent = root_of(res);
  view->state = NULL;
  view->pointer = (uint8_t *)res->pointer + n;
  view->free = NULL;
  view->free_at = NULL;
  view->by_ref = false;
  view->name = BUFFER_NAME;
  view->size = res->size - (size_t)n;
  view->jobs = 0;
  view->closed = view->freed = false;
  view->buffer = true;
  return agc_c_resource_value(view);
}

/* A new owned buffer of SIZE zeroed bytes (calloc), which the calling task owns like a resource: Native.free, the
   owner's end or the end of the run frees it. The program sees a C.Pointer. The fuzzer's hand-made bytecode (no_files)
   may not make one, as it may not call: each caller checks no_files before it reads its argument. A bad size fails
   at SIZE_SPAN. */
static agc_value new_buffer(agc_vm *vm, int64_t size, uint32_t size_span) {
  if (size < 0) agc_fail(vm, "RUNTIME-INVALID-COUNT", "size must be nonnegative", size_span);
  /* The GC struct first: a failed allocation then leaks no memory of calloc. A size the system cannot give is the
     program's error, not the VM's out of memory. */
  agc_c_resource *res = agc_alloc(sizeof *res);
  res->parent = NULL;
  void *memory = (uint64_t)size <= BUFFER_MAX && (uint64_t)size < SIZE_MAX ? calloc(size ? (size_t)size : 1, 1) : NULL;
  if (!memory) agc_fail(vm, "RUNTIME-INVALID-COUNT", "the system cannot give a buffer of this size", size_span);
  /* Zeroing the memory grows with the size, as the copy of a C.String argument does. */
  agc_charge_bytes(vm, (size_t)size);
  res->pointer = memory;
  res->free = NULL;
  res->free_at = NULL;
  res->by_ref = false;
  res->name = BUFFER_NAME;
  res->size = (size_t)size;
  res->jobs = 0;
  res->closed = res->freed = false;
  res->buffer = true;
  res->state = agc_register(vm, res, release_resource);
  agc_own(vm, res->state, close_owned);
  return agc_c_resource_value(res);
}

/* Native.memory_pointer(size): a new owned buffer of SIZE zeroed bytes (new_buffer). */
static agc_value builtin_memory_pointer(agc_vm *vm, agc_value *args, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
  return new_buffer(vm, agc_as_int(vm, args[0]), span + 1);
}

/* Native.from_string(text), Ruby ffi's MemoryPointer.from_string: a new owned buffer of the text's UTF-8 bytes and a
   trailing NUL (new_buffer zeroes it), so its size is text.bytesize + 1. A NUL inside the text is copied like any
   byte: C that takes the length reads it all, which a C.String cannot give. A String lies in memory, so bytes + 1
   fits an int64_t; a size the system cannot give is new_buffer's to refuse (its BUFFER_MAX and SIZE_MAX check). */
static agc_value builtin_from_string(agc_vm *vm, agc_value *args, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
  const agc_string *text = agc_as_string(vm, args[0]);
  agc_value buffer = new_buffer(vm, (int64_t)text->bytes + 1, span + 1);
  if (text->bytes) memcpy(agc_as_c_resource(vm, buffer)->pointer, text->data, text->bytes);
  return buffer;
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

/* Yields BUFFER, a new owned buffer, to the block (the last argument) and frees it when the block ends. */
static agc_value buffer_for_block(agc_vm *vm, agc_value buffer) {
  buffer_block *b = agc_alloc(sizeof *b);
  b->buffer = buffer;
  b->stepper.step = buffer_block_step;
  agc_task_stepper(vm, &b->stepper);
  return agc_void();
}

/* Native.memory_pointer(size) do |buf| ... end, Ruby ffi's MemoryPointer.new(size) { |p| ... }: a new owned buffer
   for the block, freed when the block ends; the call returns the block's value. */
static agc_value builtin_memory_pointer_block(agc_vm *vm, agc_value *args, uint32_t span) {
  return buffer_for_block(vm, builtin_memory_pointer(vm, args, span));
}

/* Native.from_string(text) do |buf| ... end: the buffer of Native.from_string for the block, as above. */
static agc_value builtin_from_string_block(agc_vm *vm, agc_value *args, uint32_t span) {
  return buffer_for_block(vm, builtin_from_string(vm, args, span));
}

/* Native.free(pointer): frees an owned buffer once, as Native.close frees a resource; a C.Pointer that C gave is not
   the program's to free, and neither is a view (Native.offset), whose parent owns the memory. */
static agc_value builtin_native_free(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_c_resource *res = buffer_of(vm, args[0]);
  if (!res || res->parent)
    agc_fail(vm, "RUNTIME-NATIVE-NOT-OWNED", "Native.free takes a buffer of Native.memory_pointer", span + 1);
  close_resource(vm, res);
  return agc_void();
}

/* The address of what a memory builtin reads or writes (ASK) at the pointer P, its first argument (span + 1). The
   fuzzer's hand-made bytecode (no_files) may not touch memory, as it may not call. An owned buffer knows its size: a
   freed one is RUNTIME-NATIVE-CLOSED, and any byte before or past it RUNTIME-NATIVE-BOUNDS, so nothing outside it is
   ever read or written; a view (Native.offset) has the size from its offset to its parent's end, and is freed when
   the parent is. A C.Pointer of C has no size: NULL fails unless nothing is asked for (a count of 0, the C way
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
  if (res && root_of(res)->closed) agc_fail(vm, "RUNTIME-NATIVE-CLOSED", "the owned buffer is freed", span + 1);
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
    case ITEM_UINT8: { uint8_t x; memcpy(&x, at, sizeof x); return agc_int(x); }
    case ITEM_UINT16: { uint16_t x; memcpy(&x, at, sizeof x); return agc_int(x); }
    case ITEM_UINT32: { uint32_t x; memcpy(&x, at, sizeof x); return agc_int(x); }
    case ITEM_FLOAT32: { float x; memcpy(&x, at, sizeof x); return agc_float(x); }
    case ITEM_FLOAT64: { double x; memcpy(&x, at, sizeof x); return agc_float(x); }
    case ITEM_POINTER: { void *x; memcpy(&x, at, sizeof x); return agc_c_pointer_value(x); }
  }
  return agc_void();
}

/* Checks V before an item of KIND is written: an Int that fits in the item's bits read as signed or as unsigned (an
   int8 takes -128 to 255, the same bits), a Float (a float32 takes any, one outside the range of a float becomes an
   infinity), or a C.Pointer (an owned buffer, unless freed, gives its address). */
static void check_item(agc_vm *vm, item_kind kind, agc_value v, uint32_t span) {
  if (kind == ITEM_FLOAT32 || kind == ITEM_FLOAT64) {
    (void)agc_as_float(vm, v);
  } else if (kind == ITEM_POINTER) {
    agc_c_resource *res = buffer_of(vm, v);
    if (!res) (void)agc_as_c_pointer(vm, v);
    if (res && root_of(res)->closed) agc_fail(vm, "RUNTIME-NATIVE-CLOSED", "the owned buffer is freed", span);
  } else if (!fits_bits(agc_as_int(vm, v), (unsigned)ITEM_WIDTHS[kind] * 8)) {
    agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "the value does not fit in the memory item", span);
  }
}

/* Writes the checked V as the item of KIND at AT, which may be unaligned. An Int keeps its low bits, so 255 and -1 give
   one int8. */
static void store_item(agc_vm *vm, item_kind kind, uint8_t *at, agc_value v) {
  switch (kind) {
    case ITEM_INT8:
    case ITEM_UINT8: { uint8_t x = (uint8_t)agc_as_int(vm, v); memcpy(at, &x, sizeof x); break; }
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

/* The layout of the C struct that the layout code TEXT names ("{N:CODES}", compiler/lower/lower_native.agc), laid out
   as a struct argument is. The struct rows are shared: the cache is read and grown under rt->sync. */
static const agc_c_struct *struct_layout(agc_vm *vm, agc_value text, uint32_t span) {
  return find_entry(vm, agc_as_string(vm, text), true, span)->result_struct;
}

/* Native.size_of(Struct), Ruby ffi's Struct.size: the bytes of the C struct, its tail padding included, so element k
   of an array of them is at k times the size. */
static agc_value builtin_size_of(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_int((int64_t)struct_layout(vm, args[0], span + 1)->size);
}

/* Native.get_struct(pointer, offset, Struct), Ruby ffi's Struct.new(pointer): the struct value read from the C struct
   at OFFSET bytes past the pointer, as a struct result is read, with the bounds of get_int32. */
static agc_value builtin_get_struct(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_c_struct *layout = struct_layout(vm, args[2], span + 3);
  memory_ask ask = {agc_as_int(vm, args[1]), 1, layout->size, span + 2, span + 2};
  bool locked;
  const uint8_t *at = memory_at(vm, args[0], ask, span, &locked);
  agc_value v = struct_value(layout, at);
  memory_done(vm, locked);
  return v;
}

/* Native.put_struct(pointer, offset, value): writes VALUE as its C struct (the layout code is the fourth argument,
   which the front end adds) at OFFSET bytes past the pointer, as a struct argument is written. The fields are checked
   first, so a bad one leaves the memory as it was; a freed buffer in a C.Pointer field fails like a freed buffer that
   put_pointer stores, and a live one is stored as an untracked address. The row is shared, so no free comes between
   the check and the write. */
static agc_value builtin_put_struct(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_c_struct *layout = struct_layout(vm, args[3], span + 4);
  memory_ask ask = {agc_as_int(vm, args[1]), 1, layout->size, span + 2, span + 2};
  bool locked;
  uint8_t *at = memory_at(vm, args[0], ask, span, &locked);
  check_argument(vm, AGC_C_STRUCT, layout, args[2], span + 3);
  if (struct_closed(vm, layout, args[2])) agc_fail(vm, "RUNTIME-NATIVE-CLOSED", "the owned buffer is freed", span + 3);
  struct_write(vm, layout, args[2], at);
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
   with a Bytes for their String. */
static agc_value builtin_get_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  memory_ask ask = {agc_as_int(vm, args[1]), agc_as_int(vm, args[2]), 1, span + 2, span + 3};
  bool locked;
  const uint8_t *at = memory_at(vm, args[0], ask, span, &locked);
  /* NULL with length 0 is the empty Bytes: agc_make_bytes reads nothing for no bytes. */
  agc_value v = agc_bytes_value(agc_make_bytes(at, (size_t)ask.count));
  memory_done(vm, locked);
  return v;
}
static agc_value builtin_put_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  size_t n;
  const uint8_t *data = agc_bytes_data(vm, args[2], &n);
  memory_ask ask = {agc_as_int(vm, args[1]), (int64_t)n, 1, span + 2, span + 3};
  bool locked;
  uint8_t *at = memory_at(vm, args[0], ask, span, &locked);
  /* memmove: a raw C.Pointer may name any address, the data of this Bytes included. */
  if (n) memmove(at, data, n);
  memory_done(vm, locked);
  return agc_void();
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

/* Native.load(library): opens the library that the front end resolved like the one of an extern block, so a program
   can handle a missing one (error with the loader's text) before its first call. The library stays open
   (agc_ffi_open), and the calls prepared later find it loaded; a missing function is still RUNTIME-NATIVE-LOAD at its
   call. Refused at load like any Native.* builtin (agc_ffi_refusal). */
static agc_value builtin_native_load(agc_vm *vm, agc_value *args, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
  char *library = agc_cstr(agc_as_string(vm, args[0]));
  /* The error has the "native: " prefix of the other Native.* results, then the loader's message. */
  char error[512] = "native: ";
  size_t prefix = strlen(error);
  bool opened = false;
  if (!library || !*library) {
    snprintf(error + prefix, sizeof error - prefix, "cannot open the library: its name is empty or holds a NUL");
  } else {
    opened = agc_ffi_open(library, error + prefix, sizeof error - prefix);
  }
  free(library);
  agc_charge(vm, FFI_CALL_COST);
  if (opened) return agc_result_value(true, agc_void());
  return agc_result_value(false, agc_string_value(loader_text(error)));
}

/* Keeps the failure CODE and MESSAGE of a callback whose value cannot go back to C, for the native call to raise once C
   has returned: nothing can jump out while C's frames are on the stack. */
static void site_fail(native_site *site, const char *code, const char *message) {
  site->failed = true;
  site->code = code;
  site->message = message;
}

/* The Agentica value of a callback's argument of TYPE: a C.String is copied, and NULL reads as "", as for a result. */
static agc_value callback_argument(agc_c_type type, const agc_c_value *v) {
  switch (type) {
    INT_CASES: return int_load(type, v);
    case AGC_C_DOUBLE: return agc_float(v->d);
    case AGC_C_FLOAT: return agc_float(v->f);
    case AGC_C_BOOL: return agc_bool(v->b);
    case AGC_C_STRING: {
      const char *s = v->s ? v->s : "";
      return text_value((const uint8_t *)s, strlen(s));
    }
    default: return agc_c_pointer_value(v->p);
  }
}

/* Writes V, the value of a callback's function, as its C result of TYPE. The checker gave the function the Agentica
   type, so only hand-made bytecode returns another tag (RUNTIME-INTERNAL); an integer outside fits_bits is
   RUNTIME-INTEGER-OVERFLOW, as for an argument, and a closed owned buffer RUNTIME-NATIVE-CLOSED. The tags are tested
   first, so no accessor fails here. */
static void callback_result(native_site *site, agc_c_type type, agc_value v, agc_c_value *out) {
  agc_vm *vm = site->vm;
  switch (type) {
    INT_CASES:
      if (!agc_is(v, AGC_T_INT)) break;
      if (!fits_bits(agc_as_int(vm, v), int_bits(type))) {
        site_fail(site, "RUNTIME-INTEGER-OVERFLOW", "a callback's result does not fit in the bits of its C type");
        return;
      }
      int_store(type, agc_as_int(vm, v), out);
      return;
    case AGC_C_DOUBLE:
      if (!agc_is(v, AGC_T_FLOAT)) break;
      out->d = agc_as_float(vm, v);
      return;
    case AGC_C_FLOAT:
      if (!agc_is(v, AGC_T_FLOAT)) break;
      out->f = (float)agc_as_float(vm, v);
      return;
    case AGC_C_BOOL:
      if (!agc_is(v, AGC_T_BOOL)) break;
      out->b = agc_as_bool(vm, v);
      return;
    case AGC_C_POINTER: {
      if (agc_is(v, AGC_T_C_POINTER)) {
        out->p = agc_as_c_pointer(vm, v);
        return;
      }
      if (!agc_is(v, AGC_T_C_RESOURCE) || !agc_as_c_resource(vm, v)->buffer) break;
      agc_c_resource *res = agc_as_c_resource(vm, v);
      if (root_of(res)->closed) {
        site_fail(site, "RUNTIME-NATIVE-CLOSED", "a callback returned an owned buffer that is closed");
        return;
      }
      out->p = res->pointer;
      return;
    }
    case AGC_C_VOID: return;
    default: break;
  }
  site_fail(site, "RUNTIME-INTERNAL", "invalid bytecode: a callback returned a value of another type");
}

/* Queues the free of a callback that was closed while it ran, now that its last run is over (`dying`). */
static void dying_add(agc_c_resource *res) {
  if (dying.count == dying.cap) {
    dying.cap = dying.cap ? agc_size_mul(dying.cap, 2) : 8;
    dying.items = realloc(dying.items, agc_size_mul(dying.cap, sizeof *dying.items));
    if (!dying.items) agc_out_of_memory();
  }
  dying.items[dying.count++] = res;
}

/* What C runs when it calls a callback (agc_ffi_handler): the function runs in the task of the native call on this
   thread (native_site), and its value goes back to C. C gets zero when no call can run it, the callback is closed or
   one of the call's callbacks has failed already. The native call holds rt->sync here (a shared builtin), which the
   run lets go and takes again. The run counts in the resource's `jobs`, so a close meanwhile, by the callback or by
   another task, leaves the closure to the end of the last run, and its free to the native call (dying_add). */
static void callback_entry(void *data, const agc_c_value *args, agc_c_value *result) {
  const callback_data *cb = data;
  native_site *site = current_site;
  if (!site || site->failed) return;
  if (!site->vm) {
    site->refused = true;
    return;
  }
  agc_c_resource *res = cb->res;
  if (res->closed) return;
  agc_value values[AGC_FFI_MAX_PARAMS];
  for (uint32_t k = 0; k < cb->count; k++) values[k] = callback_argument(cb->params[k], &args[k]);
  agc_value got;
  res->jobs++;
  bool ran = agc_task_run_nested(site->vm, cb->fn, values, cb->count, site->span, &got, &site->outcome);
  if (--res->jobs == 0 && res->closed && !res->freed) dying_add(res);
  if (!ran) {
    site->failed = true;
    return;
  }
  callback_result(site, cb->result, got, result);
}

/* The C types that a callback takes and returns (compiler/syntax/parser.agc, CALLBACK_PARAM_CODES and
   CALLBACK_RESULT_CODES): the integers, C.Double, C.Float, C.Bool, C.Pointer, C.String as a parameter and Void as the
   result. */
static bool callback_type(agc_c_type type, bool result) {
  switch (type) {
    INT_CASES:
    case AGC_C_DOUBLE:
    case AGC_C_FLOAT:
    case AGC_C_BOOL:
    case AGC_C_POINTER: return true;
    case AGC_C_STRING: return !result;
    case AGC_C_VOID: return result;
    default: return false;
  }
}

/* Native.callback(signature, function): a callback of an extern block that runs FUNCTION, a resource that the calling
   task owns, whose pointer is the code that C calls. The signature is "CODES NAME" (compiler/lower/lower_native.agc),
   the result's code first. The front end checked that the function takes and returns the Agentica types of the codes;
   the VM checks the codes and the number of parameters, so hand-made bytecode cannot make the closure read past them.
   A shared builtin: the resource joins the registry. */
static agc_value builtin_native_callback(agc_vm *vm, agc_value *args, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-NATIVE-DENIED", "native calls are off in this run", span);
  const agc_string *text = agc_as_string(vm, args[0]);
  const agc_fn *fn = agc_as_fn(vm, args[1]);
  const char *at = text->data, *codes;
  size_t left = text->bytes, codes_len;
  if (!next_word(&at, &left, &codes, &codes_len) || codes_len > AGC_FFI_MAX_PARAMS + 1 || !identifier(at, left))
    bad_signature(vm, span);
  callback_data *cb = agc_alloc(sizeof *cb);
  bool out;
  if (!c_type_of(codes[0], true, &cb->result, &out) || !callback_type(cb->result, true)) bad_signature(vm, span);
  cb->count = (uint32_t)codes_len - 1;
  for (uint32_t k = 0; k < cb->count; k++)
    if (!c_type_of(codes[k + 1], false, &cb->params[k], &out) || out || !callback_type(cb->params[k], false))
      bad_signature(vm, span);
  const agc_program *p = vm->rt->program;
  if (fn->function >= p->function_count || p->functions[fn->function].params != cb->count ||
      p->functions[fn->function].captures != fn->n)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: the function of a callback does not take its parameters", span);
  cb->fn = args[1];
  char *name = agc_alloc_atomic(left + 1);
  memcpy(name, at, left);
  name[left] = '\0';
  char error[256];
  agc_ffi_closure *closure =
      agc_ffi_closure_new(cb->result, cb->params, cb->count, callback_entry, cb, error, sizeof error);
  if (!closure) agc_fail_text(vm, "RUNTIME-NATIVE-CALLBACK", loader_text(error), span);
  agc_c_resource *res = agc_alloc(sizeof *res);
  res->pointer = agc_ffi_closure_code(closure);
  res->free_at = closure;
  res->callback = cb;
  cb->res = res;
  res->name = name;
  res->state = agc_register(vm, res, release_resource);
  agc_own(vm, res->state, close_owned);
  atomic_store_explicit(&callbacks_made, true, memory_order_relaxed);
  agc_charge(vm, FFI_CALL_COST);
  return agc_c_resource_value(res);
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
  {AGC_NATIVE_CALL, 2, builtin_native_call, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"Native.close", 1, builtin_native_close, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Native.null", 0, builtin_native_null, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.null?", 1, builtin_native_null_p, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.closed?", 1, builtin_native_closed_p, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false},
  {"Native.pointer", 1, builtin_native_pointer, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.address", 1, builtin_native_address, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.offset", 2, builtin_native_offset, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.get_string", 2, builtin_get_string, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.get_string", 3, builtin_get_string_length, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.get_bytes.bytes", 3, builtin_get_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.memory_pointer", 1, builtin_memory_pointer, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Native.memory_pointer", 2, builtin_memory_pointer_block, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Native.from_string", 1, builtin_from_string, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Native.from_string", 2, builtin_from_string_block, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Native.free", 1, builtin_native_free, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Native.get_int8", 2, builtin_get_int8, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.get_int16", 2, builtin_get_int16, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.get_int32", 2, builtin_get_int32, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.get_int64", 2, builtin_get_int64, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.get_uint8", 2, builtin_get_uint8, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.get_uint16", 2, builtin_get_uint16, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.get_uint32", 2, builtin_get_uint32, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.get_float32", 2, builtin_get_float32, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.get_float64", 2, builtin_get_float64, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.get_pointer", 2, builtin_get_pointer, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.put_int8", 3, builtin_put_int8, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.put_int16", 3, builtin_put_int16, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.put_int32", 3, builtin_put_int32, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.put_int64", 3, builtin_put_int64, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.put_float32", 3, builtin_put_float32, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.put_float64", 3, builtin_put_float64, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.put_pointer", 3, builtin_put_pointer, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.put_string", 3, builtin_put_string, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.get_array_of_int32", 3, builtin_get_ints32, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.get_array_of_int64", 3, builtin_get_ints64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.get_array_of_float32", 3, builtin_get_floats32, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.get_array_of_float64", 3, builtin_get_floats64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.put_array_of_int32", 3, builtin_put_ints32, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.put_array_of_int64", 3, builtin_put_ints64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.put_array_of_float32", 3, builtin_put_floats32, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.put_array_of_float64", 3, builtin_put_floats64, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.put_bytes.bytes", 3, builtin_put_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
  {"Native.size_of", 1, builtin_size_of, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
  {"Native.get_struct", 3, builtin_get_struct, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"Native.put_struct", 4, builtin_put_struct, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false, false},
  {"Native.wait_readable", 2, builtin_wait_readable, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.wait_writable", 2, builtin_wait_writable, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.load", 1, builtin_native_load, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
  {"Native.callback", 2, builtin_native_callback, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false},
};

const size_t agc_ffi_builtin_count = sizeof agc_ffi_builtins / sizeof agc_ffi_builtins[0];

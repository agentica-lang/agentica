/*
 * The Zlib builtins (agc_zlib_builtins): one-shot compression and
 * decompression of byte lists, and task-owned streaming encoder and decoder
 * handles with their progress records. The file jobs (Zlib.*_file) only
 * validate and hand over to vm/files.c; the codec itself is the adapter of
 * zlib_codec.h, which alone includes zlib.h. Service layer. Design: RFC 1950
 * (zlib), RFC 1951 (deflate) and RFC 1952 (gzip).
 */
#include "services.h"
#include "zlib_codec.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* One-shot bytes are capped at 1 MiB in and out; each streaming call moves at
   most a 64 KiB quantum in and out, while a handle's lifetime totals are
   capped at 1 GiB each. */
#define ZLIB_ONE_SHOT_MAX ((size_t)1048576)
#define ZLIB_QUANTUM ((size_t)65536)
#define ZLIB_TOTAL_MAX ((uint64_t)1073741824)

typedef enum { ZLIB_ENCODER, ZLIB_DECODER } zlib_kind;

typedef enum { ZLIB_OPEN, ZLIB_FINISHING, ZLIB_DONE, ZLIB_FAILED } zlib_state;

/* A streaming context: malloc'd, with no GC pointer, so only the registry
   entry ties it to a task. The codec holds no caller buffer on any return
   (the adapter clears its stream pointers), and totals only move forward, so
   a feed that fails its caps changes nothing. Changes under rt->sync. */
typedef struct {
  zlib_kind kind;
  agc_zcodec *codec;
  uint64_t total_in, total_out, max_in, max_out;
  zlib_state state;
} zlib_ctx;

/* The bytes a one-shot call returns, grown in place. False when the next
   write would exceed max_out; running out of memory never returns. */
typedef struct {
  uint8_t *data;
  size_t len, cap;
} out_accum;

/* The no-input address of a finishing drain: length zero, never read. */
static const uint8_t zlib_empty[1] = {0};

/* The progress record fields in the contract's order. */
static const char *const progress_fields[] = {"output", "consumed", "finished", "needs_input"};

static agc_value zlib_error(const char *message) {
  size_t len = strlen(message);
  return agc_result_value(false, agc_string_value(agc_make_string(message, len, len)));
}

/* The bytes of a List[Int] argument of at most LIMIT items, or NULL with
   *failed set to the call's error. A non-Int item fails through agc_as_int,
   as in the other byte-list builtins. */
static const uint8_t *zlib_bytes(agc_vm *vm, agc_value list, size_t limit, const char *too_big,
                                 agc_value *failed) {
  const agc_list *values = agc_as_list(vm, list);
  if (agc_list_len(values) > limit) {
    *failed = zlib_error(too_big);
    return NULL;
  }
  const uint8_t *bytes = agc_byte_list(vm, values, agc_list_len(values));
  if (!bytes) *failed = zlib_error("zlib: bytes must be between 0 and 255");
  return bytes;
}

static agc_value byte_list_value(const uint8_t *data, size_t n) {
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&b, agc_int(data[k]));
  return agc_list_value(agc_list_builder_finish(&b));
}

static bool valid_window(int64_t window_bits) {
  return window_bits == 15 || window_bits == -15 || window_bits == 31;
}

static bool valid_total(int64_t total) { return total >= 1 && (uint64_t)total <= ZLIB_TOTAL_MAX; }

/* The end of the run: frees a context the owner never closed. No registry
   walk here (release_handles walks), no lock (only one thread is left). */
static void release_zlib(void *native) {
  zlib_ctx *c = native;
  agc_zcodec_free(c->codec);
  free(c);
}

/* Zlib.encoder_close, Zlib.decoder_close and the end of the owning task:
   idempotent, under rt->sync, with no pool job that could still reach the
   context, so the codec is freed at once. Identity is checked before the
   cast: File and lock handles share the AGC_T_HANDLE tag, and unregistering
   or freeing a foreign native would corrupt its owner. */
static void close_zlib(agc_vm *vm, agc_resource *r, agc_task *ender) {
  (void)ender;
  agc_sync_assert(vm);
  if (r->close != close_zlib) return;
  zlib_ctx *c = r->native;
  if (!c) return;
  r->native = NULL;
  agc_unregister(vm, r);
  agc_zcodec_free(c->codec);
  free(c);
}

/* The context of a streaming call: a closed handle (no native left) reads as
   closed whatever task asks, the owner alone may feed or finish, and the
   kind must match the call. A wrong task is a programming error like handing
   a handle to Task.spawn_owning without owning it, so it fails the same way;
   every other refusal is the call's error value. */
static zlib_ctx *open_ctx(agc_vm *vm, agc_value handle, zlib_kind kind, uint32_t span, agc_value *failed) {
  agc_resource *r = agc_as_handle(vm, handle);
  if (r->close != close_zlib) {
    *failed = zlib_error("zlib: handle is not a zlib handle");
    return NULL;
  }
  zlib_ctx *c = r->native;
  if (!c) {
    *failed = zlib_error("zlib: handle is closed");
    return NULL;
  }
  if (r->owner != vm->task)
    agc_fail(vm, "RUNTIME-HANDLE-NOT-OWNED", "the calling task does not own this handle, or it is closed", span + 1);
  if (c->kind != kind) {
    *failed = zlib_error(kind == ZLIB_ENCODER ? "zlib: handle is not an encoder" : "zlib: handle is not a decoder");
    return NULL;
  }
  if (c->state == ZLIB_FAILED) {
    *failed = zlib_error("zlib: handle failed");
    return NULL;
  }
  return c;
}

static uint32_t progress_struct(agc_vm *vm) { return agc_builtin_struct(vm, "ZlibProgress", progress_fields, 4); }

/* A progress record in the contract's field order: the fresh output bytes,
   what the call consumed of its input, whether the stream end was reached,
   and whether the codec wants more input (false while output may still drain
   from its internal state, so the caller drains with empty input). The
   struct type resolves at the caller, before any malloc it must survive. */
static agc_value progress_value(agc_vm *vm, uint32_t type, const uint8_t *output, size_t produced, uint64_t consumed,
                                bool finished, bool needs_input) {
  (void)vm;
  agc_struct *p = agc_new_struct(type, 4);
  p->fields[0] = byte_list_value(output, produced);
  p->fields[1] = agc_int((int64_t)consumed);
  p->fields[2] = agc_bool(finished);
  p->fields[3] = agc_bool(needs_input);
  return agc_result_value(true, agc_struct_value(p));
}

/* Whether the codec wants more input: only when it took all it was given,
   left room in the output, and has not ended. A call that produced nothing
   from nothing while waiting for input reports true; any other standstill
   keeps its remainder with the caller through consumed. */
static bool wants_input(size_t given, size_t consumed, size_t produced, size_t out_cap, bool finished) {
  if (finished) return false;
  return consumed == given && produced < out_cap;
}

/* One deflate or inflate pass over at most a quantum each way, through a
   malloc'd output buffer the call frees. Totals move only on success, and a
   refused cap changes nothing, except for one decoder case: once its output
   budget is exactly full, a further call may still need to consume the
   wrapper trailer (or a raw final empty block), which produces no bytes. A
   positive max_out is still required by the range check, and any positive
   quantum would trip the totals precheck, so that valid stream end would be
   unreachable. The decoder then runs a bounded one-byte overflow probe
   instead of the requested quantum: zero production commits normally, while
   any produced byte fails the handle without exposing the extra byte. The
   encoder keeps its conservative requested-quantum refusal (a smaller retry
   quantum always exists there). The progress record is resolved before the
   malloc: its lookup longjmps when the frontend has not provided it, and
   must not leave a live buffer behind. */
static agc_value feed_stream(agc_vm *vm, zlib_ctx *c, const uint8_t *input, size_t given, size_t out_cap, bool finish,
                             uint32_t span) {
  (void)span;
  uint32_t progress = progress_struct(vm);
  if (c->total_in + (uint64_t)given > c->max_in) return zlib_error("zlib: total input exceeds max_total_in");
  /* At an exactly full decoder budget only the zero-output trailer (or raw
     terminator) may remain. Probe it with a private one-byte buffer rather
     than refusing every positive quantum or running the full requested
     quantum with no room: the probe either commits empty progress or
     proves a genuine overflow. */
  bool probe = false;
  size_t eff_cap = out_cap;
  if (c->total_out + (uint64_t)out_cap > c->max_out) {
    if (c->kind == ZLIB_DECODER && c->total_out == c->max_out) {
      probe = true;
      eff_cap = 1;
    } else {
      return zlib_error("zlib: total output exceeds max_total_out");
    }
  }
  uint8_t *out = malloc(eff_cap ? eff_cap : 1);
  if (!out) agc_out_of_memory();
  const uint8_t *next = input;
  size_t left = given, produced = 0;
  agc_zcodec_status fed = c->kind == ZLIB_ENCODER
                              ? agc_zcodec_encode(c->codec, &next, &left, finish, out, eff_cap, &produced)
                              : agc_zcodec_decode(c->codec, &next, &left, out, eff_cap, &produced);
  size_t consumed = given - left;
  bool end = fed == AGC_ZCODEC_DONE;
  bool check = fed == AGC_ZCODEC_CHECK;
  bool format = fed == AGC_ZCODEC_FORMAT;
  if (fed == AGC_ZCODEC_NOMEM) {
    free(out);
    agc_out_of_memory();
  }
  agc_value result;
  if (check || format) {
    c->state = ZLIB_FAILED;
    result = zlib_error(check ? "zlib: checksum mismatch" : c->kind == ZLIB_ENCODER ? "zlib: compression failed"
                                                                                    : "zlib: invalid compressed data");
  } else if (probe && produced != 0) {
    /* A genuine overflow past the full budget: fail sticky without
       recording or returning the probe byte, so the handle can never
       resume and the extra output never leaks. Totals stay frozen, as on
       every other failure leg. */
    c->state = ZLIB_FAILED;
    result = zlib_error("zlib: total output exceeds max_total_out");
  } else {
    if (end) c->state = ZLIB_DONE;
    c->total_in += (uint64_t)consumed;
    c->total_out += (uint64_t)produced;
    agc_charge_bytes(vm, consumed + produced);
    result = progress_value(vm, progress, out, produced, (uint64_t)consumed, end,
                            wants_input(given, consumed, produced, eff_cap, end));
  }
  free(out);
  return result;
}

static bool accum_push(out_accum *a, const uint8_t *chunk, size_t n, size_t max_out) {
  if (a->len + n > max_out) return false;
  if (a->len + n > a->cap) {
    size_t bigger = a->cap * 2 > a->len + n ? a->cap * 2 : a->len + n;
    uint8_t *wider = realloc(a->data, bigger);
    if (!wider) agc_out_of_memory();
    a->data = wider;
    a->cap = bigger;
  }
  if (n) memcpy(a->data + a->len, chunk, n);
  a->len += n;
  return true;
}

/* One whole input through the codec in bounded quanta: NO_FLUSH while input
   remains, then FINISH drains for an encoder, while a decoder must end
   exactly where the input ends. The output never grows past max_out, and a
   decoder refuses every trailing byte. */
static agc_value oneshot_run(agc_vm *vm, zlib_kind kind, agc_zcodec *codec, const uint8_t *input, size_t n,
                             size_t max_out) {
  uint8_t *chunk = malloc(ZLIB_QUANTUM);
  out_accum out = {malloc(ZLIB_QUANTUM), 0, ZLIB_QUANTUM};
  if (!chunk || !out.data) agc_out_of_memory();
  const uint8_t *next = input;
  size_t left = n, idle = 0;
  agc_value failed = agc_void();
  bool end = false;
  for (;;) {
    size_t before = left, produced = 0;
    agc_zcodec_status fed = kind == ZLIB_ENCODER
                                ? agc_zcodec_encode(codec, &next, &left, left == 0, chunk, ZLIB_QUANTUM, &produced)
                                : agc_zcodec_decode(codec, &next, &left, chunk, ZLIB_QUANTUM, &produced);
    if (fed == AGC_ZCODEC_NOMEM) {
      free(chunk);
      free(out.data);
      agc_zcodec_free(codec);
      agc_out_of_memory();
    }
    if (fed == AGC_ZCODEC_CHECK) {
      failed = zlib_error("zlib: checksum mismatch");
      break;
    }
    if (fed == AGC_ZCODEC_FORMAT) {
      failed = zlib_error(kind == ZLIB_ENCODER ? "zlib: compression failed" : "zlib: invalid compressed data");
      break;
    }
    if (!accum_push(&out, chunk, produced, max_out)) {
      failed = zlib_error("zlib: output exceeds max_out_bytes");
      break;
    }
    if (fed == AGC_ZCODEC_DONE) {
      end = true;
      break;
    }
    if (kind == ZLIB_DECODER && left == 0) {
      failed = zlib_error("zlib: truncated stream");
      break;
    }
    /* Every pass consumes input, produces output, or ends: eight still
       passes bound a codec that stopped moving without ending. */
    if (before - left == 0 && produced == 0) {
      if (++idle > 8) {
        failed = zlib_error(kind == ZLIB_ENCODER ? "zlib: compression failed" : "zlib: invalid compressed data");
        break;
      }
    } else {
      idle = 0;
    }
  }
  free(chunk);
  agc_zcodec_free(codec);
  if (!end) {
    free(out.data);
    return failed;
  }
  /* A strict single stream: a second member, zeros or junk after the verified
     end stay unconsumed, and are refused here rather than discarded. */
  if (kind == ZLIB_DECODER && left != 0) {
    free(out.data);
    return zlib_error("zlib: trailing bytes after stream end");
  }
  agc_charge_bytes(vm, n + out.len);
  agc_value result = agc_result_value(true, byte_list_value(out.data, out.len));
  free(out.data);
  return result;
}

static agc_value oneshot_compress(agc_vm *vm, const uint8_t *input, size_t n, int window_bits, int64_t level,
                                  size_t max_out) {
  agc_zcodec *codec = agc_zcodec_encode_begin(window_bits, (int)level);
  if (!codec) agc_out_of_memory();
  return oneshot_run(vm, ZLIB_ENCODER, codec, input, n, max_out);
}

static agc_value oneshot_decode(agc_vm *vm, const uint8_t *input, size_t n, int window_bits, size_t max_out) {
  if (n == 0) return zlib_error("zlib: invalid compressed data");
  agc_zcodec *codec = agc_zcodec_decode_begin(window_bits);
  if (!codec) agc_out_of_memory();
  return oneshot_run(vm, ZLIB_DECODER, codec, input, n, max_out);
}

/* One-shot calls are pure functions of their arguments: they hold no shared
   state, so they run without the shared lock, like Crypto.sha256, with the
   1 MiB input and output bounds keeping each call's work bounded. */
static agc_value oneshot_args(agc_vm *vm, agc_value *args, int window_bits, bool compress) {
  agc_value failed = agc_void();
  const uint8_t *input = zlib_bytes(vm, args[0], ZLIB_ONE_SHOT_MAX, "zlib: input exceeds 1048576 bytes", &failed);
  if (!input) return failed;
  size_t n = agc_list_len(agc_as_list(vm, args[0]));
  int64_t level = 0;
  if (compress) {
    level = agc_as_int(vm, args[1]);
    if (level < 0 || level > 9) return zlib_error("zlib: level must be between 0 and 9");
  }
  int64_t max_out = agc_as_int(vm, args[compress ? 2 : 1]);
  if (max_out < 1 || (uint64_t)max_out > ZLIB_ONE_SHOT_MAX)
    return zlib_error("zlib: max_out_bytes must be between 1 and 1048576");
  return compress ? oneshot_compress(vm, input, n, window_bits, level, (size_t)max_out)
                  : oneshot_decode(vm, input, n, window_bits, (size_t)max_out);
}

static agc_value builtin_deflate(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return oneshot_args(vm, args, 15, true);
}

static agc_value builtin_inflate(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return oneshot_args(vm, args, 15, false);
}

static agc_value builtin_gzip(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return oneshot_args(vm, args, 31, true);
}

static agc_value builtin_gunzip(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return oneshot_args(vm, args, 31, false);
}

static agc_value builtin_deflate_file(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_zlib_file(vm, AGC_ZLIB_DEFLATE_FILE, agc_as_string(vm, args[0]), agc_as_string(vm, args[1]),
                       agc_as_int(vm, args[2]), agc_as_int(vm, args[3]), agc_as_int(vm, args[4]), span);
}

static agc_value builtin_inflate_file(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_zlib_file(vm, AGC_ZLIB_INFLATE_FILE, agc_as_string(vm, args[0]), agc_as_string(vm, args[1]), 0,
                       agc_as_int(vm, args[2]), agc_as_int(vm, args[3]), span);
}

static agc_value builtin_gzip_file(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_zlib_file(vm, AGC_ZLIB_GZIP_FILE, agc_as_string(vm, args[0]), agc_as_string(vm, args[1]),
                       agc_as_int(vm, args[2]), agc_as_int(vm, args[3]), agc_as_int(vm, args[4]), span);
}

static agc_value builtin_gunzip_file(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_zlib_file(vm, AGC_ZLIB_GUNZIP_FILE, agc_as_string(vm, args[0]), agc_as_string(vm, args[1]), 0,
                       agc_as_int(vm, args[2]), agc_as_int(vm, args[3]), span);
}

/* Streaming calls run with rt->sync held and touch the shared registry, so
   each moves at most one quantum: the lock is never held across unbounded
   work, and consumed plus produced pay turn cost. */
static agc_value init_stream(agc_vm *vm, zlib_kind kind, int64_t window_bits, int64_t level, bool has_level,
                             int64_t max_in, int64_t max_out) {
  if (!valid_window(window_bits)) return zlib_error("zlib: window_bits must be 15, -15, or 31");
  if (has_level && (level < 0 || level > 9)) return zlib_error("zlib: level must be between 0 and 9");
  if (!valid_total(max_in)) return zlib_error("zlib: max_total_in must be between 1 and 1073741824");
  if (!valid_total(max_out)) return zlib_error("zlib: max_total_out must be between 1 and 1073741824");
  agc_zcodec *codec = kind == ZLIB_ENCODER ? agc_zcodec_encode_begin((int)window_bits, (int)level)
                                           : agc_zcodec_decode_begin((int)window_bits);
  if (!codec) agc_out_of_memory();
  zlib_ctx *c = calloc(1, sizeof *c);
  if (!c) {
    agc_zcodec_free(codec);
    agc_out_of_memory();
  }
  c->kind = kind;
  c->codec = codec;
  c->max_in = (uint64_t)max_in;
  c->max_out = (uint64_t)max_out;
  agc_resource *r = agc_register(vm, c, release_zlib);
  agc_own(vm, r, close_zlib);
  return agc_result_value(true, agc_handle_value(r));
}

static agc_value builtin_deflate_init(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return init_stream(vm, ZLIB_ENCODER, agc_as_int(vm, args[0]), agc_as_int(vm, args[1]), true,
                     agc_as_int(vm, args[2]), agc_as_int(vm, args[3]));
}

static agc_value builtin_inflate_init(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return init_stream(vm, ZLIB_DECODER, agc_as_int(vm, args[0]), 0, false, agc_as_int(vm, args[1]),
                     agc_as_int(vm, args[2]));
}

static agc_value next_stream(agc_vm *vm, agc_value *args, uint32_t span, zlib_kind kind) {
  agc_value failed = agc_void();
  zlib_ctx *c = open_ctx(vm, args[0], kind, span, &failed);
  if (!c) return failed;
  const uint8_t *input = zlib_bytes(vm, args[1], ZLIB_QUANTUM, "zlib: input exceeds 65536 bytes", &failed);
  if (!input) return failed;
  size_t n = agc_list_len(agc_as_list(vm, args[1]));
  int64_t max_out = agc_as_int(vm, args[2]);
  if (max_out < 1 || (uint64_t)max_out > ZLIB_QUANTUM) return zlib_error("zlib: max_out must be between 1 and 65536");
  if (c->state == ZLIB_DONE) {
    /* Empty drains after the verified end report finished again; only new
       input after it is an error, since those bytes would be discarded. */
    if (n != 0) return zlib_error("zlib: stream already finished");
    return progress_value(vm, progress_struct(vm), input, 0, 0, true, false);
  }
  if (c->kind == ZLIB_ENCODER && c->state == ZLIB_FINISHING)
    return zlib_error("zlib: encoder finish already started");
  return feed_stream(vm, c, input, n, (size_t)max_out, false, span);
}

static agc_value builtin_deflate_next(agc_vm *vm, agc_value *args, uint32_t span) {
  return next_stream(vm, args, span, ZLIB_ENCODER);
}

static agc_value builtin_inflate_next(agc_vm *vm, agc_value *args, uint32_t span) {
  return next_stream(vm, args, span, ZLIB_DECODER);
}

static agc_value builtin_deflate_finish(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_value failed = agc_void();
  zlib_ctx *c = open_ctx(vm, args[0], ZLIB_ENCODER, span, &failed);
  if (!c) return failed;
  int64_t max_out = agc_as_int(vm, args[1]);
  if (max_out < 1 || (uint64_t)max_out > ZLIB_QUANTUM) return zlib_error("zlib: max_out must be between 1 and 65536");
  /* Finishing drains stay callable until the terminal call: each bounded
     drain reports its finished flag, and only new feed is refused. FINISHING
     is assigned only once the drain is accepted, so a refused cap leaves
     OPEN intact and a later feed stays legal. */
  if (c->state == ZLIB_DONE) return progress_value(vm, progress_struct(vm), zlib_empty, 0, 0, true, false);
  agc_value drained = feed_stream(vm, c, zlib_empty, 0, (size_t)max_out, true, span);
  if (agc_as_result(vm, drained)->ok && c->state != ZLIB_DONE) c->state = ZLIB_FINISHING;
  return drained;
}

static agc_value builtin_inflate_finish(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_value failed = agc_void();
  zlib_ctx *c = open_ctx(vm, args[0], ZLIB_DECODER, span, &failed);
  if (!c) return failed;
  /* A verified stream end is the only success: anything earlier is a
     truncation, never a quiet ok. */
  if (c->state != ZLIB_DONE) return zlib_error("zlib: stream is truncated");
  return agc_result_value(true, agc_void());
}

/* Both close rows: closing is idempotent and owner-indifferent, like
   Native.close, so one function serves the encoder and the decoder. A
   foreign handle is refused before close_zlib could unregister it: the
   close reports, it never touches another library's resource. */
static agc_value builtin_zlib_close(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_resource *r = agc_as_handle(vm, args[0]);
  if (r->close != close_zlib) return zlib_error("zlib: handle is not a zlib handle");
  close_zlib(vm, r, NULL);
  return agc_result_value(true, agc_void());
}

const agc_builtin agc_zlib_builtins[] = {
  {"Zlib.deflate", 3, builtin_deflate, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Zlib.inflate", 2, builtin_inflate, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Zlib.gzip", 3, builtin_gzip, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Zlib.gunzip", 2, builtin_gunzip, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Zlib.deflate_file", 5, builtin_deflate_file, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Zlib.inflate_file", 4, builtin_inflate_file, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Zlib.gzip_file", 5, builtin_gzip_file, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Zlib.gunzip_file", 4, builtin_gunzip_file, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Zlib.deflate_init", 4, builtin_deflate_init, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Zlib.inflate_init", 3, builtin_inflate_init, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Zlib.deflate_next", 3, builtin_deflate_next, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Zlib.inflate_next", 3, builtin_inflate_next, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Zlib.deflate_finish", 2, builtin_deflate_finish, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Zlib.inflate_finish", 1, builtin_inflate_finish, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Zlib.encoder_close", 1, builtin_zlib_close, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
  {"Zlib.decoder_close", 1, builtin_zlib_close, AGC_NATIVE_NONE, AGC_COST_SIZE, true, false},
};

const size_t agc_zlib_builtin_count = sizeof agc_zlib_builtins / sizeof agc_zlib_builtins[0];

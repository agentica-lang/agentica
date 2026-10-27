/*
 * The Zlib builtins (agc_zlib_builtins): one-shot compression and
 * decompression of byte lists and the CRC32 checksum, and the zlib streams of
 * the Lazy steps deflate, inflate, gzip and gunzip (agc_zstep_*, driven by
 * vm/lazy.c). The codec itself is the adapter of zlib_codec.h, which alone
 * includes zlib.h. Service layer. Design: RFC 1950 (zlib), RFC 1951
 * (deflate) and RFC 1952 (gzip).
 */
#include "services.h"
#include "zlib_codec.h"

#include <inttypes.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* One-shot bytes are capped at 1 MiB in and out; each pass of a codec moves
   at most a 64 KiB quantum out, so a Lazy step gives chunks of at most that
   size whatever the ratio of the data. */
#define ZLIB_ONE_SHOT_MAX ((size_t)1048576)
#define ZLIB_QUANTUM ((size_t)65536)

typedef enum { ZLIB_ENCODER, ZLIB_DECODER } zlib_kind;

/* The stream of one zlib stage in one Lazy run: malloc'd, with no GC
   pointer, so only its registry entry ties it to the task that runs the
   terminal. The codec holds no caller buffer on any return (the adapter
   clears its stream pointers). full is true when the last pass filled its
   output, so more output may wait in the codec with no new input; done once
   the stream ended (a decoder verified its trailer); idle counts the passes
   in a row that moved nothing. Only the task that owns the entry touches it. */
typedef struct {
  agc_zcodec *codec;
  uint8_t *buf; /* one quantum, the output of every pass */
  bool encode, full, done;
  int idle;
  uint64_t total_out, max_out;
} zstep;

/* The bytes a one-shot call returns, grown in place. False when the next
   write would exceed max_out; running out of memory never returns. */
typedef struct {
  uint8_t *data;
  size_t len, cap;
} out_accum;

/* The no-input address of a pass with no input: length zero, never read. */
static const uint8_t zlib_empty[1] = {0};

/* The window bits of the kinds of __lazy_zlib (stdlib/prelude/lazy.agc): deflate, raw deflate, gzip, inflate, raw
   inflate, gunzip. */
static const int step_bits[] = {15, -15, 31, 15, -15, 31};

static agc_value zlib_error(const char *message) {
  size_t len = strlen(message);
  return agc_result_value(false, agc_string_value(agc_make_string(message, len, len)));
}

/* The bytes of a List[Int] argument of at most ZLIB_ONE_SHOT_MAX items, or
   NULL with *failed set to the call's error. A non-Int item fails through
   agc_as_int, as in the other byte-list builtins. */
static const uint8_t *zlib_bytes(agc_vm *vm, agc_value list, agc_value *failed) {
  const agc_list *values = agc_as_list(vm, list);
  if (agc_list_len(values) > ZLIB_ONE_SHOT_MAX) {
    *failed = zlib_error("zlib: input exceeds 1048576 bytes");
    return NULL;
  }
  const uint8_t *bytes = agc_byte_list(vm, values, agc_list_len(values));
  if (!bytes) *failed = zlib_error("zlib: bytes must be between 0 and 255");
  return bytes;
}

static agc_value byte_list_value(const uint8_t *data, size_t n) { return agc_list_value(agc_list_of_bytes(data, n)); }

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
      failed = zlib_error("zlib: output exceeds max_bytes");
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
  const uint8_t *input = zlib_bytes(vm, args[0], &failed);
  if (!input) return failed;
  size_t n = agc_list_len(agc_as_list(vm, args[0]));
  int64_t level = 0;
  if (compress) {
    level = agc_as_int(vm, args[1]);
    if (level < 0 || level > 9) return zlib_error("zlib: level must be between 0 and 9");
  }
  int64_t max_out = agc_as_int(vm, args[compress ? 2 : 1]);
  if (max_out < 1 || (uint64_t)max_out > ZLIB_ONE_SHOT_MAX)
    return zlib_error("zlib: max_bytes must be between 1 and 1048576");
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

/* Zlib.crc32(data, seed): the zlib CRC32 of the bytes chained after seed,
   for the ZIP checksum (RFC 1952 §8). A pure function of its arguments: no
   handle, no shared state, so it runs without the shared lock, like the
   one-shot calls, with the 1 MiB input bound keeping each call's work
   bounded. Empty input returns the seed unchanged (zlib crc32(Z_NULL, 0)
   resets to zero, so the empty case never reaches the codec). The bytes and
   the checksum are computed first; the Result is built only after, so no
   GC allocation happens while a caller buffer is held. */
static agc_value builtin_crc32(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_value failed = agc_void();
  const uint8_t *input = zlib_bytes(vm, args[0], &failed);
  if (!input) return failed;
  size_t n = agc_list_len(agc_as_list(vm, args[0]));
  int64_t seed = agc_as_int(vm, args[1]);
  if (seed < 0 || seed > 4294967295LL) return zlib_error("zlib: seed must be between 0 and 4294967295");
  uint32_t crc = agc_zlib_crc32((uint32_t)seed, input, n);
  return agc_result_value(true, agc_int((int64_t)crc));
}

/* The end of the run: frees a stream no run and no task end freed. No
   registry walk here (release_handles walks), no lock (only one thread is
   left). */
static void release_zstep(void *native) {
  zstep *z = native;
  agc_zcodec_free(z->codec);
  free(z->buf);
  free(z);
}

/* The end of the owning task (a raise, a cancel, --max-steps) and
   agc_zstep_close: idempotent, under rt->sync. Identity is checked before
   the cast, as File and lock handles share the registry. */
static void close_zstep(agc_vm *vm, agc_resource *r, agc_task *ender) {
  (void)ender;
  agc_sync_assert(vm);
  if (r->close != close_zstep) return;
  zstep *z = r->native;
  if (!z) return;
  r->native = NULL;
  agc_unregister(vm, r);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "zlib_close handle=%" PRIu64, r->id);
  agc_zcodec_free(z->codec);
  free(z->buf);
  free(z);
}

static agc_zstep_status zstep_failed(agc_value *out, const char *message) {
  *out = zlib_error(message);
  return AGC_ZSTEP_FAILED;
}

agc_value agc_zstep_check(int64_t kind, int64_t level, int64_t max_bytes) {
  if (kind < 3 && (level < 0 || level > 9)) return zlib_error("zlib: level must be between 0 and 9");
  if (kind >= 3 && max_bytes < 1) return zlib_error("zlib: max_bytes must be at least 1");
  return agc_void();
}

/* The caller checked the kind (0 to 5) and agc_zstep_check passed. The registry and the owner list are shared, so
   the entry is made under rt->sync: a Lazy terminal runs unlocked. */
agc_resource *agc_zstep_open(agc_vm *vm, int64_t kind, int64_t level, int64_t max_bytes) {
  bool encode = kind < 3;
  int bits = step_bits[kind];
  agc_zcodec *codec = encode ? agc_zcodec_encode_begin(bits, (int)level) : agc_zcodec_decode_begin(bits);
  if (!codec) agc_out_of_memory();
  zstep *z = calloc(1, sizeof *z);
  uint8_t *buf = malloc(ZLIB_QUANTUM);
  if (!z || !buf) {
    agc_zcodec_free(codec);
    free(z);
    free(buf);
    agc_out_of_memory();
  }
  z->codec = codec;
  z->buf = buf;
  z->encode = encode;
  z->max_out = encode ? UINT64_MAX : (uint64_t)max_bytes;
  agc_sync_take(vm);
  agc_resource *r = agc_register(vm, z, release_zstep);
  agc_own(vm, r, close_zstep);
  agc_sync_drop(vm);
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "zlib_open handle=%" PRIu64, r->id);
  return r;
}

void agc_zstep_close(agc_vm *vm, agc_resource *r) {
  agc_sync_take(vm);
  close_zstep(vm, r, NULL);
  agc_sync_drop(vm);
}

/* One pass of the codec over in (len bytes, *used set to what it took) into one chunk of at most a quantum. A
   decoder's output buffer is one byte past what max_out still allows when that is less than a quantum, so a pass
   that fills it proves the overflow without ever keeping a byte past the cap; at an exactly full budget the pass can
   still read the trailer, which produces nothing. The decoder never finishes by itself: the end is its trailer, and
   any byte after it is refused here (RFC 1950 §2.2, RFC 1952 §2.2: one stream, one member). */
agc_zstep_status agc_zstep_next(agc_vm *vm, agc_resource *r, const uint8_t *in, size_t len, size_t *used, bool finish,
                                agc_value *out) {
  *used = 0;
  *out = agc_void();
  zstep *z = r->close == close_zstep ? r->native : NULL;
  if (!z) agc_fail(vm, "RUNTIME-INTERNAL", "a Lazy zlib step after its stream was freed", 0);
  if (z->done) return len ? zstep_failed(out, "zlib: trailing bytes after stream end") : AGC_ZSTEP_END;
  if (len == 0 && !finish && !z->full) return AGC_ZSTEP_INPUT;
  size_t cap = ZLIB_QUANTUM;
  if (z->max_out - z->total_out < (uint64_t)cap) cap = (size_t)(z->max_out - z->total_out) + 1;
  uint8_t *buf = z->buf;
  const uint8_t *next = len ? in : zlib_empty;
  size_t left = len, produced = 0;
  agc_zcodec_status fed = z->encode ? agc_zcodec_encode(z->codec, &next, &left, finish, buf, cap, &produced)
                                    : agc_zcodec_decode(z->codec, &next, &left, buf, cap, &produced);
  if (fed == AGC_ZCODEC_NOMEM) agc_out_of_memory();
  size_t consumed = len - left;
  *used = consumed;
  if (fed == AGC_ZCODEC_CHECK || fed == AGC_ZCODEC_FORMAT || z->total_out + produced > z->max_out) {
    if (fed == AGC_ZCODEC_CHECK) return zstep_failed(out, "zlib: checksum mismatch");
    if (fed == AGC_ZCODEC_FORMAT)
      return zstep_failed(out, z->encode ? "zlib: compression failed" : "zlib: invalid compressed data");
    return zstep_failed(out, "zlib: output exceeds max_bytes");
  }
  z->total_out += produced;
  agc_charge_bytes(vm, consumed + produced);
  if (produced) *out = byte_list_value(buf, produced);
  if (fed == AGC_ZCODEC_DONE) {
    z->done = true;
    return left ? zstep_failed(out, "zlib: trailing bytes after stream end") : AGC_ZSTEP_END;
  }
  /* Every pass consumes input, produces output, or ends: eight still passes bound a codec that stopped moving. */
  z->idle = consumed == 0 && produced == 0 ? z->idle + 1 : 0;
  if (z->idle > 8) return zstep_failed(out, z->encode ? "zlib: compression failed" : "zlib: invalid compressed data");
  z->full = produced == cap;
  if (left || z->full || (finish && z->encode)) return AGC_ZSTEP_AGAIN;
  if (finish) return zstep_failed(out, "zlib: truncated stream");
  return AGC_ZSTEP_INPUT;
}

const agc_builtin agc_zlib_builtins[] = {
  {"Zlib.deflate", 3, builtin_deflate, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Zlib.inflate", 2, builtin_inflate, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Zlib.gzip", 3, builtin_gzip, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Zlib.gunzip", 2, builtin_gunzip, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Zlib.crc32", 2, builtin_crc32, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
};

const size_t agc_zlib_builtin_count = sizeof agc_zlib_builtins / sizeof agc_zlib_builtins[0];

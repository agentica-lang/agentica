/* Zlib bytes, the streaming decoder handle and the streams of the Lazy steps
   (agc_zstep_*), with their shared-VM interleavings, against independently
   generated vectors. */
#include "builtin_test.h"
#include "../file_io.h"
#include "../services.h"
#include "../zlib_codec.h"

#include <assert.h>
#include <setjmp.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#include "test_support.h"
#include "scratch_dir.h"
#include "zlib_vectors.h"

static agc_vm vm;
static agc_program program;
static agc_struct_def progress_def;
static agc_string *progress_names[4];

/* The bytes a stream produced, gathered across its chunks, with the largest
   chunk: no chunk is empty or over the 64 KiB quantum. */
typedef struct {
  uint8_t *data;
  size_t len, cap, largest;
} sink;

/* Python's zlib on "abc" and "" at levels 0, 6 and 9: the exact streams our
   decoder must read and our encoder must write. The gzip and raw members
   live in zlib_vectors.h. */
static const uint8_t zlib_abc[] = {0x78, 0x9c, 0x4b, 0x4c, 0x4a, 0x06, 0x00, 0x02, 0x4d, 0x01, 0x27};
static const uint8_t zlib_empty[] = {0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01};
static const uint8_t zlib_abc_l0[] = {0x78, 0x01, 0x01, 0x03, 0x00, 0xfc, 0xff,
  0x61, 0x62, 0x63, 0x02, 0x4d, 0x01, 0x27};
static const uint8_t abc_bytes[] = {0x61, 0x62, 0x63};

/* A call of the named builtin on T of V: with a shared VM the interpreter
   holds rt->sync across a shared row, so the test takes it the same way. No
   Zlib call parks. */
static agc_value call_on(agc_vm *v, agc_task *t, const char *name, uint32_t arity, agc_value *args) {
  const agc_builtin *b = agc_find_builtin((const uint8_t *)name, strlen(name), arity);
  assert(b);
  bool shared = v->rt->shared;
  if (shared) agc_sync_take(v);
  t->state = AGC_TASK_RUNNING;
  t->parking = false;
  v->task = t;
  agc_value result = b->fn(v, args, 0);
  assert(!t->parking);
  if (shared) agc_sync_drop(v);
  return result;
}

static agc_value call(const char *name, uint32_t arity, agc_value *args) {
  return call_on(&vm, vm.task, name, arity, args);
}

static agc_value ok(agc_value result) {
  const agc_result *r = agc_as_result(&vm, result);
  assert(r->ok);
  return r->value;
}

static void check_error(agc_value result, const char *message) {
  const agc_result *r = agc_as_result(&vm, result);
  assert(!r->ok);
  const agc_string *text = agc_as_string(&vm, r->value);
  assert(text->bytes == strlen(message) && memcmp(text->data, message, text->bytes) == 0);
}

static agc_value byte_list(const uint8_t *data, size_t n) {
  agc_value *items = malloc(n ? n * sizeof *items : 1);
  if (!items) agc_out_of_memory();
  for (size_t k = 0; k < n; k++) items[k] = agc_int(data[k]);
  agc_value list = agc_list_value(agc_list_from_array(items, n));
  free(items);
  return list;
}

static void check_list_bytes(agc_value list, const uint8_t *data, size_t n) {
  const agc_list *got = agc_as_list(&vm, list);
  assert(agc_list_len(got) == n);
  for (size_t k = 0; k < n; k++) assert(agc_as_int(&vm, agc_list_get(got, k)) == data[k]);
}

/* Appends the output list of a progress record to DEST at *TOTAL. */
static void gather(agc_vm *v, const agc_struct *p, uint8_t *dest, size_t *total) {
  const agc_list *out = agc_as_list(v, p->fields[0]);
  for (size_t j = 0; j < agc_list_len(out); j++) dest[(*total)++] = (uint8_t)agc_as_int(v, agc_list_get(out, j));
}

static const agc_struct *progress_of(agc_value result) {
  const agc_struct *p = agc_as_struct(&vm, ok(result));
  assert(p->n == 4);
  return p;
}

/* A progress record in the contract's field order: output, consumed,
   finished, needs_input. The struct lookup already enforces the names and
   order against the program; the kinds below pin the value side. */
static void check_progress(const agc_struct *p, size_t produced, int64_t consumed, bool finished, bool needs_input) {
  assert(agc_list_len(agc_as_list(&vm, p->fields[0])) == produced);
  assert(agc_as_int(&vm, p->fields[1]) == consumed);
  assert(agc_as_bool(&vm, p->fields[2]) == finished);
  assert(agc_as_bool(&vm, p->fields[3]) == needs_input);
}

/* The public rows in the contract's order, with their arities and shared
   marks: the one-shot and checksum calls are pure, while the streaming
   decoder touches the shared registry and runs under rt->sync. */
static void test_table(void) {
  struct {
    const char *name;
    uint32_t arity;
    bool shared;
  } expected[] = {
    {"Zlib.deflate", 3, false}, {"Zlib.inflate", 2, false}, {"Zlib.gzip", 3, false}, {"Zlib.gunzip", 2, false},
    {"Zlib.crc32", 2, false}, {"Zlib.inflate_init", 3, true}, {"Zlib.inflate_next", 3, true},
    {"Zlib.inflate_finish", 1, true}, {"Zlib.decoder_close", 1, true},
  };
  /* The 8 rows past these are the stubs of the removed calls that the old stage0 names; they share one function. */
  size_t count = sizeof expected / sizeof expected[0];
  assert(agc_zlib_builtin_count == count + 8);
  for (size_t k = count + 1; k < agc_zlib_builtin_count; k++)
    assert(agc_zlib_builtins[k].fn == agc_zlib_builtins[count].fn);
  for (size_t k = 0; k < count; k++) {
    const agc_builtin *b = &agc_zlib_builtins[k];
    if (strcmp(b->name, expected[k].name) != 0 || b->arity != expected[k].arity || b->shared != expected[k].shared ||
        b->cost != AGC_COST_SIZE || b->leaf || b->native != AGC_NATIVE_NONE || !b->fn)
      fprintf(stderr, "row %zu should be %s/%u shared=%d\n", k, expected[k].name, expected[k].arity,
              expected[k].shared);
    assert(strcmp(b->name, expected[k].name) == 0 && b->arity == expected[k].arity &&
           b->shared == expected[k].shared && b->cost == AGC_COST_SIZE && !b->leaf &&
           b->native == AGC_NATIVE_NONE && b->fn);
    assert(agc_find_builtin((const uint8_t *)expected[k].name, strlen(expected[k].name), expected[k].arity) == b);
  }
}

/* One-shot compression writes the independent streams byte for byte,
   including the empty stream and the level corners. */
static void test_oneshot_compress(void) {
  agc_value data = byte_list(abc_bytes, sizeof abc_bytes);
  agc_value args[] = {data, agc_int(6), agc_int(1048576)};
  check_list_bytes(ok(call("Zlib.deflate", 3, args)), zlib_abc, sizeof zlib_abc);
  args[1] = agc_int(0);
  check_list_bytes(ok(call("Zlib.deflate", 3, args)), zlib_abc_l0, sizeof zlib_abc_l0);
  args[1] = agc_int(9);
  const agc_list *l9 = agc_as_list(&vm, ok(call("Zlib.deflate", 3, args)));
  assert(agc_list_len(l9) == sizeof zlib_abc);
  assert(agc_as_int(&vm, agc_list_get(l9, 0)) == 0x78 && agc_as_int(&vm, agc_list_get(l9, 1)) == 0xda);
  for (size_t k = 2; k < sizeof zlib_abc; k++)
    assert(agc_as_int(&vm, agc_list_get(l9, k)) == zlib_abc[k]);
  agc_value empty = byte_list(NULL, 0);
  agc_value empty_args[] = {empty, agc_int(6), agc_int(1048576)};
  check_list_bytes(ok(call("Zlib.deflate", 3, empty_args)), zlib_empty, sizeof zlib_empty);
  /* Our gzip member is verified structurally: the fixed header bytes
     (magic, method, flags, mtime, level-9 XFL), the raw body and the
     CRC32/ISIZE trailer. The OS byte is excluded: zlib writes OS_CODE,
     which is 3 on Unix but 10 on native Windows (zutil.h), so it is
     host-dependent and no contract fixes it. */
  agc_value gz_args[] = {data, agc_int(9), agc_int(1048576)};
  const agc_list *gz = agc_as_list(&vm, ok(call("Zlib.gzip", 3, gz_args)));
  assert(agc_list_len(gz) == 10 + sizeof zlib_vec_raw_abc + 8);
  static const uint8_t gz_head[] = {0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03};
  static const uint8_t gz_tail[] = {0xc2, 0x41, 0x24, 0x35, 0x03, 0x00, 0x00, 0x00};
  for (size_t k = 0; k < sizeof gz_head; k++) {
    if (k == 9) continue; /* OS byte: host-dependent, see above. */
    assert(agc_as_int(&vm, agc_list_get(gz, k)) == gz_head[k]);
  }
  for (size_t k = 0; k < sizeof zlib_vec_raw_abc; k++)
    assert(agc_as_int(&vm, agc_list_get(gz, 10 + k)) == zlib_vec_raw_abc[k]);
  for (size_t k = 0; k < sizeof gz_tail; k++)
    assert(agc_as_int(&vm, agc_list_get(gz, 10 + sizeof zlib_vec_raw_abc + k)) == gz_tail[k]);
  /* An exact output bound succeeds; one byte less fails without a partial. */
  agc_value fit[] = {data, agc_int(6), agc_int(sizeof zlib_abc)};
  check_list_bytes(ok(call("Zlib.deflate", 3, fit)), zlib_abc, sizeof zlib_abc);
  agc_value tight[] = {data, agc_int(6), agc_int(sizeof zlib_abc - 1)};
  check_error(call("Zlib.deflate", 3, tight), "zlib: output exceeds max_bytes");
  agc_value bad_level[] = {data, agc_int(10), agc_int(100)};
  check_error(call("Zlib.deflate", 3, bad_level), "zlib: level must be between 0 and 9");
  bad_level[1] = agc_int(-1);
  check_error(call("Zlib.deflate", 3, bad_level), "zlib: level must be between 0 and 9");
  agc_value bad_max[] = {data, agc_int(6), agc_int(0)};
  check_error(call("Zlib.deflate", 3, bad_max), "zlib: max_bytes must be between 1 and 1048576");
  bad_max[2] = agc_int(1048577);
  check_error(call("Zlib.deflate", 3, bad_max), "zlib: max_bytes must be between 1 and 1048576");
  static uint8_t big[1048577] = {0};
  agc_value huge = byte_list(big, sizeof big);
  agc_value big_args[] = {huge, agc_int(6), agc_int(1048576)};
  check_error(call("Zlib.deflate", 3, big_args), "zlib: input exceeds 1048576 bytes");
  agc_list_builder bad;
  agc_list_builder_sized(&bad, 3);
  agc_list_builder_push(&bad, agc_int(0x61));
  agc_list_builder_push(&bad, agc_int(256));
  agc_list_builder_push(&bad, agc_int(0x63));
  agc_value bad_data[] = {agc_list_value(agc_list_builder_finish(&bad)), agc_int(6), agc_int(100)};
  check_error(call("Zlib.deflate", 3, bad_data), "zlib: bytes must be between 0 and 255");
}

/* One-shot decompression reads the independent streams strictly: one
   stream only, with its checksum verified and every trailing byte refused. */
static void test_oneshot_decode(void) {
  agc_value args[] = {byte_list(zlib_abc, sizeof zlib_abc), agc_int(1048576)};
  check_list_bytes(ok(call("Zlib.inflate", 2, args)), abc_bytes, sizeof abc_bytes);
  agc_value empty_args[] = {byte_list(zlib_empty, sizeof zlib_empty), agc_int(1048576)};
  assert(agc_list_len(agc_as_list(&vm, ok(call("Zlib.inflate", 2, empty_args)))) == 0);
  agc_value gz[] = {byte_list(zlib_vec_gzip_abc, sizeof zlib_vec_gzip_abc), agc_int(1048576)};
  check_list_bytes(ok(call("Zlib.gunzip", 2, gz)), abc_bytes, sizeof abc_bytes);
  /* An exact output bound succeeds; one byte less fails. */
  agc_value fit[] = {byte_list(zlib_abc, sizeof zlib_abc), agc_int(3)};
  check_list_bytes(ok(call("Zlib.inflate", 2, fit)), abc_bytes, sizeof abc_bytes);
  agc_value tight[] = {byte_list(zlib_abc, sizeof zlib_abc), agc_int(2)};
  check_error(call("Zlib.inflate", 2, tight), "zlib: output exceeds max_bytes");
  /* Empty compressed input fails; truncation never succeeds. */
  agc_value empty_in[] = {byte_list(NULL, 0), agc_int(100)};
  check_error(call("Zlib.inflate", 2, empty_in), "zlib: invalid compressed data");
  check_error(call("Zlib.gunzip", 2, empty_in), "zlib: invalid compressed data");
  agc_value half[] = {byte_list(zlib_abc, sizeof zlib_abc / 2), agc_int(100)};
  check_error(call("Zlib.inflate", 2, half), "zlib: truncated stream");
  /* How a broken body surfaces (format or checksum) is the codec's own
     business; a broken header, checksum and length each have their error. */
  uint8_t broken[sizeof zlib_abc];
  memcpy(broken, zlib_abc, sizeof broken);
  broken[sizeof broken / 2] ^= 0x01;
  agc_value corrupt[] = {byte_list(broken, sizeof broken), agc_int(100)};
  assert(!agc_as_result(&vm, call("Zlib.inflate", 2, corrupt))->ok);
  memcpy(broken, zlib_abc, sizeof broken);
  broken[0] ^= 0x01;
  corrupt[0] = byte_list(broken, sizeof broken);
  check_error(call("Zlib.inflate", 2, corrupt), "zlib: invalid compressed data");
  memcpy(broken, zlib_abc, sizeof broken);
  broken[sizeof broken - 1] ^= 0x01;
  corrupt[0] = byte_list(broken, sizeof broken);
  check_error(call("Zlib.inflate", 2, corrupt), "zlib: checksum mismatch");
  uint8_t gz_broken[sizeof zlib_vec_gzip_abc];
  memcpy(gz_broken, zlib_vec_gzip_abc, sizeof gz_broken);
  gz_broken[sizeof gz_broken - 8] ^= 0x01;
  agc_value gz_crc[] = {byte_list(gz_broken, sizeof gz_broken), agc_int(100)};
  check_error(call("Zlib.gunzip", 2, gz_crc), "zlib: checksum mismatch");
  memcpy(gz_broken, zlib_vec_gzip_abc, sizeof gz_broken);
  gz_broken[sizeof gz_broken - 1] ^= 0x01;
  gz_crc[0] = byte_list(gz_broken, sizeof gz_broken);
  check_error(call("Zlib.gunzip", 2, gz_crc), "zlib: checksum mismatch");
  /* Trailing bytes stay caller-owned in spirit: one-shot calls refuse them,
     zeros and second members alike. */
  static uint8_t trailed[sizeof zlib_abc + 1];
  memcpy(trailed, zlib_abc, sizeof zlib_abc);
  trailed[sizeof zlib_abc] = 0x00;
  agc_value trailing[] = {byte_list(trailed, sizeof trailed), agc_int(100)};
  check_error(call("Zlib.inflate", 2, trailing), "zlib: trailing bytes after stream end");
  static uint8_t doubled[2 * sizeof zlib_abc];
  memcpy(doubled, zlib_abc, sizeof zlib_abc);
  memcpy(doubled + sizeof zlib_abc, zlib_abc, sizeof zlib_abc);
  agc_value concat[] = {byte_list(doubled, sizeof doubled), agc_int(100)};
  check_error(call("Zlib.inflate", 2, concat), "zlib: trailing bytes after stream end");
  /* Each wrapper decodes only itself: gzip rejects zlib, zlib rejects gzip
     and raw. */
  agc_value wrapped[] = {byte_list(zlib_vec_gzip_abc, sizeof zlib_vec_gzip_abc), agc_int(100)};
  check_error(call("Zlib.inflate", 2, wrapped), "zlib: invalid compressed data");
  agc_value zlib_in_gz[] = {byte_list(zlib_abc, sizeof zlib_abc), agc_int(100)};
  check_error(call("Zlib.gunzip", 2, zlib_in_gz), "zlib: invalid compressed data");
  agc_value raw[] = {byte_list(zlib_vec_raw_abc, sizeof zlib_vec_raw_abc), agc_int(100)};
  check_error(call("Zlib.inflate", 2, raw), "zlib: invalid compressed data");
  uint8_t bad_magic[sizeof zlib_vec_gzip_abc];
  memcpy(bad_magic, zlib_vec_gzip_abc, sizeof bad_magic);
  bad_magic[0] = 0x1e;
  agc_value magic[] = {byte_list(bad_magic, sizeof bad_magic), agc_int(100)};
  check_error(call("Zlib.gunzip", 2, magic), "zlib: invalid compressed data");
}

/* Zlib.crc32 against the published check value: "123456789" from seed 0 is
   3421780262. Empty input returns the seed unchanged (even all-ones: the
   codec helper never sees the empty call, since zlib would reset it to
   zero), and chaining after the previous result matches a single pass. */
static void test_crc32(void) {
  static const uint8_t digits[] = "123456789";
  assert(agc_zlib_crc32(0, NULL, 0) == 0);
  assert(agc_zlib_crc32(0xffffffffu, NULL, 0) == 0xffffffffu);
  assert(agc_zlib_crc32(0, digits, sizeof digits - 1) == 3421780262u);
  agc_value whole[] = {byte_list(digits, sizeof digits - 1), agc_int(0)};
  int64_t full = agc_as_int(&vm, ok(call("Zlib.crc32", 2, whole)));
  assert(full == 3421780262LL);
  /* Empty input returns the seed, including all-ones. */
  agc_value empty0[] = {byte_list(NULL, 0), agc_int(0)};
  assert(agc_as_int(&vm, ok(call("Zlib.crc32", 2, empty0))) == 0);
  agc_value empty_ones[] = {byte_list(NULL, 0), agc_int(4294967295LL)};
  assert(agc_as_int(&vm, ok(call("Zlib.crc32", 2, empty_ones))) == 4294967295LL);
  /* Incremental: the second chunk chained after the first matches one pass. */
  agc_value first[] = {byte_list(digits, 3), agc_int(0)};
  int64_t head = agc_as_int(&vm, ok(call("Zlib.crc32", 2, first)));
  agc_value rest[] = {byte_list(digits + 3, sizeof digits - 1 - 3), agc_int(head)};
  assert(agc_as_int(&vm, ok(call("Zlib.crc32", 2, rest))) == full);
  /* NUL and binary bytes hash like any other byte. */
  static const uint8_t binary[] = {0x00, 0xff, 0x00, 0x80, 0x01};
  agc_value bin[] = {byte_list(binary, sizeof binary), agc_int(0)};
  assert(agc_as_int(&vm, ok(call("Zlib.crc32", 2, bin))) ==
         (int64_t)agc_zlib_crc32(0, binary, sizeof binary));
  /* A bad seed, a bad byte and an over-long input are the call's errors. */
  agc_value low_seed[] = {byte_list(digits, 3), agc_int(-1)};
  check_error(call("Zlib.crc32", 2, low_seed), "zlib: seed must be between 0 and 4294967295");
  agc_value high_seed[] = {byte_list(digits, 3), agc_int(4294967296LL)};
  check_error(call("Zlib.crc32", 2, high_seed), "zlib: seed must be between 0 and 4294967295");
  agc_list_builder bad;
  agc_list_builder_sized(&bad, 2);
  agc_list_builder_push(&bad, agc_int(0x61));
  agc_list_builder_push(&bad, agc_int(256));
  agc_value bad_data[] = {agc_list_value(agc_list_builder_finish(&bad)), agc_int(0)};
  check_error(call("Zlib.crc32", 2, bad_data), "zlib: bytes must be between 0 and 255");
  static uint8_t big[1048577] = {0};
  agc_value huge = byte_list(big, sizeof big);
  agc_value big_args[] = {huge, agc_int(0)};
  check_error(call("Zlib.crc32", 2, big_args), "zlib: input exceeds 1048576 bytes");
}

static void sink_put(agc_vm *v, sink *s, agc_value chunk) {
  if (agc_is(chunk, AGC_T_VOID)) return;
  const agc_list *l = agc_as_list(v, chunk);
  size_t n = agc_list_len(l);
  assert(n > 0 && n <= 65536);
  if (n > s->largest) s->largest = n;
  if (s->len + n > s->cap) {
    s->cap = (s->len + n) * 2;
    s->data = realloc(s->data, s->cap);
    if (!s->data) agc_out_of_memory();
  }
  for (size_t k = 0; k < n; k++) s->data[s->len++] = (uint8_t)agc_as_int(v, agc_list_get(l, k));
}

static const uint8_t no_bytes[1] = {0};

/* Feeds IN to the stream in pieces of STEP bytes (an empty item before each
   piece when EMPTIES), then finishes, as vm/lazy.c drives a step: AGAIN runs
   again over what is left of the piece, INPUT and END take the next one.
   Returns the last status; *error is the error Result of a FAILED one. */
static agc_zstep_status pump(agc_vm *v, agc_resource *r, const uint8_t *in, size_t len, size_t step, bool empties,
                             sink *s, agc_value *error) {
  for (size_t at = 0;; at += step) {
    bool finish = at >= len;
    size_t take = finish ? 0 : (len - at < step ? len - at : step);
    for (int round = empties && !finish ? 0 : 1; round < 2; round++) {
      size_t piece = round == 0 ? 0 : take, off = 0;
      const uint8_t *base = piece ? in + at : no_bytes;
      for (;;) {
        size_t used;
        agc_value out;
        agc_zstep_status status = agc_zstep_next(v, r, base + off, piece - off, &used, finish, &out);
        off += used;
        if (status == AGC_ZSTEP_FAILED) {
          *error = out;
          return status;
        }
        sink_put(v, s, out);
        if (status != AGC_ZSTEP_AGAIN) {
          assert(off == piece);
          if (finish) return status;
          break;
        }
      }
    }
  }
}

/* One stream of KIND over IN, opened, pumped and closed. */
static agc_zstep_status run_step(int64_t kind, int64_t level, int64_t max_bytes, const uint8_t *in, size_t len,
                                 size_t step, sink *s, agc_value *error) {
  agc_resource *r = agc_zstep_open(&vm, kind, level, max_bytes);
  agc_zstep_status status = pump(&vm, r, in, len, step, false, s, error);
  agc_zstep_close(&vm, r);
  assert(r->native == NULL);
  return status;
}

static void check_step_error(agc_zstep_status status, agc_value error, const char *message) {
  assert(status == AGC_ZSTEP_FAILED);
  check_error(error, message);
}

/* A zlib decoder over two-byte chunks and a two-byte output quantum: unused
   input stays caller-owned through consumed, and the verified end reports
   finished with the checksum checked. */
static void test_stream_decode(void) {
  agc_value init[] = {agc_int(15), agc_int(100), agc_int(100)};
  agc_value dec = ok(call("Zlib.inflate_init", 3, init));
  /* An empty feed while awaiting input drains nothing and fails nothing. */
  agc_value drain[] = {dec, byte_list(NULL, 0), agc_int(64)};
  check_progress(progress_of(call("Zlib.inflate_next", 3, drain)), 0, 0, false, true);
  uint8_t gathered[64];
  size_t total = 0, at = 0;
  bool done = false;
  while (!done) {
    size_t take = sizeof zlib_abc - at > 2 ? 2 : sizeof zlib_abc - at;
    agc_value feed[] = {dec, byte_list(zlib_abc + at, take), agc_int(2)};
    const agc_struct *p = progress_of(call("Zlib.inflate_next", 3, feed));
    int64_t consumed = agc_as_int(&vm, p->fields[1]);
    assert(consumed >= 0 && (size_t)consumed <= take);
    at += (size_t)consumed;
    done = agc_as_bool(&vm, p->fields[2]);
    const agc_list *out = agc_as_list(&vm, p->fields[0]);
    for (size_t j = 0; j < agc_list_len(out); j++) gathered[total++] = (uint8_t)agc_as_int(&vm, agc_list_get(out, j));
    /* needs_input is false while output may still drain: with a full two
       bytes out, the caller drains before feeding more. */
    if (!done) assert(agc_as_bool(&vm, p->fields[3]) == (agc_list_len(out) < 2 && (size_t)consumed == take));
  }
  assert(total == sizeof abc_bytes && memcmp(gathered, abc_bytes, total) == 0);
  agc_value finish[] = {dec};
  assert(agc_as_result(&vm, call("Zlib.inflate_finish", 1, finish))->ok);
  assert(agc_as_result(&vm, call("Zlib.inflate_finish", 1, finish))->ok);
  check_progress(progress_of(call("Zlib.inflate_next", 3, drain)), 0, 0, true, false);
  agc_value late[] = {dec, byte_list(abc_bytes, 1), agc_int(64)};
  check_error(call("Zlib.inflate_next", 3, late), "zlib: stream already finished");
  agc_value close[] = {dec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, close))->ok);
}

/* Finishing before the verified end is a truncation, and trailing input is
   never discarded: the last feed reports it through consumed. */
static void test_stream_truncation_trailing(void) {
  agc_value init[] = {agc_int(31), agc_int(100), agc_int(100)};
  agc_value dec = ok(call("Zlib.inflate_init", 3, init));
  agc_value finish[] = {dec};
  check_error(call("Zlib.inflate_finish", 1, finish), "zlib: stream is truncated");
  agc_value half[] = {dec, byte_list(zlib_vec_gzip_abc, sizeof zlib_vec_gzip_abc / 2), agc_int(64)};
  const agc_struct *p = progress_of(call("Zlib.inflate_next", 3, half));
  assert(!agc_as_bool(&vm, p->fields[2]));
  assert(agc_as_int(&vm, p->fields[1]) == (int64_t)(sizeof zlib_vec_gzip_abc / 2));
  check_error(call("Zlib.inflate_finish", 1, finish), "zlib: stream is truncated");
  static uint8_t trailed[sizeof zlib_vec_gzip_abc + 1];
  memcpy(trailed, zlib_vec_gzip_abc, sizeof zlib_vec_gzip_abc);
  trailed[sizeof zlib_vec_gzip_abc] = 0x00;
  size_t first_half = sizeof zlib_vec_gzip_abc / 2;
  agc_value full[] = {dec, byte_list(trailed + first_half, sizeof trailed - first_half), agc_int(64)};
  const agc_struct *end = progress_of(call("Zlib.inflate_next", 3, full));
  assert(agc_as_bool(&vm, end->fields[2]));
  /* The trailing zero stays with the caller: consumed stops at the member. */
  assert(agc_as_int(&vm, end->fields[1]) == (int64_t)(sizeof zlib_vec_gzip_abc - first_half));
  uint8_t gathered[8];
  size_t total = 0;
  for (uint32_t f = 0; f < 2; f++) {
    const agc_list *out = agc_as_list(&vm, (f == 0 ? p : end)->fields[0]);
    for (size_t j = 0; j < agc_list_len(out); j++) gathered[total++] = (uint8_t)agc_as_int(&vm, agc_list_get(out, j));
  }
  assert(total == sizeof abc_bytes && memcmp(gathered, abc_bytes, total) == 0);
  assert(agc_as_result(&vm, call("Zlib.inflate_finish", 1, finish))->ok);
  agc_value close[] = {dec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, close))->ok);
}

/* A decoder whose output budget exactly fits the payload must still reach
   the verified end: the wrapper trailer (or a raw final empty block)
   produces no bytes, so once the budget is full a bounded one-byte probe
   consumes it, whatever quantum the call asked for. A byte past the full
   budget instead fails the handle without leaking the probe byte, and the
   trailer error and input-cap legs stay errors. */
static void test_stream_decoder_full_budget(void) {
  /* gzip "abc" with a 3-byte budget, the 8-byte trailer split into a later
     chunk: the payload call is not done yet, then the trailer call
     finishes with no output. */
  agc_value init[] = {agc_int(31), agc_int(100), agc_int(3)};
  agc_value dec = ok(call("Zlib.inflate_init", 3, init));
  agc_value head[] = {dec, byte_list(zlib_vec_gzip_abc, 15), agc_int(3)};
  const agc_struct *first = progress_of(call("Zlib.inflate_next", 3, head));
  check_progress(first, 3, 15, false, false);
  check_list_bytes(first->fields[0], abc_bytes, sizeof abc_bytes);
  /* A 1-byte quantum finishes the trailer... */
  agc_value tail[] = {dec, byte_list(zlib_vec_gzip_abc + 15, sizeof zlib_vec_gzip_abc - 15), agc_int(1)};
  const agc_struct *end = progress_of(call("Zlib.inflate_next", 3, tail));
  check_progress(end, 0, 8, true, false);
  agc_value finish[] = {dec};
  assert(agc_as_result(&vm, call("Zlib.inflate_finish", 1, finish))->ok);
  agc_value close[] = {dec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, close))->ok);
  /* ... and so does a full 64 KiB quantum: the probe runs a private byte,
     never the requested quantum with no room. */
  agc_value dec_big = ok(call("Zlib.inflate_init", 3, init));
  agc_value head_big[] = {dec_big, byte_list(zlib_vec_gzip_abc, 15), agc_int(3)};
  check_progress(progress_of(call("Zlib.inflate_next", 3, head_big)), 3, 15, false, false);
  agc_value tail_big[] = {dec_big, byte_list(zlib_vec_gzip_abc + 15, sizeof zlib_vec_gzip_abc - 15),
                          agc_int(65536)};
  check_progress(progress_of(call("Zlib.inflate_next", 3, tail_big)), 0, 8, true, false);
  agc_value finish_big[] = {dec_big};
  assert(agc_as_result(&vm, call("Zlib.inflate_finish", 1, finish_big))->ok);
  agc_value close_big[] = {dec_big};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, close_big))->ok);
  /* The zlib wrapper splits the same way: 7 payload bytes, then the 4-byte
     Adler trailer at the full budget. */
  agc_value zinit[] = {agc_int(15), agc_int(100), agc_int(3)};
  agc_value zdec = ok(call("Zlib.inflate_init", 3, zinit));
  agc_value zhead[] = {zdec, byte_list(zlib_abc, 7), agc_int(3)};
  const agc_struct *zfirst = progress_of(call("Zlib.inflate_next", 3, zhead));
  check_progress(zfirst, 3, 7, false, false);
  check_list_bytes(zfirst->fields[0], abc_bytes, sizeof abc_bytes);
  agc_value ztail[] = {zdec, byte_list(zlib_abc + 7, sizeof zlib_abc - 7), agc_int(1)};
  check_progress(progress_of(call("Zlib.inflate_next", 3, ztail)), 0, 4, true, false);
  agc_value zfinish[] = {zdec};
  assert(agc_as_result(&vm, call("Zlib.inflate_finish", 1, zfinish))->ok);
  agc_value zclose[] = {zdec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, zclose))->ok);
  /* Raw has no trailer, but its final empty block still needs a zero-output
     termination once the budget is full. */
  agc_value rinit[] = {agc_int(-15), agc_int(100), agc_int(3)};
  agc_value rdec = ok(call("Zlib.inflate_init", 3, rinit));
  agc_value rhead[] = {rdec, byte_list(zlib_vec_raw_abc, 4), agc_int(3)};
  const agc_struct *rfirst = progress_of(call("Zlib.inflate_next", 3, rhead));
  check_progress(rfirst, 3, 4, false, false);
  check_list_bytes(rfirst->fields[0], abc_bytes, sizeof abc_bytes);
  agc_value rtail[] = {rdec, byte_list(zlib_vec_raw_abc + 4, sizeof zlib_vec_raw_abc - 4), agc_int(1)};
  check_progress(progress_of(call("Zlib.inflate_next", 3, rtail)), 0, 1, true, false);
  agc_value rfinish[] = {rdec};
  assert(agc_as_result(&vm, call("Zlib.inflate_finish", 1, rfinish))->ok);
  agc_value rclose[] = {rdec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, rclose))->ok);
  /* One byte at a time with a 1-byte quantum and an exact budget: only the
     trailer call is done, the gathered output is exactly the payload, and
     the end verifies. */
  agc_value binit[] = {agc_int(31), agc_int(100), agc_int(3)};
  agc_value bdec = ok(call("Zlib.inflate_init", 3, binit));
  uint8_t gathered[8];
  size_t total = 0;
  bool done = false;
  for (size_t at = 0; at < sizeof zlib_vec_gzip_abc; at++) {
    agc_value feed[] = {bdec, byte_list(zlib_vec_gzip_abc + at, 1), agc_int(1)};
    const agc_struct *p = progress_of(call("Zlib.inflate_next", 3, feed));
    assert(agc_as_int(&vm, p->fields[1]) <= 1);
    done = agc_as_bool(&vm, p->fields[2]);
    assert(done == (at == sizeof zlib_vec_gzip_abc - 1));
    gather(&vm, p, gathered, &total);
  }
  assert(total == sizeof abc_bytes && memcmp(gathered, abc_bytes, total) == 0);
  agc_value bfinish[] = {bdec};
  assert(agc_as_result(&vm, call("Zlib.inflate_finish", 1, bfinish))->ok);
  agc_value bclose[] = {bdec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, bclose))->ok);
  /* A genuine overflow past the full budget fails sticky: with a 2-byte
     budget the third payload byte never leaks, and the handle never
     resumes. */
  agc_value oinit[] = {agc_int(31), agc_int(100), agc_int(2)};
  agc_value odec = ok(call("Zlib.inflate_init", 3, oinit));
  uint8_t kept[8];
  size_t kept_total = 0;
  bool overflowed = false;
  for (size_t at = 0; at < sizeof zlib_vec_gzip_abc; at++) {
    agc_value feed[] = {odec, byte_list(zlib_vec_gzip_abc + at, 1), agc_int(1)};
    agc_value result = call("Zlib.inflate_next", 3, feed);
    if (!agc_as_result(&vm, result)->ok) {
      check_error(result, "zlib: total output exceeds max_total_out");
      overflowed = true;
      break;
    }
    gather(&vm, agc_as_struct(&vm, ok(result)), kept, &kept_total);
  }
  assert(overflowed);
  assert(kept_total == 2 && memcmp(kept, abc_bytes, kept_total) == 0);
  agc_value retry[] = {odec, byte_list(zlib_vec_gzip_abc, 1), agc_int(1)};
  check_error(call("Zlib.inflate_next", 3, retry), "zlib: handle failed");
  agc_value ofinish[] = {odec};
  check_error(call("Zlib.inflate_finish", 1, ofinish), "zlib: handle failed");
  agc_value oclose[] = {odec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, oclose))->ok);
  /* A corrupt trailer at the full budget is still a checksum failure, and a
     truncated one still truncates: the probe changes neither verdict. */
  uint8_t bad[sizeof zlib_vec_gzip_abc];
  memcpy(bad, zlib_vec_gzip_abc, sizeof bad);
  bad[sizeof bad - 1] ^= 0x01;
  agc_value cdec = ok(call("Zlib.inflate_init", 3, init));
  agc_value chead[] = {cdec, byte_list(bad, 15), agc_int(3)};
  check_progress(progress_of(call("Zlib.inflate_next", 3, chead)), 3, 15, false, false);
  agc_value ctail[] = {cdec, byte_list(bad + 15, sizeof bad - 15), agc_int(1)};
  check_error(call("Zlib.inflate_next", 3, ctail), "zlib: checksum mismatch");
  check_error(call("Zlib.inflate_next", 3, ctail), "zlib: handle failed");
  agc_value cclose[] = {cdec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, cclose))->ok);
  agc_value tdec = ok(call("Zlib.inflate_init", 3, init));
  agc_value thead[] = {tdec, byte_list(zlib_vec_gzip_abc, 15), agc_int(3)};
  check_progress(progress_of(call("Zlib.inflate_next", 3, thead)), 3, 15, false, false);
  agc_value ttail[] = {tdec, byte_list(zlib_vec_gzip_abc + 15, 4), agc_int(1)};
  check_progress(progress_of(call("Zlib.inflate_next", 3, ttail)), 0, 4, false, true);
  agc_value tfinish[] = {tdec};
  check_error(call("Zlib.inflate_finish", 1, tfinish), "zlib: stream is truncated");
  agc_value tclose[] = {tdec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, tclose))->ok);
  /* The input total cap is still enforced before any probe runs. */
  agc_value sinit[] = {agc_int(15), agc_int(5), agc_int(100)};
  agc_value sdec = ok(call("Zlib.inflate_init", 3, sinit));
  agc_value over[] = {sdec, byte_list(zlib_abc, 6), agc_int(100)};
  check_error(call("Zlib.inflate_next", 3, over), "zlib: total input exceeds max_total_in");
  agc_value sclose[] = {sdec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, sclose))->ok);
}

/* A bad level is an encoder's error and a bad max_bytes a decoder's; each
   kind ignores the other argument. Lazy max_bytes has no upper bound. */
static void test_zstep_check(void) {
  check_error(agc_zstep_check(0, 10, 1), "zlib: level must be between 0 and 9");
  check_error(agc_zstep_check(2, -1, 1), "zlib: level must be between 0 and 9");
  check_error(agc_zstep_check(3, 6, 0), "zlib: max_bytes must be at least 1");
  check_error(agc_zstep_check(5, 6, -1), "zlib: max_bytes must be at least 1");
  assert(agc_is(agc_zstep_check(1, 9, 0), AGC_T_VOID));
  assert(agc_is(agc_zstep_check(4, 99, INT64_MAX), AGC_T_VOID));
}

/* The streams write and read the independent vectors byte for byte, the
   decoders one byte at a time. */
static void test_zstep_vectors(void) {
  sink s = {0};
  agc_value error = agc_void();
  assert(run_step(0, 6, 0, abc_bytes, sizeof abc_bytes, 1, &s, &error) == AGC_ZSTEP_END);
  assert(s.len == sizeof zlib_abc && memcmp(s.data, zlib_abc, s.len) == 0);
  s.len = 0;
  assert(run_step(0, 0, 0, abc_bytes, sizeof abc_bytes, 3, &s, &error) == AGC_ZSTEP_END);
  assert(s.len == sizeof zlib_abc_l0 && memcmp(s.data, zlib_abc_l0, s.len) == 0);
  s.len = 0;
  assert(run_step(1, 6, 0, abc_bytes, sizeof abc_bytes, 3, &s, &error) == AGC_ZSTEP_END);
  assert(s.len == sizeof zlib_vec_raw_abc && memcmp(s.data, zlib_vec_raw_abc, s.len) == 0);
  s.len = 0;
  assert(run_step(0, 6, 0, NULL, 0, 1, &s, &error) == AGC_ZSTEP_END);
  assert(s.len == sizeof zlib_empty && memcmp(s.data, zlib_empty, s.len) == 0);
  struct {
    int64_t kind;
    const uint8_t *data;
    size_t len;
  } decodes[] = {{3, zlib_abc, sizeof zlib_abc}, {4, zlib_vec_raw_abc, sizeof zlib_vec_raw_abc},
                 {5, zlib_vec_gzip_abc, sizeof zlib_vec_gzip_abc}};
  for (size_t k = 0; k < sizeof decodes / sizeof decodes[0]; k++) {
    s.len = 0;
    assert(run_step(decodes[k].kind, 0, 100, decodes[k].data, decodes[k].len, 1, &s, &error) == AGC_ZSTEP_END);
    assert(s.len == 3 && memcmp(s.data, abc_bytes, 3) == 0);
  }
  s.len = 0;
  assert(run_step(5, 0, 1, zlib_vec_gzip_empty, sizeof zlib_vec_gzip_empty, 4, &s, &error) == AGC_ZSTEP_END);
  assert(s.len == 0);
  free(s.data);
}

/* Each wrapper round-trips a 300 KB mix of noise and zeros at levels 0, 6
   and 9, in pieces around the 64 KiB quantum and with empty items between
   them; no chunk passes the quantum. */
static void test_zstep_round_trip(void) {
  enum { TOTAL = 300000 };
  static uint8_t plain[TOTAL];
  uint32_t seed = 12345;
  for (size_t k = 0; k < TOTAL; k++) {
    seed = seed * 1103515245u + 12345u;
    plain[k] = k % 100000 < 50000 ? (uint8_t)(seed >> 16) : 0;
  }
  size_t steps[] = {7, 65536, 65537, TOTAL};
  int64_t levels[] = {0, 6, 9};
  for (int64_t enc = 0; enc < 3; enc++)
    for (size_t l = 0; l < 3; l++)
      for (size_t k = 0; k < 4; k++) {
        sink coded = {0}, back = {0};
        agc_value error = agc_void();
        agc_resource *r = agc_zstep_open(&vm, enc, levels[l], 0);
        assert(pump(&vm, r, plain, TOTAL, steps[k], k == 0, &coded, &error) == AGC_ZSTEP_END);
        agc_zstep_close(&vm, r);
        r = agc_zstep_open(&vm, enc + 3, 0, TOTAL);
        assert(pump(&vm, r, coded.data, coded.len, steps[3 - k], k == 1, &back, &error) == AGC_ZSTEP_END);
        agc_zstep_close(&vm, r);
        assert(back.len == TOTAL && memcmp(back.data, plain, TOTAL) == 0);
        assert(k != 0 || back.largest == 65536);
        free(coded.data);
        free(back.data);
      }
}

/* max_bytes holds while streaming: an exact budget ends, one byte less
   fails, and a 3 MiB zero bomb stops at its cap with no more than the cap
   handed out. */
static void test_zstep_caps(void) {
  sink s = {0};
  agc_value error = agc_void();
  assert(run_step(3, 0, 3, zlib_abc, sizeof zlib_abc, 1, &s, &error) == AGC_ZSTEP_END);
  assert(s.len == 3);
  s.len = 0;
  check_step_error(run_step(3, 0, 2, zlib_abc, sizeof zlib_abc, 1, &s, &error), error,
                   "zlib: output exceeds max_bytes");
  assert(s.len <= 2);
  enum { BOMB = 3 << 20 };
  static uint8_t zeros[BOMB];
  sink coded = {0};
  assert(run_step(2, 9, 0, zeros, BOMB, BOMB, &coded, &error) == AGC_ZSTEP_END);
  assert(coded.len < 8192);
  s.len = 0;
  check_step_error(run_step(5, 0, 1048576, coded.data, coded.len, 512, &s, &error), error,
                   "zlib: output exceeds max_bytes");
  assert(s.len <= 1048576);
  s.len = 0;
  assert(run_step(5, 0, BOMB, coded.data, coded.len, 512, &s, &error) == AGC_ZSTEP_END && s.len == BOMB);
  free(coded.data);
  free(s.data);
}

/* The decoders are strict: one stream, its checksum, and no byte after it,
   whether the byte shares the last piece or comes in a later one. Empty
   items after the end are fine. */
static void test_zstep_strict(void) {
  sink s = {0};
  agc_value error = agc_void();
  uint8_t buf[2 * sizeof zlib_abc];
  memcpy(buf, zlib_abc, sizeof zlib_abc);
  buf[sizeof zlib_abc] = 0;
  check_step_error(run_step(3, 0, 100, buf, sizeof zlib_abc + 1, sizeof zlib_abc + 1, &s, &error), error,
                   "zlib: trailing bytes after stream end");
  check_step_error(run_step(3, 0, 100, buf, sizeof zlib_abc + 1, sizeof zlib_abc, &s, &error), error,
                   "zlib: trailing bytes after stream end");
  memcpy(buf + sizeof zlib_abc, zlib_abc, sizeof zlib_abc);
  check_step_error(run_step(3, 0, 100, buf, sizeof buf, 1, &s, &error), error,
                   "zlib: trailing bytes after stream end");
  agc_resource *r = agc_zstep_open(&vm, 3, 0, 100);
  assert(pump(&vm, r, zlib_abc, sizeof zlib_abc, 2, true, &s, &error) == AGC_ZSTEP_END);
  size_t used;
  assert(agc_zstep_next(&vm, r, no_bytes, 0, &used, false, &error) == AGC_ZSTEP_END);
  assert(agc_zstep_next(&vm, r, no_bytes, 0, &used, true, &error) == AGC_ZSTEP_END);
  agc_zstep_close(&vm, r);
  check_step_error(run_step(3, 0, 100, zlib_abc, sizeof zlib_abc / 2, 1, &s, &error), error,
                   "zlib: truncated stream");
  check_step_error(run_step(5, 0, 100, NULL, 0, 1, &s, &error), error, "zlib: truncated stream");
  memcpy(buf, zlib_abc, sizeof zlib_abc);
  buf[sizeof zlib_abc - 1] ^= 0x01;
  check_step_error(run_step(3, 0, 100, buf, sizeof zlib_abc, 1, &s, &error), error, "zlib: checksum mismatch");
  uint8_t gz[sizeof zlib_vec_gzip_abc];
  memcpy(gz, zlib_vec_gzip_abc, sizeof gz);
  gz[sizeof gz - 1] ^= 0x01;
  check_step_error(run_step(5, 0, 100, gz, sizeof gz, 5, &s, &error), error, "zlib: checksum mismatch");
  check_step_error(run_step(3, 0, 100, zlib_vec_gzip_abc, sizeof zlib_vec_gzip_abc, 1, &s, &error), error,
                   "zlib: invalid compressed data");
  check_step_error(run_step(5, 0, 100, zlib_abc, sizeof zlib_abc, 1, &s, &error), error,
                   "zlib: invalid compressed data");
  free(s.data);
}

/* A stream is a registry entry its task owns: close is idempotent, the
   task's end frees what the run did not, and a pass over a freed stream is
   an internal error, never a use after free. */
static void test_zstep_lifetime(void) {
  agc_resource *r = agc_zstep_open(&vm, 0, 6, 0);
  agc_zstep_close(&vm, r);
  agc_zstep_close(&vm, r);
  assert(r->native == NULL);
  agc_task *main_task = vm.task;
  agc_task *other = agc_new_task(&vm);
  vm.task = other;
  agc_resource *owned[2] = {agc_zstep_open(&vm, 2, 6, 0), agc_zstep_open(&vm, 5, 0, 10)};
  vm.task = main_task;
  agc_close_owned(&vm, other);
  assert(owned[0]->native == NULL && owned[1]->native == NULL);
  agc_zstep_close(&vm, owned[0]);
  vm.in_turn = false;
  if (setjmp(vm.fail) == 0) {
    size_t used;
    agc_value out;
    (void)agc_zstep_next(&vm, owned[1], abc_bytes, 1, &used, false, &out);
    assert(!"the pass did not fail");
  }
  assert(strcmp(vm.outcome->code, "RUNTIME-INTERNAL") == 0);
  vm.task = main_task;
  vm.in_turn = true;
}

/* Eight threads on one shared VM open, pump and close private streams with
   exact asserts while the main thread does the same: the registry and the
   owner lists change under rt->sync only. Each thread's last round leaves
   its streams open for its task's end. */
#define ZLIB_THREADS 8
#define ZLIB_ROUNDS 40

static agc_vm workers[ZLIB_THREADS];
static agc_task *worker_tasks[ZLIB_THREADS];
static uv_barrier_t worker_gate;
static _Atomic int unexpected;

static void round_trip(agc_vm *v, intptr_t seed, bool leave_open) {
  uint8_t pattern[513];
  for (size_t k = 0; k < sizeof pattern; k++) pattern[k] = (uint8_t)((seed * 131 + k * 17) & 0xff);
  sink coded = {0}, back = {0};
  agc_value error = agc_void();
  int64_t kind = seed % 3;
  agc_resource *enc = agc_zstep_open(v, kind, 6, 0);
  agc_resource *dec = agc_zstep_open(v, kind + 3, 0, sizeof pattern);
  if (pump(v, enc, pattern, sizeof pattern, 100, false, &coded, &error) != AGC_ZSTEP_END ||
      pump(v, dec, coded.data, coded.len, 7, false, &back, &error) != AGC_ZSTEP_END || back.len != sizeof pattern ||
      memcmp(back.data, pattern, sizeof pattern) != 0)
    atomic_fetch_add(&unexpected, 1);
  free(coded.data);
  free(back.data);
  if (leave_open) return;
  agc_zstep_close(v, enc);
  agc_zstep_close(v, dec);
}

static void zlib_worker(void *arg) {
  intptr_t k = (intptr_t)arg;
  agc_vm *v = &workers[k];
  assert(agc_gc_thread_enter());
  v->in_turn = true;
  v->task = worker_tasks[k];
  uv_barrier_wait(&worker_gate);
  for (int r = 0; r < ZLIB_ROUNDS; r++) round_trip(v, k * ZLIB_ROUNDS + r + 1, r == ZLIB_ROUNDS - 1);
  agc_sync_take(v);
  agc_close_owned(v, worker_tasks[k]);
  agc_sync_drop(v);
  agc_gc_thread_leave();
}

static void test_concurrent(void) {
  for (int k = 0; k < ZLIB_THREADS; k++) {
    workers[k] = vm;
    worker_tasks[k] = agc_new_task(&workers[k]);
  }
  assert(uv_barrier_init(&worker_gate, ZLIB_THREADS + 1) == 0);
  uv_thread_t threads[ZLIB_THREADS];
  for (intptr_t k = 0; k < ZLIB_THREADS; k++) assert(uv_thread_create(&threads[k], zlib_worker, (void *)k) == 0);
  uv_barrier_wait(&worker_gate);
  for (int r = 0; r < ZLIB_ROUNDS; r++) round_trip(&vm, 1000 + r, false);
  for (int k = 0; k < ZLIB_THREADS; k++) assert(uv_thread_join(&threads[k]) == 0);
  uv_barrier_destroy(&worker_gate);
  assert(atomic_load(&unexpected) == 0);
}

int main(void) {
  agc_test_deadline(120);
  agc_init();
  agc_io_init();
  static const char *const names[] = {"output", "consumed", "finished", "needs_input"};
  for (size_t k = 0; k < 4; k++) progress_names[k] = agc_make_string(names[k], strlen(names[k]), strlen(names[k]));
  progress_def.name = agc_make_string("ZlibProgress", 12, 12);
  progress_def.count = 4;
  progress_def.fields = progress_names;
  program.structs = &progress_def;
  program.struct_count = 1;
  agc_vm_init(&vm, &program, stdout, stderr, INT64_MAX);
  vm.in_turn = true;
  test_table();
  test_oneshot_compress();
  test_oneshot_decode();
  test_crc32();
  test_stream_decode();
  test_stream_truncation_trailing();
  test_stream_decoder_full_budget();
  test_zstep_check();
  test_zstep_vectors();
  test_zstep_round_trip();
  test_zstep_caps();
  test_zstep_strict();
  test_zstep_lifetime();
  /* The shared phase: one lock for tasks and the registry, which agc_zstep_open
     and agc_zstep_close take like the unlocked Lazy terminal does. */
  agc_share(&vm);
  agc_gc_allow_threads();
  test_concurrent();
  agc_close_owned(&vm, vm.task);
  assert(agc_io_close(&vm));
  puts("zlib tests passed");
  return 0;
}

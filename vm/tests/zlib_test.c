/* Zlib bytes, streaming handles and their shared-VM interleavings, against
   independently generated vectors. */
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

/* Python's zlib on "abc" and "" at levels 0, 6 and 9: the exact streams our
   decoder must read and our encoder must write. The gzip and raw members
   live in zlib_vectors.h, shared with the file tests. */
static const uint8_t zlib_abc[] = {0x78, 0x9c, 0x4b, 0x4c, 0x4a, 0x06, 0x00, 0x02, 0x4d, 0x01, 0x27};
static const uint8_t zlib_empty[] = {0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01};
static const uint8_t zlib_abc_l0[] = {0x78, 0x01, 0x01, 0x03, 0x00, 0xfc, 0xff,
  0x61, 0x62, 0x63, 0x02, 0x4d, 0x01, 0x27};
static const uint8_t abc_bytes[] = {0x61, 0x62, 0x63};

/* A call of the named builtin on T of V: with a shared VM the interpreter
   holds rt->sync across a shared row, so the test takes it the same way. No
   Zlib bytes or streaming call parks. */
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

/* The 16 public rows in the contract's order, with their arities and shared
   marks: the one-shot and file calls are pure or pool work, while the
   streaming calls touch the shared registry and run under rt->sync. */
static void test_table(void) {
  struct {
    const char *name;
    uint32_t arity;
    bool shared;
  } expected[] = {
    {"Zlib.deflate", 3, false}, {"Zlib.inflate", 2, false}, {"Zlib.gzip", 3, false}, {"Zlib.gunzip", 2, false},
    {"Zlib.deflate_file", 5, false}, {"Zlib.inflate_file", 4, false}, {"Zlib.gzip_file", 5, false},
    {"Zlib.gunzip_file", 4, false}, {"Zlib.deflate_init", 4, true}, {"Zlib.inflate_init", 3, true},
    {"Zlib.deflate_next", 3, true}, {"Zlib.inflate_next", 3, true}, {"Zlib.deflate_finish", 2, true},
    {"Zlib.inflate_finish", 1, true}, {"Zlib.encoder_close", 1, true}, {"Zlib.decoder_close", 1, true},
  };
  assert(agc_zlib_builtin_count == sizeof expected / sizeof expected[0]);
  for (size_t k = 0; k < sizeof expected / sizeof expected[0]; k++) {
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
  check_error(call("Zlib.deflate", 3, tight), "zlib: output exceeds max_out_bytes");
  agc_value bad_level[] = {data, agc_int(10), agc_int(100)};
  check_error(call("Zlib.deflate", 3, bad_level), "zlib: level must be between 0 and 9");
  bad_level[1] = agc_int(-1);
  check_error(call("Zlib.deflate", 3, bad_level), "zlib: level must be between 0 and 9");
  agc_value bad_max[] = {data, agc_int(6), agc_int(0)};
  check_error(call("Zlib.deflate", 3, bad_max), "zlib: max_out_bytes must be between 1 and 1048576");
  bad_max[2] = agc_int(1048577);
  check_error(call("Zlib.deflate", 3, bad_max), "zlib: max_out_bytes must be between 1 and 1048576");
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
  check_error(call("Zlib.inflate", 2, tight), "zlib: output exceeds max_out_bytes");
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

/* Streaming argument checks: the wrapper selection, level and lifetime caps
   are validated before any state exists. */
static void test_stream_init_checks(void) {
  agc_value bad_window[] = {agc_int(16), agc_int(6), agc_int(100), agc_int(100)};
  check_error(call("Zlib.deflate_init", 4, bad_window), "zlib: window_bits must be 15, -15, or 31");
  bad_window[0] = agc_int(-8);
  check_error(call("Zlib.deflate_init", 4, bad_window), "zlib: window_bits must be 15, -15, or 31");
  agc_value bad_window3[] = {agc_int(0), agc_int(100), agc_int(100)};
  check_error(call("Zlib.inflate_init", 3, bad_window3), "zlib: window_bits must be 15, -15, or 31");
  agc_value bad_level[] = {agc_int(15), agc_int(10), agc_int(100), agc_int(100)};
  check_error(call("Zlib.deflate_init", 4, bad_level), "zlib: level must be between 0 and 9");
  agc_value bad_in[] = {agc_int(15), agc_int(6), agc_int(0), agc_int(100)};
  check_error(call("Zlib.deflate_init", 4, bad_in), "zlib: max_total_in must be between 1 and 1073741824");
  bad_in[2] = agc_int(1073741825);
  check_error(call("Zlib.deflate_init", 4, bad_in), "zlib: max_total_in must be between 1 and 1073741824");
  agc_value bad_out[] = {agc_int(15), agc_int(6), agc_int(100), agc_int(0)};
  check_error(call("Zlib.deflate_init", 4, bad_out), "zlib: max_total_out must be between 1 and 1073741824");
  agc_value bad_out3[] = {agc_int(15), agc_int(100), agc_int(1073741825)};
  check_error(call("Zlib.inflate_init", 3, bad_out3), "zlib: max_total_out must be between 1 and 1073741824");
}

/* A raw encoder round trip in small chunks, drained through repeated bounded
   finish calls: the concatenated output is the independent raw stream. */
static void test_stream_encode(void) {
  agc_value init[] = {agc_int(-15), agc_int(6), agc_int(100), agc_int(100)};
  agc_value enc = ok(call("Zlib.deflate_init", 4, init));
  uint8_t gathered[64];
  size_t total = 0;
  for (size_t k = 0; k < sizeof abc_bytes; k++) {
    agc_value feed[] = {enc, byte_list(abc_bytes + k, 1), agc_int(64)};
    const agc_struct *p = progress_of(call("Zlib.deflate_next", 3, feed));
    check_progress(p, agc_list_len(agc_as_list(&vm, p->fields[0])), 1, false, true);
    const agc_list *out = agc_as_list(&vm, p->fields[0]);
    for (size_t j = 0; j < agc_list_len(out); j++) gathered[total++] = (uint8_t)agc_as_int(&vm, agc_list_get(out, j));
  }
  /* A one-byte output quantum still drains: needs_input stays false while
     output may come from internal state, and finish repeats until the end. */
  agc_value first_finish[] = {enc, agc_int(1)};
  const agc_struct *first = progress_of(call("Zlib.deflate_finish", 2, first_finish));
  assert(!agc_as_bool(&vm, first->fields[2]));
  gather(&vm, first, gathered, &total);
  /* New feed once finishing started is refused, even before the terminal
     drain; empty finish drains continue instead. */
  agc_value late[] = {enc, byte_list(abc_bytes, 1), agc_int(64)};
  check_error(call("Zlib.deflate_next", 3, late), "zlib: encoder finish already started");
  for (;;) {
    agc_value finish[] = {enc, agc_int(1)};
    const agc_struct *p = progress_of(call("Zlib.deflate_finish", 2, finish));
    bool done = agc_as_bool(&vm, p->fields[2]);
    const agc_list *out = agc_as_list(&vm, p->fields[0]);
    size_t n = agc_list_len(out);
    assert(n <= 1);
    check_progress(p, n, 0, done, done ? false : n < 1);
    for (size_t j = 0; j < n; j++) gathered[total++] = (uint8_t)agc_as_int(&vm, agc_list_get(out, j));
    if (done) break;
  }
  assert(total == sizeof zlib_vec_raw_abc && memcmp(gathered, zlib_vec_raw_abc, total) == 0);
  /* Feed after the verified end is refused too; empty drains repeat done. */
  check_error(call("Zlib.deflate_next", 3, late), "zlib: stream already finished");
  agc_value again[] = {enc, agc_int(64)};
  check_progress(progress_of(call("Zlib.deflate_finish", 2, again)), 0, 0, true, false);
  agc_value close[] = {enc};
  assert(agc_as_result(&vm, call("Zlib.encoder_close", 1, close))->ok);
  assert(agc_as_result(&vm, call("Zlib.encoder_close", 1, close))->ok);
  check_error(call("Zlib.deflate_next", 3, late), "zlib: handle is closed");
  check_error(call("Zlib.deflate_finish", 2, again), "zlib: handle is closed");
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

/* A failed handle stays failed, and the caps are enforced before any state
   could exceed them: a refused call changes nothing. */
static void test_stream_failure_caps(void) {
  agc_value init[] = {agc_int(15), agc_int(100), agc_int(100)};
  agc_value dec = ok(call("Zlib.inflate_init", 3, init));
  uint8_t broken[sizeof zlib_abc];
  memcpy(broken, zlib_abc, sizeof broken);
  broken[sizeof broken - 1] ^= 0x01;
  agc_value feed[] = {dec, byte_list(broken, sizeof broken), agc_int(64)};
  check_error(call("Zlib.inflate_next", 3, feed), "zlib: checksum mismatch");
  check_error(call("Zlib.inflate_next", 3, feed), "zlib: handle failed");
  agc_value finish[] = {dec};
  check_error(call("Zlib.inflate_finish", 1, finish), "zlib: handle failed");
  agc_value close[] = {dec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, close))->ok);
  agc_value tiny[] = {agc_int(15), agc_int(6), agc_int(2), agc_int(1073741824)};
  agc_value enc = ok(call("Zlib.deflate_init", 4, tiny));
  agc_value three[] = {enc, byte_list(abc_bytes, 3), agc_int(64)};
  check_error(call("Zlib.deflate_next", 3, three), "zlib: total input exceeds max_total_in");
  agc_value two[] = {enc, byte_list(abc_bytes, 2), agc_int(64)};
  const agc_struct *p = progress_of(call("Zlib.deflate_next", 3, two));
  assert(agc_as_int(&vm, p->fields[1]) == 2);
  check_error(call("Zlib.deflate_next", 3, two), "zlib: total input exceeds max_total_in");
  agc_value small_out[] = {agc_int(15), agc_int(6), agc_int(1073741824), agc_int(5)};
  agc_value enc2 = ok(call("Zlib.deflate_init", 4, small_out));
  agc_value feed2[] = {enc2, byte_list(abc_bytes, 3), agc_int(64)};
  check_error(call("Zlib.deflate_next", 3, feed2), "zlib: total output exceeds max_total_out");
  agc_value feed5[] = {enc2, byte_list(abc_bytes, 3), agc_int(5)};
  const agc_struct *q = progress_of(call("Zlib.deflate_next", 3, feed5));
  assert(agc_list_len(agc_as_list(&vm, q->fields[0])) <= 5);
  check_error(call("Zlib.deflate_next", 3, feed5), "zlib: total output exceeds max_total_out");
  agc_value big_data[] = {enc2, byte_list(abc_bytes, 3), agc_int(65537)};
  check_error(call("Zlib.deflate_next", 3, big_data), "zlib: max_out must be between 1 and 65536");
  static uint8_t much[65537] = {0};
  agc_value huge[] = {enc2, byte_list(much, sizeof much), agc_int(64)};
  check_error(call("Zlib.deflate_next", 3, huge), "zlib: input exceeds 65536 bytes");
  agc_value close_enc[] = {enc};
  assert(agc_as_result(&vm, call("Zlib.encoder_close", 1, close_enc))->ok);
  agc_value close_enc2[] = {enc2};
  assert(agc_as_result(&vm, call("Zlib.encoder_close", 1, close_enc2))->ok);
}

/* A call that must fail with a diagnostic: solo only, off-turn so the
   failure lands on vm.fail, with nothing live across the jump. */
static void fails_with(agc_task *t, const char *name, uint32_t arity, agc_value *args, const char *code) {
  if (setjmp(vm.fail) == 0) {
    (void)call_on(&vm, t, name, arity, args);
    assert(!"the call did not fail");
  }
  assert(strcmp(vm.outcome->code, code) == 0);
}

/* Handles are task-owned: the wrong kind is the call's error, and use from
   another task fails like an unowned spawn_owning handover. */
static void test_stream_ownership(void) {
  agc_value init[] = {agc_int(15), agc_int(6), agc_int(100), agc_int(100)};
  agc_value enc = ok(call("Zlib.deflate_init", 4, init));
  agc_value dec_init[] = {agc_int(15), agc_int(100), agc_int(100)};
  agc_value dec = ok(call("Zlib.inflate_init", 3, dec_init));
  agc_value cross[] = {dec, byte_list(abc_bytes, 1), agc_int(64)};
  check_error(call("Zlib.deflate_next", 3, cross), "zlib: handle is not an encoder");
  agc_value cross2[] = {enc, byte_list(abc_bytes, 1), agc_int(64)};
  check_error(call("Zlib.inflate_next", 3, cross2), "zlib: handle is not a decoder");
  check_error(call("Zlib.inflate_finish", 1, cross), "zlib: stream is truncated");
  agc_task *main_task = vm.task;
  agc_task *other = agc_new_task(&vm);
  agc_value feed[] = {enc, byte_list(abc_bytes, 1), agc_int(64)};
  vm.in_turn = false;
  fails_with(other, "Zlib.deflate_next", 3, feed, "RUNTIME-HANDLE-NOT-OWNED");
  vm.task = main_task;
  vm.in_turn = true;
  /* The failed ownership probe changed nothing: the owner still feeds. */
  const agc_struct *p = progress_of(call("Zlib.deflate_next", 3, cross2));
  assert(agc_as_int(&vm, p->fields[1]) == 1);
  /* Ownership moves with the handle: after the handover the new task feeds
     and the old one is refused. */
  agc_hand_over(agc_as_handle(&vm, enc), other);
  agc_value moved[] = {enc, byte_list(abc_bytes, 1), agc_int(64)};
  assert(agc_as_int(&vm, progress_of(call_on(&vm, other, "Zlib.deflate_next", 3, moved))->fields[1]) == 1);
  vm.in_turn = false;
  fails_with(main_task, "Zlib.deflate_next", 3, moved, "RUNTIME-HANDLE-NOT-OWNED");
  vm.task = main_task;
  vm.in_turn = true;
  /* Close is owner-indifferent and idempotent, like Native.close. */
  agc_value close_enc[] = {enc};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, close_enc))->ok);
  agc_value close_dec[] = {dec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, close_dec))->ok);
}

/* Eight threads on one shared VM: private round trips with exact asserts,
   plus one shared handle per thread where a feed may lose to a concurrent
   close (ok progress or the closed error, never anything else) while close
   always succeeds. Every call runs under rt->sync, exactly as the
   interpreter runs a shared row, so feed, close, handover and owner-end
   serialize and no thread ever reaches a freed context. */
#define ZLIB_THREADS 8
#define ZLIB_ROUNDS 40

static agc_vm workers[ZLIB_THREADS];
static agc_task *worker_tasks[ZLIB_THREADS];
static agc_value worker_shared[ZLIB_THREADS];
static uv_barrier_t worker_gate;
static _Atomic int unexpected;

static void note_unexpected(void) { atomic_fetch_add(&unexpected, 1); }

/* A feed of a shared handle: ok progress, or the closed error when a close
   won. Anything else fails the run through the counter. */
static void feed_shared(agc_vm *v, agc_task *t, agc_value handle) {
  static const uint8_t probe[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  agc_list_builder b;
  agc_list_builder_sized(&b, sizeof probe);
  for (size_t k = 0; k < sizeof probe; k++) agc_list_builder_push(&b, agc_int(probe[k]));
  agc_value args[] = {handle, agc_list_value(agc_list_builder_finish(&b)), agc_int(64)};
  agc_value result = call_on(v, t, "Zlib.deflate_next", 3, args);
  const agc_result *r = agc_as_result(v, result);
  if (r->ok) return;
  const agc_string *text = agc_as_string(v, r->value);
  static const char closed[] = "zlib: handle is closed";
  if (text->bytes != strlen(closed) || memcmp(text->data, closed, text->bytes) != 0) note_unexpected();
}

static void close_shared(agc_vm *v, agc_task *t, agc_value handle) {
  agc_value args[] = {handle};
  if (!agc_as_result(v, call_on(v, t, "Zlib.encoder_close", 1, args))->ok) note_unexpected();
}

/* One private raw round trip with exact bytes: two feeds, repeated bounded
   finish drains, then a three-chunk decode. Deterministic under every
   interleaving, since the handles are task-private. The last round leaves
   its pair open for the owner's end, so the task-end path closes handles
   too; every other round closes its own. */
static void round_trip(agc_vm *v, agc_task *t, intptr_t seed, bool leave_open) {
  uint8_t pattern[513];
  for (size_t k = 0; k < sizeof pattern; k++) pattern[k] = (uint8_t)((seed * 131 + k * 17) & 0xff);
  agc_value init[] = {agc_int(-15), agc_int(6), agc_int(1048576), agc_int(1048576)};
  agc_value enc = ok(call_on(v, t, "Zlib.deflate_init", 4, init));
  uint8_t coded[2048];
  size_t coded_total = 0;
  size_t splits[] = {300, sizeof pattern};
  size_t at = 0;
  for (size_t s = 0; s < 2; s++) {
    agc_value feed[] = {enc, byte_list(pattern + at, splits[s] - at), agc_int(1024)};
    const agc_struct *p = agc_as_struct(v, ok(call_on(v, t, "Zlib.deflate_next", 3, feed)));
    if (agc_as_int(v, p->fields[1]) != (int64_t)(splits[s] - at)) note_unexpected();
    gather(v, p, coded, &coded_total);
    at = splits[s];
  }
  bool done = false;
  for (int k = 0; k < 100 && !done; k++) {
    agc_value finish[] = {enc, agc_int(1024)};
    const agc_struct *p = agc_as_struct(v, ok(call_on(v, t, "Zlib.deflate_finish", 2, finish)));
    done = agc_as_bool(v, p->fields[2]);
    gather(v, p, coded, &coded_total);
  }
  if (!done) note_unexpected();
  agc_value dec_init[] = {agc_int(-15), agc_int(1048576), agc_int(1048576)};
  agc_value dec = ok(call_on(v, t, "Zlib.inflate_init", 3, dec_init));
  uint8_t plain[1024];
  size_t plain_total = 0;
  size_t thirds[] = {coded_total / 3, 2 * coded_total / 3, coded_total};
  at = 0;
  done = false;
  for (size_t s = 0; s < 3; s++) {
    agc_value feed[] = {dec, byte_list(coded + at, thirds[s] - at), agc_int(1024)};
    const agc_struct *p = agc_as_struct(v, ok(call_on(v, t, "Zlib.inflate_next", 3, feed)));
    at += (size_t)agc_as_int(v, p->fields[1]);
    done = agc_as_bool(v, p->fields[2]);
    gather(v, p, plain, &plain_total);
  }
  if (!done || at != coded_total || plain_total != sizeof pattern || memcmp(plain, pattern, sizeof pattern) != 0)
    note_unexpected();
  agc_value finish[] = {dec};
  if (!agc_as_result(v, call_on(v, t, "Zlib.inflate_finish", 1, finish))->ok) note_unexpected();
  if (leave_open) return;
  close_shared(v, t, enc);
  close_shared(v, t, dec);
}

static void zlib_worker(void *arg) {
  intptr_t k = (intptr_t)arg;
  agc_vm *v = &workers[k];
  assert(agc_gc_thread_enter());
  v->in_turn = true;
  agc_task *task = worker_tasks[k];
  uv_barrier_wait(&worker_gate);
  for (int r = 0; r < ZLIB_ROUNDS; r++) {
    round_trip(v, task, k * ZLIB_ROUNDS + r + 1, r == ZLIB_ROUNDS - 1);
    feed_shared(v, task, worker_shared[k]);
    close_shared(v, task, worker_shared[k]);
  }
  /* The owner's end closes the last round's pair: the same close the
     scheduler runs for a task that ends with open handles. */
  agc_sync_take(v);
  agc_close_owned(v, task);
  agc_sync_drop(v);
  /* Everything the thread owned is closed now: a further feed is refused. */
  feed_shared(v, task, worker_shared[k]);
  agc_gc_thread_leave();
}

/* The main thread closes the shared handles throughout the run: every feed
   that meets one either ran first or reports it closed. */
static void test_concurrent(void) {
  for (int k = 0; k < ZLIB_THREADS; k++) {
    workers[k] = vm;
    worker_tasks[k] = agc_new_task(&workers[k]);
    agc_value init[] = {agc_int(-15), agc_int(6), agc_int(1048576), agc_int(1048576)};
    worker_shared[k] = ok(call("Zlib.deflate_init", 4, init));
    agc_sync_take(&vm);
    agc_hand_over(agc_as_handle(&vm, worker_shared[k]), worker_tasks[k]);
    agc_sync_drop(&vm);
  }
  assert(uv_barrier_init(&worker_gate, ZLIB_THREADS + 1) == 0);
  uv_thread_t threads[ZLIB_THREADS];
  for (intptr_t k = 0; k < ZLIB_THREADS; k++) assert(uv_thread_create(&threads[k], zlib_worker, (void *)k) == 0);
  uv_barrier_wait(&worker_gate);
  for (int r = 0; r < 2 * ZLIB_ROUNDS; r++)
    for (int k = 0; k < ZLIB_THREADS; k++) close_shared(&vm, vm.task, worker_shared[k]);
  for (int k = 0; k < ZLIB_THREADS; k++) assert(uv_thread_join(&threads[k]) == 0);
  uv_barrier_destroy(&worker_gate);
  assert(atomic_load(&unexpected) == 0);
  for (int k = 0; k < ZLIB_THREADS; k++) {
    agc_sync_take(&vm);
    agc_close_owned(&vm, worker_tasks[k]);
    agc_sync_drop(&vm);
  }
}

/* A refused finish must not flip OPEN to FINISHING: the totals pre-check
   runs before the state assignment, so a later feed stays legal. */
static void test_finish_cap_state(void) {
  /* The totals bound the proof whatever a feed emits: the 64 quantum always
exceeds the 20 lifetime cap, while a 10 quantum always fits beside at most
     10 emitted bytes, and the whole stream stays far below the cap. */
  agc_value init[] = {agc_int(15), agc_int(6), agc_int(1073741824), agc_int(20)};
  agc_value enc = ok(call("Zlib.deflate_init", 4, init));
  agc_value feed[] = {enc, byte_list(abc_bytes, 3), agc_int(10)};
  const agc_struct *p = progress_of(call("Zlib.deflate_next", 3, feed));
  assert(agc_as_int(&vm, p->fields[1]) == 3);
  agc_value big[] = {enc, agc_int(64)};
  check_error(call("Zlib.deflate_finish", 2, big), "zlib: total output exceeds max_total_out");
  /* The refused finish left OPEN intact: the next feed stays legal, which a
     premature FINISHING would have refused. */
  static const uint8_t dee[] = {0x64};
  agc_value next[] = {enc, byte_list(dee, 1), agc_int(10)};
  const agc_struct *q = progress_of(call("Zlib.deflate_next", 3, next));
  assert(agc_as_int(&vm, q->fields[1]) == 1);
  /* An invalid quantum likewise changes nothing, and a finish on the closed
     handle reports closed without touching anything. */
  agc_value bad[] = {enc, agc_int(0)};
  check_error(call("Zlib.deflate_finish", 2, bad), "zlib: max_out must be between 1 and 65536");
  agc_value next2[] = {enc, byte_list(dee, 1), agc_int(1)};
  assert(agc_as_int(&vm, progress_of(call("Zlib.deflate_next", 3, next2))->fields[1]) == 1);
  agc_value close[] = {enc};
  assert(agc_as_result(&vm, call("Zlib.encoder_close", 1, close))->ok);
  check_error(call("Zlib.deflate_finish", 2, big), "zlib: handle is closed");
}

static agc_value path_str(const char *text) {
  return agc_string_value(agc_make_string(text, strlen(text), strlen(text)));
}

/* A File call on a Zlib handle through the test's own call helper. */
static agc_value file_call(agc_task *t, const char *name, uint32_t arity, agc_value *args) {
  const agc_builtin *b = agc_find_builtin((const uint8_t *)name, strlen(name), arity);
  assert(b);
  return agc_test_call(&vm, t, b, args);
}

/* Handles of the two libraries share the AGC_T_HANDLE tag, so each side
   must refuse the other's: every Zlib entry refuses an open File handle and
   every central File path refuses an open Zlib handle, with stable errors
   and no close, unregister or free of the foreign resource. */
static void test_foreign_handles(void) {
  char directory[4300];
  uv_fs_t req;
  agc_test_scratch(directory, &req, "zlib-foreign");
  char path[4300];
  assert(snprintf(path, sizeof path, "%s/foreign.bin", directory) > 0);
  agc_value open_args[] = {path_str(path), path_str("write"), agc_int(5000)};
  agc_value file = ok(file_call(vm.task, "File.open", 3, open_args));
  agc_value data = byte_list(abc_bytes, sizeof abc_bytes);
  agc_value feed[] = {file, data, agc_int(64)};
  check_error(call("Zlib.deflate_next", 3, feed), "zlib: handle is not a zlib handle");
  check_error(call("Zlib.inflate_next", 3, feed), "zlib: handle is not a zlib handle");
  agc_value finish[] = {file, agc_int(64)};
  check_error(call("Zlib.deflate_finish", 2, finish), "zlib: handle is not a zlib handle");
  agc_value dfinish[] = {file};
  check_error(call("Zlib.inflate_finish", 1, dfinish), "zlib: handle is not a zlib handle");
  agc_value close[] = {file};
  check_error(call("Zlib.encoder_close", 1, close), "zlib: handle is not a zlib handle");
  check_error(call("Zlib.decoder_close", 1, close), "zlib: handle is not a zlib handle");
  /* The File handle is untouched: still owned, lockable, writable, and its
     bytes land intact through a real close. */
  assert(agc_task_owns(&vm, file));
  agc_value lock[] = {file, agc_int(5000)};
  assert(agc_as_bool(&vm, ok(file_call(vm.task, "File.try_lock", 2, lock))));
  static const uint8_t hello[] = {0x68, 0x65, 0x6c, 0x6c, 0x6f};
  agc_value write[] = {file, byte_list(hello, sizeof hello), agc_int(5000)};
  ok(file_call(vm.task, "File.write_bytes", 3, write));
  agc_value fclose[] = {file, agc_int(5000)};
  ok(file_call(vm.task, "File.close", 2, fclose));
  agc_value read[] = {path_str(path), agc_int(5000)};
  assert(agc_as_string(&vm, ok(file_call(vm.task, "File.read_text", 2, read)))->bytes == sizeof hello);
  /* The mirror direction: File.close/read/write/flush/try_lock on Zlib
     handles refuse without reaching any file state. */
  agc_value einit[] = {agc_int(15), agc_int(6), agc_int(100), agc_int(100)};
  agc_value enc = ok(call("Zlib.deflate_init", 4, einit));
  agc_value dinit[] = {agc_int(15), agc_int(100), agc_int(100)};
  agc_value dec = ok(call("Zlib.inflate_init", 3, dinit));
  static const char foreign[] = "filesystem: handle is not a file handle";
  agc_value fclose2[] = {enc, agc_int(5000)};
  check_error(file_call(vm.task, "File.close", 2, fclose2), foreign);
  agc_value dread[] = {dec, agc_int(10), agc_int(5000)};
  check_error(file_call(vm.task, "File.read_bytes", 3, dread), foreign);
  agc_value wargs[] = {enc, path_str("x"), agc_int(5000)};
  check_error(file_call(vm.task, "File.write", 3, wargs), foreign);
  agc_value wbytes[] = {enc, byte_list(abc_bytes, 1), agc_int(5000)};
  check_error(file_call(vm.task, "File.write_bytes", 3, wbytes), foreign);
  agc_value flush[] = {enc, agc_int(5000)};
  check_error(file_call(vm.task, "File.flush", 2, flush), foreign);
  agc_value tlock[] = {dec, agc_int(5000)};
  check_error(file_call(vm.task, "File.try_lock", 2, tlock), foreign);
  /* Both Zlib handles are untouched: still owned, feedable, closable. */
  assert(agc_task_owns(&vm, enc) && agc_task_owns(&vm, dec));
  agc_value efeed[] = {enc, byte_list(abc_bytes, 1), agc_int(64)};
  assert(agc_as_int(&vm, progress_of(call("Zlib.deflate_next", 3, efeed))->fields[1]) == 1);
  agc_value dfeed[] = {dec, byte_list(NULL, 0), agc_int(64)};
  check_progress(progress_of(call("Zlib.inflate_next", 3, dfeed)), 0, 0, false, true);
  agc_value eclose[] = {enc};
  assert(agc_as_result(&vm, call("Zlib.encoder_close", 1, eclose))->ok);
  agc_value dclose[] = {dec};
  assert(agc_as_result(&vm, call("Zlib.decoder_close", 1, dclose))->ok);
  assert(agc_fs_unlink(path) == 0);
  assert(uv_fs_rmdir(NULL, &req, directory, NULL) == 0);
  uv_fs_req_cleanup(&req);
}

static agc_vm bare_vm;
static agc_program bare_program;

/* The init half on the record-less VM, returning its handle value. */
static agc_value bare_init(void) {
  agc_value init[] = {agc_int(15), agc_int(6), agc_int(100), agc_int(100)};
  agc_value result = call_on(&bare_vm, bare_vm.task, "Zlib.deflate_init", 4, init);
  const agc_result *r = agc_as_result(&bare_vm, result);
  assert(r->ok);
  return r->value;
}

/* A call that must fail with the missing-record diagnostic on a VM whose
   program has no ZlibProgress struct: solo only, off-turn, nothing live. */
static void fails_internal(agc_task *t, const char *name, uint32_t arity, agc_value *args) {
  if (setjmp(bare_vm.fail) == 0) {
    (void)call_on(&bare_vm, t, name, arity, args);
    assert(!"the call did not fail");
  }
  assert(strcmp(bare_vm.outcome->code, "RUNTIME-INTERNAL") == 0);
}

/* The progress lookup runs before any malloc, so a missing record fails
   cleanly again and again with nothing retained; the encoder itself
   survives every failed lookup and still closes. */
static void test_missing_progress_record(void) {
  agc_vm_init(&bare_vm, &bare_program, stdout, stderr, INT64_MAX);
  bare_vm.in_turn = true;
  agc_value enc = bare_init();
  agc_task *task = bare_vm.task;
  bare_vm.in_turn = false;
  agc_value feed[] = {enc, byte_list(abc_bytes, 3), agc_int(64)};
  for (int k = 0; k < 50; k++) fails_internal(task, "Zlib.deflate_next", 3, feed);
  bare_vm.task = task;
  bare_vm.in_turn = true;
  agc_value close[] = {enc};
  assert(agc_as_result(&bare_vm, call_on(&bare_vm, task, "Zlib.encoder_close", 1, close))->ok);
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
  test_stream_init_checks();
  test_stream_encode();
  test_stream_decode();
  test_stream_truncation_trailing();
  test_stream_decoder_full_budget();
  test_stream_failure_caps();
  test_stream_ownership();
  test_finish_cap_state();
  test_foreign_handles();
  test_missing_progress_record();
  /* The shared phase: one lock for tasks, handles and the registry, with
     every streaming row running under it like the interpreter runs them. */
  agc_share(&vm);
  agc_gc_allow_threads();
  test_concurrent();
  agc_close_owned(&vm, vm.task);
  assert(agc_io_close(&vm));
  puts("zlib tests passed");
  return 0;
}

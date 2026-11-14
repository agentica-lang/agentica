/* The Zlib rows and the streams of the Lazy steps (agc_zstep_*), with their
   shared-VM interleavings, against independently generated vectors. The
   one-shot calls and Zlib.crc32 are proven through the CLI against Python
   (tests/test_vm_zlib.py, tests/test_vm_zlib_crc32.py). */
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

/* The bytes a stream produced, gathered across its chunks, with the largest
   chunk: no chunk is empty or over the 64 KiB quantum. */
typedef struct {
  uint8_t *data;
  size_t len, cap, largest;
} sink;

/* Python's zlib on "abc" at levels 6 and 0 and on "" at 6: the exact streams
   our decoder must read and our encoder must write. The gzip and raw members
   live in zlib_vectors.h. */
static const uint8_t zlib_abc[] = {0x78, 0x9c, 0x4b, 0x4c, 0x4a, 0x06, 0x00, 0x02, 0x4d, 0x01, 0x27};
static const uint8_t zlib_empty[] = {0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01};
static const uint8_t zlib_abc_l0[] = {0x78, 0x01, 0x01, 0x03, 0x00, 0xfc, 0xff,
  0x61, 0x62, 0x63, 0x02, 0x4d, 0x01, 0x27};
static const uint8_t abc_bytes[] = {0x61, 0x62, 0x63};

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

static void fails(const char *name, uint32_t arity, agc_value *args, const char *code) {
  agc_test_fails_row(&vm, name, arity, args, code);
}

/* The 5 public rows in the contract's order, under their ".bytes" keys, with
   their arities: pure calls, never shared, since the streams of the Lazy
   steps have no row. */
static void test_table(void) {
  struct {
    const char *name;
    uint32_t arity;
    bool shared;
  } expected[] = {
    {"Zlib.deflate.bytes", 3, false}, {"Zlib.inflate.bytes", 2, false}, {"Zlib.gzip.bytes", 3, false},
    {"Zlib.gunzip.bytes", 2, false},  {"Zlib.crc32.bytes", 2, false},
  };
  size_t count = sizeof expected / sizeof expected[0];
  assert(agc_zlib_builtin_count == count);
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

/* A List given to a Zlib row is a wrong tag: the type cannot give one, only hand-made bytecode can. */
static void test_list_refused(void) {
  agc_task *main_task = vm.task;
  vm.in_turn = false;
  agc_value list_args[] = {byte_list(abc_bytes, sizeof abc_bytes), agc_int(6), agc_int(100)};
  fails("Zlib.deflate.bytes", 3, list_args, "RUNTIME-INTERNAL");
  fails("Zlib.gunzip.bytes", 2, list_args, "RUNTIME-INTERNAL");
  fails("Zlib.crc32.bytes", 2, list_args, "RUNTIME-INTERNAL");
  vm.task = main_task;
  vm.in_turn = true;
}

/* A chunk of a stream: a Bytes. */
static void sink_put(agc_vm *v, sink *s, agc_value chunk) {
  if (agc_is(chunk, AGC_T_VOID)) return;
  size_t n;
  const uint8_t *data = agc_bytes_data(v, chunk, &n);
  assert(n > 0 && n <= 65536);
  if (n > s->largest) s->largest = n;
  if (s->len + n > s->cap) {
    s->cap = (s->len + n) * 2;
    s->data = realloc(s->data, s->cap);
    if (!s->data) agc_out_of_memory();
  }
  memcpy(s->data + s->len, data, n);
  s->len += n;
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

/* A bad level is an encoder's error and a bad max_bytes a decoder's; each
   kind ignores the other argument. Lazy max_bytes has no upper bound. */
static void test_zstep_check(void) {
  check_error(agc_zstep_check(&vm, 0, 10, 1), "zlib: level must be between 0 and 9");
  check_error(agc_zstep_check(&vm, 2, -1, 1), "zlib: level must be between 0 and 9");
  check_error(agc_zstep_check(&vm, 3, 6, 0), "zlib: max_bytes must be at least 1");
  check_error(agc_zstep_check(&vm, 5, 6, -1), "zlib: max_bytes must be at least 1");
  assert(agc_is(agc_zstep_check(&vm, 1, 9, 0), AGC_T_VOID));
  assert(agc_is(agc_zstep_check(&vm, 4, 99, INT64_MAX), AGC_T_VOID));
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

/* Each wrapper round-trips a 300 KB mix of noise and zeros, in pieces around
   the 64 KiB quantum and with empty items between them; no chunk passes the
   quantum. One level per wrapper covers 0, 6 and 9: tests/test_vm_zlib.py
   runs every level of every wrapper against Python. */
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
    for (size_t k = 0; k < 4; k++) {
      sink coded = {0}, back = {0};
      agc_value error = agc_void();
      agc_resource *r = agc_zstep_open(&vm, enc, levels[enc], 0);
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
  if (AGC_CATCH(vm.fail) == 0) {
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
  agc_vm_init(&vm, &program, stdout, stderr, INT64_MAX);
  vm.in_turn = true;
  test_table();
  test_list_refused();
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

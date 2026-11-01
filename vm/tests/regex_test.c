/*
 * RegexEngine.search (vm/regex.c) driven by hand: a long search yields with a bounded turn cost per resume and survives
 * collections between resumes, its results follow the Go rules, and program lists that std/regex never builds fail
 * with RUNTIME-INTERNAL instead of reading out of bounds or looping.
 */
#include "../core.h"
#include "../services.h"
#include "../trace.h"
#include "builtin_test.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>

enum { CHAR, CLASS, ANY, ANY_NL, SPLIT, JUMP, SAVE, ASSERT, MATCH };
enum { TEST, FIRST, ALL };

static agc_vm vm;
static uint64_t ids;
static const agc_builtin *search;
/* The last drive: the turn cost all its resumes charged, and the time of the slowest resume (printed when it is long,
   never asserted: shared runners are too noisy for a time bound). */
static int64_t total_cost;
static uint64_t slowest_ns;

/* A program: the three instruction lists, the classes and the number of capture slots. */
typedef struct {
  const int64_t *ops, *xs, *ys;
  size_t n;
  agc_value classes;
  int64_t ncap;
} program;

static agc_task *make_task(void) {
  agc_task *t = agc_alloc(sizeof(agc_task));
  t->id = ++ids;
  t->state = AGC_TASK_RUNNING;
  return t;
}

static agc_value ints(const int64_t *items, size_t n) {
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&b, agc_int(items[k]));
  return agc_list_value(agc_list_builder_finish(&b));
}

static agc_value lists(const agc_value *items, size_t n) {
  agc_list_builder b;
  agc_list_builder_sized(&b, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&b, items[k]);
  return agc_list_value(agc_list_builder_finish(&b));
}

static agc_value no_classes(void) { return lists(NULL, 0); }

static agc_value text_of(const char *s, size_t bytes, size_t chars) {
  return agc_string_value(agc_make_string(s, bytes, chars));
}

static void args_of(agc_value *args, agc_value text, const program *p, int64_t mode) {
  args[0] = text;
  args[1] = ints(p->ops, p->n);
  args[2] = ints(p->xs, p->n);
  args[3] = ints(p->ys, p->n);
  args[4] = p->classes;
  args[5] = agc_int(p->ncap);
  args[6] = agc_int(mode);
}

/* Starts the search on a new task and runs it to its end, each resume in a turn of its own. Returns the result and
   the number of resumes; asserts that no resume charged more than a turn and one chunk. */
static agc_value drive(agc_value text, const program *p, int64_t mode, bool collect, size_t *resumes) {
  agc_value args[7];
  args_of(args, text, p, mode);
  agc_task *t = make_task();
  vm.task = t;
  assert(agc_is(search->fn(&vm, args, 0), AGC_T_VOID) && t->stepper);
  *resumes = 0;
  slowest_ns = 0;
  total_cost = 0;
  for (;;) {
    vm.task = t;
    agc_turn_begin(&vm);
    uint64_t began = agc_trace_now();
    agc_step step = t->stepper->step(&vm, t->stepper, agc_void());
    uint64_t took = agc_trace_now() - began;
    if (took > slowest_ns) slowest_ns = took;
    /* A chunk is at most 256 characters, 4096 instruction visits (plus the visits of the last character, at most
       two per instruction), under two windows of 64 KB skipped plus a prefix of at most 4 bytes per instruction, and
       4096 items of the result list. */
    assert(vm.turn_cost_used <= AGC_TURN_STEPS + 256 + (4096 + 2 * (int64_t)p->n) / 64 +
                                    ((int64_t)2 * 65536 + 4 * (int64_t)p->n) / AGC_COST_BYTES + 4096 / 8 + 1);
    total_cost += vm.turn_cost_used;
    (*resumes)++;
    if (collect) {
      for (int k = 0; k < 64; k++) (void)agc_alloc(4096);
      agc_gc_collect();
    }
    if (step.kind == AGC_STEP_END) {
      if (slowest_ns > 20000000u) fprintf(stderr, "note: slowest resume %llu ns\n", (unsigned long long)slowest_ns);
      return step.value;
    }
    assert(step.kind == AGC_STEP_YIELD);
  }
}

static size_t length(agc_value v) { return agc_list_len(agc_as_list(&vm, v)); }

static int64_t item(agc_value v, size_t k) { return agc_as_int(&vm, agc_list_get(agc_as_list(&vm, v), k)); }

/* `a+$`: SAVE 0, CHAR a, SPLIT 1 3, ASSERT END_TEXT, SAVE 1, MATCH. */
static const int64_t plus_ops[] = {SAVE, CHAR, SPLIT, ASSERT, SAVE, MATCH};
static const int64_t plus_xs[] = {0, 'a', 1, 1, 1, 0};
static const int64_t plus_ys[] = {0, 0, 3, 0, 0, 0};

static void test_long_search_yields_and_survives_collections(void) {
  size_t n = 1 << 20;
  char *s = malloc(n + 1);
  assert(s);
  memset(s, 'a', n);
  s[n] = '!';
  program p = {plus_ops, plus_xs, plus_ys, 6, no_classes(), 2};
  size_t resumes;
  agc_value result = drive(text_of(s, n + 1, n + 1), &p, FIRST, true, &resumes);
  assert(length(result) == 0 && resumes > 100);
  /* The same text ending in `a` matches at 0, whole. */
  s[n] = 'a';
  result = drive(text_of(s, n + 1, n + 1), &p, FIRST, true, &resumes);
  assert(length(result) == 2 && item(result, 0) == 0 && item(result, 1) == (int64_t)n + 1);
  free(s);
}

/* A prefix far from the start: the skip reads at most 64 KB per chunk, so even a search that only skips yields. */
static void test_a_long_skip_yields(void) {
  size_t n = 1 << 22;
  char *s = malloc(n);
  assert(s);
  memset(s, '.', n);
  memcpy(s + n - 2, "ab", 2);
  static const int64_t ops[] = {SAVE, CHAR, CHAR, SAVE, MATCH}, xs[] = {0, 'a', 'b', 1, 0}, ys[] = {0, 0, 0, 0, 0};
  program p = {ops, xs, ys, 5, no_classes(), 2};
  size_t resumes;
  agc_value result = drive(text_of(s, n, n), &p, TEST, false, &resumes);
  assert(length(result) == 1 && item(result, 0) == (int64_t)n && resumes > 1);
  free(s);
}

/* A literal of 9000 `a` and a `b` over 1 MB of `a`: every byte the linear prefix search reads is charged (at least
   the whole text here), and each resume stays within a turn and one chunk (drive), so the search spreads over many
   resumes. */
static void test_a_long_literal_prefix_is_found_in_linear_time(void) {
  enum { LETTERS = 9000, N = LETTERS + 4 };
  static int64_t ops[N], xs[N], ys[N];
  ops[0] = SAVE;
  for (int k = 1; k <= LETTERS; k++) {
    ops[k] = CHAR;
    xs[k] = 'a';
  }
  ops[LETTERS + 1] = CHAR;
  xs[LETTERS + 1] = 'b';
  ops[LETTERS + 2] = SAVE;
  xs[LETTERS + 2] = 1;
  ops[LETTERS + 3] = MATCH;
  size_t n = 1 << 20;
  char *s = malloc(n);
  assert(s);
  memset(s, 'a', n);
  program p = {ops, xs, ys, N, no_classes(), 2};
  size_t resumes;
  agc_value result = drive(text_of(s, n, n), &p, TEST, false, &resumes);
  assert(length(result) == 0 && total_cost >= (int64_t)n / AGC_COST_BYTES && resumes >= 4);
  /* With the `b` at the end it matches there. */
  s[n - 1] = 'b';
  result = drive(text_of(s, n, n), &p, TEST, false, &resumes);
  assert(length(result) == 1 && item(result, 0) == (int64_t)n);
  free(s);
}

/* The empty match of a program with 257 groups at each of 16384 characters: 8.4M Ints. Each item of the list is
   charged, and no resume charges more than a turn and one chunk (drive), so the list is built over hundreds of
   resumes instead of in the last one. */
static void test_a_huge_result_list_is_built_over_many_resumes(void) {
  static const int64_t ops[] = {SAVE, SAVE, MATCH}, xs[] = {0, 1, 0}, ys[] = {0, 0, 0};
  size_t n = 1 << 14;
  char *s = malloc(n);
  assert(s);
  memset(s, 'z', n);
  program p = {ops, xs, ys, 3, no_classes(), 514};
  size_t resumes;
  agc_value result = drive(text_of(s, n, n), &p, ALL, false, &resumes);
  size_t items = (n + 1) * 514;
  assert(length(result) == items && total_cost >= (int64_t)(items / 8) && resumes > 100);
  assert(item(result, 0) == 0 && item(result, 2) == -1 && item(result, 514) == 1);
  free(s);
}

/* ALL with `x*` on "xéx": 0-1 and 2-3, in characters; the empty matches at 1 and 3 start where a match ended, so
   they are dropped. */
static void test_all_follows_the_go_rules(void) {
  static const int64_t ops[] = {SAVE, SPLIT, CHAR, JUMP, SAVE, MATCH}, xs[] = {0, 2, 'x', 1, 1, 0},
                       ys[] = {0, 4, 0, 0, 0, 0};
  program p = {ops, xs, ys, 6, no_classes(), 2};
  size_t resumes;
  agc_value result = drive(text_of("x\xc3\xa9x", 4, 3), &p, ALL, false, &resumes);
  static const int64_t want[] = {0, 1, 2, 3};
  assert(length(result) == 4);
  for (size_t k = 0; k < 4; k++) assert(item(result, k) == want[k]);
}

/* A program of empty loops (SPLIT and JUMP back to themselves) ends: each pc is visited once per position. */
static void test_empty_loops_end(void) {
  static const int64_t ops[] = {SPLIT, JUMP, MATCH}, xs[] = {0, 1, 0}, ys[] = {1, 0, 0};
  program p = {ops, xs, ys, 3, no_classes(), 2};
  size_t resumes;
  agc_value result = drive(text_of("abc", 3, 3), &p, ALL, false, &resumes);
  assert(length(result) == 0);
}

static void refused(agc_value text, const program *p, int64_t mode) {
  agc_value args[7];
  args_of(args, text, p, mode);
  vm.task = make_task();
  agc_test_fails(&vm, "RegexEngine.search", search, args, "RUNTIME-INTERNAL");
}

static void test_hostile_programs_are_refused(void) {
  agc_value text = text_of("abc", 3, 3);
  program good = {plus_ops, plus_xs, plus_ys, 6, no_classes(), 2};
  /* Each case changes one field of the good program. */
  static const int64_t bad_op[] = {SAVE, 9, SPLIT, ASSERT, SAVE, MATCH};
  static const int64_t neg_op[] = {SAVE, -1, SPLIT, ASSERT, SAVE, MATCH};
  static const int64_t split_out[] = {0, 'a', 6, 1, 1, 0};
  static const int64_t split_out_y[] = {0, 0, 7, 0, 0, 0};
  static const int64_t save_out[] = {2, 'a', 1, 1, 1, 0};
  static const int64_t assert_out[] = {0, 'a', 1, 6, 1, 0};
  static const int64_t code_out[] = {0, 0x110000, 1, 1, 1, 0};
  static const int64_t class_op[] = {SAVE, CLASS, SPLIT, ASSERT, SAVE, MATCH};
  static const int64_t falls_off[] = {SAVE, CHAR, SPLIT, ASSERT, SAVE, CHAR};
  program cases[] = {
    {plus_ops, plus_xs, plus_ys, 0, no_classes(), 2},
    {bad_op, plus_xs, plus_ys, 6, no_classes(), 2},
    {neg_op, plus_xs, plus_ys, 6, no_classes(), 2},
    {plus_ops, split_out, plus_ys, 6, no_classes(), 2},
    {plus_ops, plus_xs, split_out_y, 6, no_classes(), 2},
    {plus_ops, save_out, plus_ys, 6, no_classes(), 2},
    {plus_ops, assert_out, plus_ys, 6, no_classes(), 2},
    {plus_ops, code_out, plus_ys, 6, no_classes(), 2},
    {class_op, plus_xs, plus_ys, 6, no_classes(), 2},
    {falls_off, plus_xs, plus_ys, 6, no_classes(), 2},
    {plus_ops, plus_xs, plus_ys, 6, no_classes(), 0},
    {plus_ops, plus_xs, plus_ys, 6, no_classes(), 3},
    {plus_ops, plus_xs, plus_ys, 6, no_classes(), 516},
  };
  for (size_t k = 0; k < sizeof cases / sizeof cases[0]; k++) refused(text, &cases[k], FIRST);
  refused(text, &good, 3);
  refused(text, &good, -1);
  /* Lists of different lengths. */
  agc_value args[7];
  args_of(args, text, &good, TEST);
  args[3] = ints(plus_ys, 5);
  vm.task = make_task();
  agc_test_fails(&vm, "RegexEngine.search", search, args, "RUNTIME-INTERNAL");
  /* Classes that are not sorted, disjoint [low, high] pairs of code points. */
  static const int64_t odd[] = {1, 2, 3}, reversed[] = {5, 4}, overlap[] = {1, 5, 5, 9}, unsorted[] = {7, 9, 1, 2},
                       too_high[] = {1, 0x110000}, negative[] = {-1, 5};
  const int64_t *bad_classes[] = {odd, reversed, overlap, unsorted, too_high, negative};
  size_t sizes[] = {3, 2, 4, 4, 2, 2};
  static const int64_t class_xs[] = {0, 0, 1, 1, 1, 0};
  for (size_t k = 0; k < 6; k++) {
    agc_value one = ints(bad_classes[k], sizes[k]);
    program p = {class_op, class_xs, plus_ys, 6, lists(&one, 1), 2};
    refused(text, &p, TEST);
  }
  /* The same program with a well-formed class runs. */
  static const int64_t abc[] = {'a', 'c'};
  agc_value one = ints(abc, 2);
  program p = {class_op, class_xs, plus_ys, 6, lists(&one, 1), 2};
  size_t resumes;
  agc_value result = drive(text, &p, FIRST, false, &resumes);
  assert(length(result) == 2 && item(result, 0) == 0 && item(result, 1) == 3);
}

int main(void) {
  agc_init();
  agc_io_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  search = agc_find_builtin((const uint8_t *)"RegexEngine.search", 18, 7);
  assert(search && search->arity == 7);
  test_long_search_yields_and_survives_collections();
  test_a_long_skip_yields();
  test_a_long_literal_prefix_is_found_in_linear_time();
  test_a_huge_result_list_is_built_over_many_resumes();
  test_all_follows_the_go_rules();
  test_empty_loops_end();
  test_hostile_programs_are_refused();
  puts("regex tests passed");
  return 0;
}

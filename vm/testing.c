/* The builtin Test module (docs/future/36-unit-tests.md §36.3, §36.6). */
#include "agc.h"

#include <string.h>

typedef enum { MODE_NONE, MODE_LIST, MODE_RUN } run_mode;

struct agc_test_run {
  agc_task *current;
  const agc_test_case *test;
};

static const char marker[] = "\x1e" "agentica-bdd ";

static agc_string *lit(const char *text) {
  size_t n = strlen(text);
  return agc_make_string(text, n, n);
}

static agc_value ok_void(void) { return agc_result_value(true, agc_void()); }

static agc_value failed(agc_vm *vm, uint32_t span, agc_string *message, agc_string *expected, agc_string *actual) {
  agc_task *test = vm->task->test;
  if (test && test->state != AGC_TASK_DONE && !test->note) {
    agc_test_note *n = agc_alloc(sizeof(agc_test_note));
    n->message = message;
    n->expected = expected;
    n->actual = actual;
    n->span = span;
    test->note = n;
  }
  agc_string *text = expected ? agc_concat(lit("expected "), expected) : message;
  if (actual) text = agc_concat(agc_concat(text, lit("; actual ")), actual);
  return agc_result_value(false, agc_string_value(text));
}

static agc_value builtin_test(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_test_case *c = agc_alloc(sizeof(agc_test_case));
  c->name = agc_as_string(vm, args[0]);
  agc_as_fn(vm, args[1]);
  c->body = args[1];
  c->span = span;
  return agc_test_case_value(c);
}

static agc_value builtin_eq(agc_vm *vm, agc_value *args, uint32_t span) {
  if (agc_equal(vm, args[0], args[1], span)) return ok_void();
  return failed(vm, span, lit("values are not equal"), agc_test_text(vm, args[1]), agc_test_text(vm, args[0]));
}

static agc_value builtin_ok(agc_vm *vm, agc_value *args, uint32_t span) {
  if (agc_as_result(vm, args[0])->ok) return ok_void();
  return failed(vm, span, lit("expected ok"), NULL, agc_test_text(vm, args[0]));
}

static agc_value builtin_error(agc_vm *vm, agc_value *args, uint32_t span) {
  if (!agc_as_result(vm, args[0])->ok) return ok_void();
  return failed(vm, span, lit("expected an error"), NULL, agc_test_text(vm, args[0]));
}

static agc_value builtin_assert(agc_vm *vm, agc_value *args, uint32_t span) {
  if (agc_as_bool(vm, args[0])) return ok_void();
  return failed(vm, span, agc_as_string(vm, args[1]), NULL, NULL);
}

static const agc_test_case *case_at(agc_vm *vm, const agc_list *tests, size_t k) {
  return agc_as_test_case(vm, tests->items[k]);
}

static void check_names(agc_vm *vm, const agc_list *tests) {
  agc_map *seen = agc_new_map();
  for (size_t k = 0; k < tests->len; k++) {
    const agc_test_case *c = case_at(vm, tests, k);
    agc_value name = agc_string_value(c->name);
    agc_value found;
    if (!c->name->bytes) agc_fail(vm, "RUNTIME-TEST-NAME", "a test name must not be empty", c->span);
    if (agc_map_get(vm, seen, name, &found))
      agc_fail_text(vm, "RUNTIME-TEST-NAME", agc_around("two tests are named ", c->name, ""), c->span);
    seen = agc_map_put(vm, seen, name, agc_bool(true));
  }
}

static bool is_text(agc_vm *vm, agc_value v, const char *text) {
  const agc_string *s = agc_as_string(vm, v);
  return s->bytes == strlen(text) && memcmp(s->data, text, s->bytes) == 0;
}

static run_mode mode_of(agc_vm *vm) {
  const agc_list *args = agc_as_list(vm, vm->rt->args);
  if (args->len != 2 || !is_text(vm, args->items[0], "--agentica-test")) return MODE_NONE;
  if (is_text(vm, args->items[1], "list")) return MODE_LIST;
  if (is_text(vm, args->items[1], "run")) return MODE_RUN;
  return MODE_NONE;
}

static agc_json_member member(const char *key, agc_value value) {
  agc_json_member m;
  m.key = lit(key);
  m.value = value;
  return m;
}

static agc_value json_text(agc_string *s) { return agc_json_leaf(AGC_JSON_STRING, agc_string_value(s)); }

static agc_value json_int(uint32_t n) { return agc_json_leaf(AGC_JSON_INT, agc_int(n)); }

static agc_json_member *members(size_t n) { return agc_alloc(agc_size_mul(n, sizeof(agc_json_member))); }

static agc_value position(uint32_t line, uint32_t column) {
  agc_json_member *m = members(2);
  m[0] = member("column", json_int(column));
  m[1] = member("line", json_int(line));
  return agc_json_object(m, 2);
}

static void write_record(agc_vm *vm, agc_json_member *m, size_t n) {
  const agc_string *text = agc_json_encode(vm, agc_json_object(m, n), 0);
  agc_write(vm, vm->rt->out, marker, sizeof marker - 1);
  agc_write(vm, vm->rt->out, text->data, text->bytes);
  agc_write(vm, vm->rt->out, "\n", 1);
}

static void write_event(agc_vm *vm, const char *event) {
  agc_json_member *m = members(1);
  m[0] = member("event", json_text(lit(event)));
  write_record(vm, m, 1);
  agc_flush(vm);
}

static void write_list(agc_vm *vm, const agc_list *tests) {
  const agc_program *p = vm->rt->program;
  for (size_t k = 0; k < tests->len; k++) {
    const agc_test_case *c = case_at(vm, tests, k);
    const agc_span *at = &p->spans[c->span];
    agc_json_member *m = members(4);
    m[0] = member("column", json_int(at->start_column));
    m[1] = member("event", json_text(lit("test")));
    m[2] = member("line", json_int(at->start_line));
    m[3] = member("name", json_text(c->name));
    write_record(vm, m, 4);
  }
  write_event(vm, "ready");
}

static void write_fail(agc_vm *vm, const char *code, agc_string *message, uint32_t span, const agc_test_note *n) {
  const agc_program *p = vm->rt->program;
  const agc_span *at = &p->spans[span];
  agc_json_member *range = members(2);
  range[0] = member("end", position(at->end_line, at->end_column));
  range[1] = member("start", position(at->start_line, at->start_column));
  agc_json_member *m = members(7);
  size_t count = 0;
  m[count++] = member("code", json_text(lit(code)));
  m[count++] = member("event", json_text(lit("fail")));
  m[count++] = member("file", json_text(p->sources[at->source].name));
  m[count++] = member("message", json_text(message));
  m[count++] = member("range", agc_json_object(range, 2));
  if (n && n->expected) m[count++] = member("expected", json_text(n->expected));
  if (n && n->actual) m[count++] = member("actual", json_text(n->actual));
  write_record(vm, m, count);
  agc_flush(vm);
}

static uint64_t test_seed(uint64_t seed, const agc_string *name) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (size_t k = 0; k < name->bytes; k++) {
    h ^= (uint8_t)name->data[k];
    h *= 0x100000001b3ULL;
  }
  return seed ^ h;
}

static agc_task *start_test(agc_vm *vm, const agc_test_case *c) {
  agc_task *t = agc_task_spawn(vm, c->body, NULL, 0, c->span);
  t->test = t;
  agc_random_seed(&t->random, test_seed(vm->rt->seed, c->name));
  return t;
}

/* A test's running descendants moved to the caller when the test task
   ended; they are the caller's children spawned under this test. */
static void cancel_leftovers(agc_vm *vm, const agc_task *caller, const agc_task *test) {
  for (;;) {
    agc_task *k = caller->children;
    while (k && (k->test != test || k->cancelled)) k = k->next_sibling;
    if (!k) return;
    agc_task_cancel(vm, k);
  }
}

static agc_task *unobserved_of(const agc_vm *vm, const agc_task *test) {
  for (agc_task *t = vm->crashes; t; t = t->crash_next)
    if (!t->observed && t->test == test && t != test) return t;
  return NULL;
}

static void observe_test(agc_vm *vm, const agc_task *test) {
  for (agc_task *t = vm->crashes; t; t = t->crash_next)
    if (t->test == test) agc_task_observe(vm, t);
}

static void report(agc_vm *vm, agc_task *t, const agc_test_case *c) {
  cancel_leftovers(vm, vm->task, t);
  agc_task *crashed = unobserved_of(vm, t);
  if (t->crashed) {
    write_fail(vm, t->crash_code, t->crash_message, t->crash_span, NULL);
  } else if (t->note) {
    write_fail(vm, "RUNTIME-TEST-ASSERTION", t->note->message, t->note->span, t->note);
  } else if (!agc_as_result(vm, t->result)->ok) {
    write_fail(vm, "RUNTIME-TEST-ERROR", agc_as_string(vm, agc_as_result(vm, t->result)->value), c->span, NULL);
  } else if (t->left_children) {
    write_fail(vm, "RUNTIME-TEST-PENDING-TASKS", lit("the test returned while its tasks were still running"), c->span,
               NULL);
  } else if (crashed) {
    write_fail(vm, "RUNTIME-TASK-CRASHED", crashed->crash, c->span, NULL);
  } else {
    write_event(vm, "pass");
  }
  observe_test(vm, t);
}

static bool wait_for(agc_vm *vm, agc_task *target) {
  vm->task->awaiting = NULL;
  if (target->state == AGC_TASK_DONE) return false;
  vm->task->awaiting = target;
  agc_task_enqueue(&target->waiters, &target->waiters_tail, vm->task);
  agc_task_park(vm, true);
  return true;
}

static const agc_test_case *next_test(agc_vm *vm, const agc_list *tests, const agc_string *line, uint32_t span) {
  int64_t index = 0;
  bool digits = line->bytes > 0 && (line->bytes == 1 || line->data[0] != '0');
  for (size_t k = 0; k < line->bytes; k++) digits = digits && line->data[k] >= '0' && line->data[k] <= '9';
  if (digits && agc_parse_int((const uint8_t *)line->data, line->bytes, &index) == AGC_NUMBER_OK &&
      (uint64_t)index < tests->len)
    return case_at(vm, tests, (size_t)index);
  write_fail(vm, "RUNTIME-BDD-INFRA", agc_around("invalid test index ", line, ""), span, NULL);
  agc_exit(vm, 1);
}

/* Ends the run as a return from main would: a crash nobody observed, such
   as one outside every test, makes it exit 1 with the summary line. */
static _Noreturn void finish_run(agc_vm *vm) {
  agc_flush(vm);
  agc_exit(vm, agc_report_unobserved(vm) ? 1 : 0);
}

/* Run mode is a retry builtin: each wake re-enters here and goes on from the
   state kept on the calling task. */
static agc_value builtin_run(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *tests = agc_as_list(vm, args[0]);
  agc_test_run *r = vm->task->test_run;
  if (!r) {
    if (vm->task->test || vm->test_active)
      agc_fail(vm, "RUNTIME-TEST-RUN", "Test.run cannot run inside a test or next to another Test.run", span);
    check_names(vm, tests);
    run_mode mode = mode_of(vm);
    if (mode == MODE_NONE) {
      static const char usage[] = "run this file with agentica test\n";
      agc_write(vm, vm->rt->err, usage, sizeof usage - 1);
      agc_exit(vm, 2);
    }
    if (mode == MODE_LIST) {
      write_list(vm, tests);
      finish_run(vm);
    }
    r = agc_alloc(sizeof(agc_test_run));
    vm->task->test_run = r;
    vm->test_active = true;
  }
  for (;;) {
    if (r->current) {
      if (wait_for(vm, r->current)) return agc_void();
      report(vm, r->current, r->test);
      r->current = NULL;
    }
    agc_string *line = NULL;
    agc_input_status status = agc_input_line(vm, &line);
    if (status == AGC_INPUT_WAIT) return agc_void();
    if (status != AGC_INPUT_OK) finish_run(vm);
    r->test = next_test(vm, tests, line, span);
    r->current = start_test(vm, r->test);
  }
}

const agc_builtin agc_test_builtins[] = {
  {"Test.test", 2, builtin_test, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.run", 1, builtin_run, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.eq", 2, builtin_eq, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.ok?", 1, builtin_ok, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.error?", 1, builtin_error, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Test.assert", 2, builtin_assert, AGC_NATIVE_NONE, AGC_COST_NONE},
};

const size_t agc_test_builtin_count = sizeof agc_test_builtins / sizeof agc_test_builtins[0];

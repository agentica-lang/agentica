/*
 * The builtin Error record in C (#671): agc_error and its location, the error builtins (error, Result.message,
 * Result.unwrap!), printing as the error(...) call, equality without the location, and hostile field values.
 */
#include "../core.h"
#include "builtin_test.h"
#include "test_program.h"
#include "test_support.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

enum { F_MAIN, F_PRELUDE, FUNCTIONS };
enum { CODE = 3, SPANS = FUNCTIONS * CODE };

typedef struct {
  agc_program program;
  agc_test_source src;
  agc_span span_table[SPANS];
  agc_function fns[FUNCTIONS];
  agc_instr code[SPANS];
  uint32_t spans[SPANS];
  agc_string *error_fields[AGC_ERROR_FIELDS];
  agc_struct_def structs[1];
  agc_enum_def enums[1];
  agc_variant_def variants[2];
} fixture;

static agc_vm vm;
static fixture *shapes;

static agc_string *text(const char *s) { return agc_make_string(s, strlen(s), strlen(s)); }

static bool same(const agc_string *s, const char *expected) {
  return s->bytes == strlen(expected) && memcmp(s->data, expected, s->bytes) == 0;
}

static void check(const agc_string *got, const char *expected) {
  if (!same(got, expected)) {
    fprintf(stderr, "got %.*s, want %s\n", (int)got->bytes, got->data, expected);
    assert(false);
  }
}

/* A program with the Error struct and the Optional enum, a user function and a prelude one. Span k of function f is
   on line f + 1 at column k + 1, of the source stored as "./std/x.agc" and joined to the folder "root". */
static fixture *build(void) {
  static const char *const fields[AGC_ERROR_FIELDS] = {"kind", "message", "code", "details", "cause", "location"};
  fixture *f = agc_alloc(sizeof *f);
  for (size_t k = 0; k < AGC_ERROR_FIELDS; k++) f->error_fields[k] = text(fields[k]);
  f->structs[0] = (agc_struct_def){text("Error"), AGC_ERROR_FIELDS, false, f->error_fields, NULL, NULL};
  f->enums[0] = (agc_enum_def){text("Optional"), 0, 2, NULL, NULL};
  f->variants[0] = (agc_variant_def){text("None"), 0, 0, agc_new_enum(0, 0)};
  f->variants[1] = (agc_variant_def){text("Some"), 0, 1, NULL};
  agc_source *source = &f->src.source;
  *source = (agc_source){.name = text("root/std/x.agc"), .stored = text("std/x.agc"), .text = text("x\nx\n")};
  source->lines = 1;
  source->line_start = f->src.line_start;
  source->line_chars = f->src.line_chars;
  f->src.line_chars[0] = 1;
  for (uint32_t at = 0; at < SPANS; at++) {
    uint32_t k = at / CODE, pc = at % CODE;
    f->spans[at] = at;
    f->span_table[at] = (agc_span){0, k + 1, pc + 1, k + 1, pc + 2};
  }
  for (uint32_t k = 0; k < FUNCTIONS; k++)
    f->fns[k] = (agc_function){.name = text(k == F_MAIN ? "main" : "to_result"), .registers = 1, .count = CODE,
                               .prelude = k == F_PRELUDE, .code = f->code + (size_t)k * CODE,
                               .spans = f->spans + (size_t)k * CODE};
  f->program.structs = f->structs;
  f->program.struct_count = 1;
  f->program.enums = f->enums;
  f->program.enum_count = 1;
  f->program.variants = f->variants;
  f->program.variant_count = 2;
  f->program.optional = 0;
  f->program.json_field = UINT32_MAX;
  f->program.spans = f->span_table;
  f->program.span_count = SPANS;
  f->program.sources = source;
  f->program.source_count = 1;
  f->program.functions = f->fns;
  f->program.function_count = FUNCTIONS;
  return f;
}

static agc_value call(const char *name, agc_value arg) {
  const agc_builtin *row = agc_find_builtin((const uint8_t *)name, strlen(name), 1);
  assert(row);
  return row->fn(&vm, &arg, 0);
}

static agc_value payload(agc_value result) {
  const agc_result *r = agc_as_result(&vm, result);
  assert(!r->ok);
  return r->value;
}

static agc_struct *error_of(agc_value result) { return agc_as_struct(&vm, payload(result)); }

static agc_value some(agc_value v) { return agc_optional_make(&shapes->program, true, v); }

/* main calls a prelude function at its second instruction, which calls a builtin at its third: the location is the
   user's call, past the prelude frame, as a stack trace shows it. Without a turn there is no frame. */
static void test_location(void) {
  agc_task *t = agc_test_task();
  t->frames = agc_alloc(2 * sizeof(agc_frame));
  t->frame_capacity = t->frame_count = 2;
  t->frames[0] = (agc_frame){.function = F_MAIN, .pc = 2};
  t->frames[1] = (agc_frame){.function = F_PRELUDE, .pc = 3};
  vm.task = t;
  vm.in_turn = true;
  check(agc_error_location(&vm), "std/x.agc:1:2");
  agc_struct *e = error_of(agc_error(&vm, "io.not_found", "no file"));
  assert(e->type == vm.rt->error_struct && e->n == AGC_ERROR_FIELDS);
  check(agc_as_string(&vm, e->fields[AGC_ERROR_KIND]), "io.not_found");
  check(agc_as_string(&vm, e->fields[AGC_ERROR_MESSAGE]), "no file");
  check(agc_as_string(&vm, e->fields[AGC_ERROR_LOCATION]), "std/x.agc:1:2");
  assert(agc_as_enum(&vm, e->fields[AGC_ERROR_CODE])->variant == 0);
  assert(agc_as_enum(&vm, e->fields[AGC_ERROR_CAUSE])->variant == 0);
  assert(agc_as_map(&vm, e->fields[AGC_ERROR_DETAILS])->size == 0);
  /* error("text") of an older front end: the builtin makes the Error, at the user's call. */
  e = error_of(call("error", agc_test_str("boom")));
  check(agc_as_string(&vm, e->fields[AGC_ERROR_KIND]), "error");
  check(agc_as_string(&vm, e->fields[AGC_ERROR_LOCATION]), "std/x.agc:1:2");
  /* error(e) keeps a located Error as it is, and fills an empty location (lowering leaves it empty in the prelude). */
  agc_value located = payload(agc_error(&vm, "error", "kept"));
  e->fields[AGC_ERROR_LOCATION] = agc_test_str("app.agc:9:9");
  assert(payload(call("error", agc_struct_value(e))).as.p == e);
  e->fields[AGC_ERROR_LOCATION] = agc_test_str("");
  agc_struct *placed = error_of(call("error", agc_struct_value(e)));
  assert(placed != e);
  check(agc_as_string(&vm, placed->fields[AGC_ERROR_LOCATION]), "std/x.agc:1:2");
  check(agc_as_string(&vm, e->fields[AGC_ERROR_LOCATION]), "");
  vm.in_turn = false;
  check(agc_error_location(&vm), "");
  check(agc_as_string(&vm, agc_as_struct(&vm, located)->fields[AGC_ERROR_LOCATION]), "std/x.agc:1:2");
  vm.task = vm.rt->main;
}

/* An Error of the given fields, located at app.agc:1:1. */
static agc_value make(const char *kind, const char *message, agc_value code, agc_value details, agc_value cause) {
  agc_struct *e = agc_new_struct(vm.rt->error_struct, AGC_ERROR_FIELDS);
  e->fields[AGC_ERROR_KIND] = agc_test_str(kind);
  e->fields[AGC_ERROR_MESSAGE] = agc_test_str(message);
  e->fields[AGC_ERROR_CODE] = code;
  e->fields[AGC_ERROR_DETAILS] = details;
  e->fields[AGC_ERROR_CAUSE] = cause;
  e->fields[AGC_ERROR_LOCATION] = agc_test_str("app.agc:1:1");
  return agc_struct_value(e);
}

static agc_value plain(const char *message) {
  agc_value none = agc_optional_make(&shapes->program, false, agc_void());
  return make("error", message, none, vm.rt->empty_map, none);
}

/* inspect is the error(...) call without defaults or location, and a failed Result that holds an Error prints the
   same call once; to_s and interpolation give the message. */
static void test_printing(void) {
  agc_value boom = plain("boom");
  check(agc_debug(&vm, boom), "error(\"boom\")");
  check(agc_debug(&vm, agc_result_value(false, boom)), "error(\"boom\")");
  check(agc_debug(&vm, agc_result_value(true, boom)), "ok(error(\"boom\"))");
  check(agc_debug(&vm, agc_list_value(agc_list_from_array(&boom, 1))), "[error(\"boom\")]");
  check(agc_test_text(&vm, agc_result_value(false, boom)), "error(\"boom\")");
  check(agc_text(&vm, boom), "boom");
  agc_string *interpolated = NULL;
  assert(agc_text_checked(&vm, boom, &interpolated));
  check(interpolated, "boom");
  agc_map *details = agc_map_put(&vm, agc_new_map(), agc_test_str("line"), agc_test_str("12"));
  agc_value full = make("db.constraint", "unique failed", some(agc_int(19)), agc_map_value(details), some(boom));
  check(agc_debug(&vm, agc_result_value(false, full)),
        "error(\"unique failed\", kind: \"db.constraint\", code: 19, details: {\"line\": \"12\"}, cause: error(\"boom\"))");
  /* A struct of this shape from a hostile file: fields of other types print as they are, and none is skipped. */
  agc_value odd = make("error", "odd", agc_int(7), agc_list_value(agc_list_from_array(NULL, 0)), agc_bool(true));
  agc_as_struct(&vm, odd)->fields[AGC_ERROR_KIND] = agc_int(5);
  check(agc_debug(&vm, odd), "error(\"odd\", kind: 5, code: 7, details: [], cause: true)");
}

/* == compares kind, message, code, details and cause, never the location. */
static void test_equality(void) {
  const agc_builtin *row = agc_find_builtin((const uint8_t *)"Value.equal", 11, 2);
  agc_value a = plain("boom"), b = plain("boom");
  agc_as_struct(&vm, b)->fields[AGC_ERROR_LOCATION] = agc_test_str("other.agc:4:2");
  agc_value pair[] = {agc_result_value(false, a), agc_result_value(false, b)};
  assert(agc_as_bool(&vm, row->fn(&vm, pair, 0)));
  agc_as_struct(&vm, b)->fields[AGC_ERROR_KIND] = agc_test_str("db");
  assert(!agc_as_bool(&vm, row->fn(&vm, pair, 0)));
  agc_value messages[] = {plain("boom"), plain("bang")};
  assert(!agc_as_bool(&vm, row->fn(&vm, messages, 0)));
}

/* Result.message gives the text, and a halt shows " (kind)" after it unless the kind is the default. */
static void test_readers(void) {
  agc_value none = agc_optional_make(&shapes->program, false, agc_void());
  agc_value db = make("db", "boom", none, vm.rt->empty_map, none);
  check(agc_as_string(&vm, call("Result.message", agc_result_value(false, db))), "boom");
  check(agc_error_message(&vm, agc_test_str("text")), "text");
  check(agc_error_halt_text(&vm, plain("boom")), "boom");
  check(agc_error_halt_text(&vm, db), "boom (db)");
  agc_value failed = agc_result_value(false, db);
  const agc_builtin *unwrap = agc_find_builtin((const uint8_t *)"Result.unwrap!", 14, 1);
  assert(strcmp(agc_test_fail_code(&vm, unwrap, &failed), "RUNTIME-UNWRAP-ERROR") == 0);
  assert(vm.outcome->message_len == 9 && memcmp(vm.outcome->message, "boom (db)", 9) == 0);
  /* A message that is not a String is a wrong tag, not a read of other memory. */
  agc_as_struct(&vm, db)->fields[AGC_ERROR_MESSAGE] = agc_int(1);
  const agc_builtin *message = agc_find_builtin((const uint8_t *)"Result.message", 14, 1);
  assert(strcmp(agc_test_fail_code(&vm, message, &failed), "RUNTIME-INTERNAL") == 0);
}

/* A program without the struct keeps String payloads, which every reader takes as before. */
static void test_fallback(void) {
  uint32_t found = vm.rt->error_struct;
  vm.rt->error_struct = UINT32_MAX;
  agc_value s = payload(agc_error(&vm, "io.not_found", "no file"));
  check(agc_as_string(&vm, s), "no file");
  check(agc_debug(&vm, agc_result_value(false, s)), "error(\"no file\")");
  check(agc_error_halt_text(&vm, s), "no file");
  assert(agc_is(payload(call("error", agc_test_str("boom"))), AGC_T_STRING));
  vm.rt->error_struct = found;
}

int main(void) {
  agc_init();
  shapes = build();
  agc_vm_init(&vm, &shapes->program, stdout, stderr, INT64_MAX);
  assert(vm.rt->error_struct == 0);
  AGC_TEST_RUN(test_location());
  AGC_TEST_RUN(test_printing());
  AGC_TEST_RUN(test_equality());
  AGC_TEST_RUN(test_readers());
  AGC_TEST_RUN(test_fallback());
  puts("error tests passed");
  return 0;
}

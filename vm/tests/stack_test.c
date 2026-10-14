/*
 * agc_stack_capture and the three printers on hand-built tasks: frames in main
 * and in a spawned task, with native frames skipped.
 */
#include "../core.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>

#define FUNCTIONS 6
#define CODE 4
#define SPANS (FUNCTIONS * CODE + 1)
#define LINE_CHARS 30
#define LINE "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

enum { F_MAIN, F_PUSH, F_BLOCK, F_WALK, F_BREAK, F_SPARE };

typedef struct {
  agc_function fns[FUNCTIONS];
  agc_instr code[FUNCTIONS][CODE];
  uint32_t spans[FUNCTIONS][CODE];
  agc_span span_table[SPANS];
  agc_source source;
  uint32_t line_start[1], line_chars[1];
  agc_program program;
} fixture;

static int marker;

static uint32_t span_at(uint32_t function, uint32_t pc) { return function * CODE + pc - 1; }

static fixture *build(void) {
  fixture *f = calloc(1, sizeof *f);
  assert(f);
  static const char *names[FUNCTIONS] = {"main", "@12::push", "block@t.agc:3:4", "walk", "a\nb", "@7::"};
  char text[LINE_CHARS + 1];
  memset(text, 'x', LINE_CHARS);
  text[LINE_CHARS] = '\0';
  f->source.name = agc_make_string("t.agc", 5, 5);
  f->source.text = agc_make_string(text, LINE_CHARS, LINE_CHARS);
  f->source.lines = 1;
  f->source.line_start = f->line_start;
  f->source.line_chars = f->line_chars;
  f->line_chars[0] = LINE_CHARS;
  for (uint32_t i = 0; i < SPANS; i++) {
    f->span_table[i].start_line = f->span_table[i].end_line = 1;
    f->span_table[i].start_column = i + 1;
    f->span_table[i].end_column = i + 2;
  }
  for (uint32_t k = 0; k < FUNCTIONS; k++) {
    agc_function *fn = &f->fns[k];
    fn->name = agc_make_string(names[k], strlen(names[k]), strlen(names[k]));
    fn->registers = 1;
    fn->count = CODE;
    fn->code = f->code[k];
    fn->spans = f->spans[k];
    for (uint32_t pc = 0; pc < CODE; pc++) f->spans[k][pc] = k * CODE + pc;
  }
  f->program.span_count = SPANS;
  f->program.spans = f->span_table;
  f->program.source_count = 1;
  f->program.sources = &f->source;
  f->program.function_count = FUNCTIONS;
  f->program.functions = f->fns;
  return f;
}

static void frames(agc_task *t, uint32_t count) {
  t->frames = calloc(count, sizeof(agc_frame));
  assert(t->frames);
  t->frame_capacity = t->frame_count = count;
}

static void frame(agc_task *t, uint32_t index, uint32_t function, uint32_t pc, bool tail) {
  t->frames[index].function = function;
  t->frames[index].pc = pc;
  t->frames[index].tail = tail;
}

static void native(agc_task *t, uint32_t index) { t->frames[index].native = (agc_native *)&marker; }

static agc_outcome failure(uint32_t span) {
  agc_outcome o;
  memset(&o, 0, sizeof o);
  o.kind = AGC_FAILED;
  o.code = "RUNTIME-TEST";
  o.message = "boom";
  o.message_len = 4;
  o.span = span;
  return o;
}

static void begin(agc_vm *vm, fixture *f, agc_task *t) {
  agc_vm_init(vm, &f->program, stdout, stderr, INT64_MAX);
  vm->task = t ? t : vm->main;
  vm->in_turn = true;
}

static char *render(const fixture *f, const agc_outcome *o, agc_style style, bool task) {
  FILE *out = tmpfile();
  assert(out);
  agc_print_diagnostic(out, &f->program, o, style, task);
  long size = ftell(out);
  assert(size >= 0);
  rewind(out);
  char *text = calloc((size_t)size + 1, 1);
  assert(text && fread(text, 1, (size_t)size, out) == (size_t)size);
  fclose(out);
  return text;
}

static void check_text(char *got, const char *want) {
  if (strcmp(got, want) != 0) {
    fprintf(stderr, "got:\n%s\nwant:\n%s\n", got, want);
    assert(false);
  }
  free(got);
}

static void alone(void) {
  fixture *f = build();
  agc_vm vm;
  begin(&vm, f, NULL);
  agc_task *t = vm.main;
  frames(t, 1);
  frame(t, 0, F_MAIN, 3, false);
  agc_outcome o = failure(span_at(F_MAIN, 3));
  agc_stack_capture(&vm, &o);
  assert(!o.stack.shown);
  char *text = render(f, &o, AGC_STYLE_JSON, false);
  assert(!strstr(text, "stack"));
  free(text);

  vm.in_turn = false;
  frames(t, 2);
  frame(t, 0, F_MAIN, 3, false);
  frame(t, 1, F_PUSH, 2, false);
  agc_stack_capture(&vm, &o);
  assert(!o.stack.shown);
  vm.in_turn = true;
  agc_stack_capture(&vm, &o);
  assert(o.stack.shown && o.stack.count == 2 && !o.stack.spawned);

  agc_task *spawned = agc_new_task(&vm);
  vm.task = spawned;
  frames(spawned, 1);
  frame(spawned, 0, F_PUSH, 1, false);
  spawned->spawned = true;
  spawned->spawn_span = span_at(F_MAIN, 2);
  o = failure(span_at(F_PUSH, 1));
  agc_stack_capture(&vm, &o);
  assert(o.stack.shown && o.stack.count == 1 && o.stack.spawned && o.stack.spawn_span == span_at(F_MAIN, 2));
  check_text(render(f, &o, AGC_STYLE_PLAIN, true),
             "t.agc:1:5 error[RUNTIME-TEST] in a task\n"
             "boom\n"
             "\n"
             "1 | " LINE "\n"
             "  |     ^\n"
             "  = stack, innermost first:\n"
             "    push at t.agc:1:5\n"
             "    task spawned at t.agc:1:2\n");
  free(f);
}

static void nested(void) {
  fixture *f = build();
  agc_vm vm;
  begin(&vm, f, NULL);
  agc_task *t = vm.main;
  frames(t, 4);
  frame(t, 0, F_MAIN, 2, false);
  frame(t, 1, F_PUSH, 3, false);
  frame(t, 2, F_BLOCK, 1, false);
  native(t, 2);
  frame(t, 3, F_BREAK, 2, true);
  agc_outcome o = failure(span_at(F_BREAK, 2));
  agc_stack_capture(&vm, &o);
  assert(o.stack.shown && o.stack.count == 3 && o.stack.head == 3 && o.stack.omitted == 0);
  assert(o.stack.lines[0].function == F_BREAK && o.stack.lines[0].span == o.span && o.stack.lines[0].tail);
  assert(o.stack.lines[1].function == F_PUSH && o.stack.lines[1].span == span_at(F_PUSH, 3));
  assert(o.stack.lines[2].function == F_MAIN && o.stack.lines[2].span == span_at(F_MAIN, 2));
  check_text(render(f, &o, AGC_STYLE_AI, false),
             "check failed: 1 error\n"
             "\n"
             "[RUNTIME-TEST]\n"
             "  message: boom\n"
             "  at: t.agc:1:18\n"
             "  source: " LINE "\n"
             "  stack:\n"
             "    a\\nb at t.agc:1:18 (after a tail call)\n"
             "    push at t.agc:1:7\n"
             "    main at t.agc:1:2\n");
  check_text(render(f, &o, AGC_STYLE_JSON, true),
             "{\"code\":\"RUNTIME-TEST\",\"file\":\"t.agc\",\"message\":\"boom\","
             "\"range\":{\"end\":{\"column\":19,\"line\":1},\"start\":{\"column\":18,\"line\":1}},"
             "\"stack\":[{\"column\":18,\"file\":\"t.agc\",\"function\":\"a\\nb\",\"line\":1,\"tail\":true},"
             "{\"column\":7,\"file\":\"t.agc\",\"function\":\"push\",\"line\":1},"
             "{\"column\":2,\"file\":\"t.agc\",\"function\":\"main\",\"line\":1}],\"task\":true}\n");
  free(f);
}

static void repeats(void) {
  fixture *f = build();
  agc_vm vm;
  begin(&vm, f, NULL);
  agc_task *t = vm.main;
  frames(t, 9);
  frame(t, 0, F_MAIN, 2, false);
  for (uint32_t i = 1; i <= 5; i++) frame(t, i, F_WALK, 3, false);
  frame(t, 6, F_WALK, 3, true);
  frame(t, 7, F_WALK, 3, true);
  frame(t, 8, F_WALK, 2, false);
  agc_outcome o = failure(span_at(F_WALK, 2));
  agc_stack_capture(&vm, &o);
  assert(o.stack.shown && o.stack.count == 4);
  assert(o.stack.lines[0].repeat == 1 && o.stack.lines[0].span == span_at(F_WALK, 2));
  assert(o.stack.lines[1].repeat == 2 && o.stack.lines[1].tail && o.stack.lines[1].span == span_at(F_WALK, 3));
  assert(o.stack.lines[2].repeat == 5 && !o.stack.lines[2].tail);
  assert(o.stack.lines[3].repeat == 1 && o.stack.lines[3].function == F_MAIN);
  char *text = render(f, &o, AGC_STYLE_JSON, false);
  assert(strstr(text, "\"line\":1,\"repeat\":2,\"tail\":true}"));
  assert(strstr(text, "\"line\":1,\"repeat\":5}"));
  free(text);
  text = render(f, &o, AGC_STYLE_PLAIN, false);
  assert(strstr(text, "    walk at t.agc:1:15 (2 times) (after a tail call)\n"));
  assert(strstr(text, "    walk at t.agc:1:15 (5 times)\n"));
  free(text);

  frames(t, 10000);
  for (uint32_t i = 0; i < 10000; i++) frame(t, i, F_WALK, 3, false);
  o = failure(span_at(F_WALK, 3));
  agc_stack_capture(&vm, &o);
  assert(o.stack.shown && o.stack.count == 1 && o.stack.lines[0].repeat == 10000 && o.stack.omitted == 0);
  free(f);
}

static void cap(uint32_t depth, uint32_t omitted) {
  fixture *f = build();
  agc_vm vm;
  begin(&vm, f, NULL);
  agc_task *t = vm.main;
  frames(t, depth);
  for (uint32_t i = 0; i < depth; i++) frame(t, i, i % 2 ? F_PUSH : F_WALK, 1 + i % 3, false);
  agc_outcome o = failure(span_at(F_PUSH, 1));
  agc_stack_capture(&vm, &o);
  assert(o.stack.shown && o.stack.count == AGC_STACK_HEAD + AGC_STACK_TAIL && o.stack.head == AGC_STACK_HEAD);
  assert(o.stack.omitted == omitted);
  for (uint32_t i = 0; i < AGC_STACK_TAIL; i++) {
    const agc_frame *at = &t->frames[AGC_STACK_TAIL - 1 - i];
    assert(o.stack.lines[AGC_STACK_HEAD + i].function == at->function);
    assert(o.stack.lines[AGC_STACK_HEAD + i].span == span_at(at->function, at->pc));
  }
  for (uint32_t i = 1; i < AGC_STACK_HEAD; i++) {
    const agc_frame *at = &t->frames[depth - 1 - i];
    assert(o.stack.lines[i].function == at->function);
    assert(o.stack.lines[i].span == span_at(at->function, at->pc));
  }
  char *text = render(f, &o, AGC_STYLE_PLAIN, false);
  char want[64];
  snprintf(want, sizeof want, "    ... %u frame%s not shown ...\n", (unsigned)omitted, omitted == 1 ? "" : "s");
  assert(strstr(text, want));
  free(text);
  text = render(f, &o, AGC_STYLE_JSON, false);
  snprintf(want, sizeof want, "],\"stack_omitted\":%u}\n", (unsigned)omitted);
  assert(strstr(text, want));
  free(text);
  free(f);
}

static void exact(void) {
  fixture *f = build();
  agc_vm vm;
  begin(&vm, f, NULL);
  agc_task *t = vm.main;
  frames(t, 20);
  for (uint32_t i = 0; i < 20; i++) frame(t, i, i % 2 ? F_PUSH : F_WALK, 1 + i % 3, false);
  agc_outcome o = failure(span_at(F_PUSH, 1));
  agc_stack_capture(&vm, &o);
  assert(o.stack.shown && o.stack.count == 20 && o.stack.head == 20 && o.stack.omitted == 0);
  char *text = render(f, &o, AGC_STYLE_PLAIN, false);
  assert(!strstr(text, "not shown"));
  free(text);
  free(f);
}

static void hostile(void) {
  fixture *f = build();
  agc_vm vm;
  begin(&vm, f, NULL);
  agc_task *t = vm.main;
  frames(t, 6);
  frame(t, 0, F_MAIN, 0, false);
  frame(t, 1, FUNCTIONS, 2, false);
  frame(t, 2, F_PUSH, 4000000000u, false);
  frame(t, 3, F_SPARE, CODE + 1, false);
  frame(t, 4, 4000000000u, 1, false);
  frame(t, 5, F_WALK, 1, false);
  agc_outcome o = failure(SPANS + 5);
  agc_stack_capture(&vm, &o);
  assert(o.stack.shown && o.stack.count == 4);
  assert(o.stack.lines[0].function == F_WALK && o.stack.lines[0].span == 0);
  assert(o.stack.lines[1].function == F_SPARE && o.stack.lines[1].span == span_at(F_SPARE, CODE));
  assert(o.stack.lines[2].function == F_PUSH && o.stack.lines[2].span == span_at(F_PUSH, CODE));
  assert(o.stack.lines[3].function == F_MAIN && o.stack.lines[3].span == span_at(F_MAIN, 1));
  o.span = 0;
  free(render(f, &o, AGC_STYLE_JSON, true));
  free(render(f, &o, AGC_STYLE_AI, true));
  free(render(f, &o, AGC_STYLE_PLAIN, true));

  t->spawned = true;
  t->spawn_span = SPANS;
  agc_stack_capture(&vm, &o);
  assert(o.stack.shown && !o.stack.spawned);

  t->frame_count = t->frame_capacity + 1;
  agc_stack_capture(&vm, &o);
  assert(!o.stack.shown);
  t->frame_count = 0;
  agc_stack_capture(&vm, &o);
  assert(!o.stack.shown);
  t->frames = NULL;
  t->frame_count = 3;
  agc_stack_capture(&vm, &o);
  assert(!o.stack.shown);

  vm.task = NULL;
  agc_stack_capture(&vm, &o);
  assert(!o.stack.shown);

  agc_task *natives = agc_new_task(&vm);
  vm.task = natives;
  frames(natives, 3);
  for (uint32_t i = 0; i < 3; i++) native(natives, i);
  agc_stack_capture(&vm, &o);
  assert(!o.stack.shown);
  free(f);
}

static void names(void) {
  fixture *f = build();
  agc_vm vm;
  begin(&vm, f, NULL);
  agc_task *t = vm.main;
  frames(t, 4);
  frame(t, 0, F_SPARE, 1, false);
  frame(t, 1, F_PUSH, 1, false);
  frame(t, 2, F_BLOCK, 1, false);
  frame(t, 3, F_BREAK, 1, false);
  agc_outcome o = failure(span_at(F_BREAK, 1));
  agc_stack_capture(&vm, &o);
  char *text = render(f, &o, AGC_STYLE_PLAIN, false);
  assert(strstr(text, "    a\\nb at t.agc:1:17\n    block at t.agc:1:9\n    push at t.agc:1:5\n    @7:: at t.agc:1:21\n"));
  free(text);
  free(f);
}

int main(void) {
  alone();
  nested();
  repeats();
  cap(40, 20);
  cap(21, 1);
  exact();
  hostile();
  names();
  return 0;
}

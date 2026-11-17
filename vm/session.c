/*
 * FrontEnd.serve_session: the main loop of `agentica run --session`, the child of `agentica repl`. It reads each entry
 * from the parent channel (the session's whole program, then the entry function and its slots), loads the program
 * over the running one (agc_load_session), runs the program's new init function and then the entry as tasks, keeps
 * the values the entry gives back in the session slots, and answers one JSON line. Tasks that an entry starts live
 * on. Service layer. Design: docs/vm/08-loader-and-cli.md (§8, §9).
 */
#include "services.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The most slots a session has, and so the longest list of slots an entry names: as many as a file's Globals. */
#define SLOTS_MAX 65535

/* The session of the runtime (agc_runtime.session): the values of the session's names, the program bytes received so
   far, and the request being served, all in GC memory that the runtime keeps alive. Only the main task reads it. */
struct agc_session {
  agc_value *slots;
  uint32_t slot_count, slot_cap;
  uint8_t *bytes;
  size_t len, cap;
  agc_string *record;
  agc_task *current;
  const char *problem;
  /* The entry loaded a program, which stays loaded whatever its answer: the answer says "loaded". */
  bool loaded;
  bool in_init, deny_native;
  uint32_t entry, read_count, write_count;
  uint32_t *reads, *writes;
};

agc_session *agc_session_new(bool deny_native) {
  agc_session *s = agc_alloc(sizeof(agc_session));
  memset(s, 0, sizeof *s);
  s->deny_native = deny_native;
  return s;
}

static agc_string *lit(const char *text) {
  size_t n = strlen(text);
  return agc_make_string(text, n, n);
}

static agc_json_member *members(size_t n) { return agc_alloc(agc_size_mul(n, sizeof(agc_json_member))); }

static agc_json_member yes(const char *key) {
  return agc_json_pair(key, agc_json_leaf(AGC_JSON_BOOL, agc_bool(true)));
}

static agc_value json_text(agc_string *s) { return agc_json_leaf(AGC_JSON_STRING, agc_string_value(s)); }

static agc_string *refused(agc_vm *vm, const char *message) {
  agc_json_member *m = members(2);
  m[0] = agc_json_pair("ok", agc_json_leaf(AGC_JSON_BOOL, agc_bool(false)));
  m[1] = agc_json_pair("refused", json_text(lit(message)));
  return agc_json_line(vm, m, 2);
}

/* The failure as the front end shows it: the diagnostic's fields, as a --json run prints them, and its text in the
   style of the run (plain, --ai or --json), which the front end prints as it is. LOADED: the entry's program stays. */
static agc_string *failure(agc_vm *vm, const agc_program *p, const agc_outcome *o, bool loaded) {
  const agc_span *at = &p->spans[o->span < p->span_count ? o->span : 0];
  agc_json_member *d = members(7);
  size_t count = 0;
  d[count++] = agc_json_pair("code", json_text(lit(o->code)));
  d[count++] = agc_json_pair("file", json_text(p->sources[at->source].name));
  agc_string *message = agc_utf8_decode((const uint8_t *)o->message, o->message_len, "\xEF\xBF\xBD");
  d[count++] = agc_json_pair("message", json_text(message));
  d[count++] = agc_json_pair("range", agc_span_range(at));
  if (o->stack.shown) count += agc_stack_members(p, &o->stack, d + count);
  agc_json_member *m = members(4);
  size_t n = 0;
  m[n++] = agc_json_pair("diagnostic", agc_json_object(d, count));
  if (loaded) m[n++] = yes("loaded");
  m[n++] = agc_json_pair("ok", agc_json_leaf(AGC_JSON_BOOL, agc_bool(false)));
  agc_memstream *ms = NULL;
  FILE *file = agc_memstream_open(&ms);
  if (file) {
    agc_print_diagnostic(file, p, o, vm->rt->style, false);
    char *text = NULL;
    size_t len = 0;
    if (agc_memstream_take(file, ms, &text, &len) && text)
      m[n++] = agc_json_pair("text", json_text(agc_utf8_decode((const uint8_t *)text, len, "\xEF\xBF\xBD")));
    free(text);
  }
  return agc_json_line(vm, m, n);
}

static agc_string *crashed(agc_vm *vm, agc_session *s, agc_task *t) {
  agc_outcome o;
  memset(&o, 0, sizeof o);
  o.kind = AGC_FAILED;
  o.code = t->crash_code;
  o.message = t->crash_message->data;
  o.message_len = t->crash_message->bytes;
  o.span = t->crash_span;
  if (t->crash_stack) o.stack = *t->crash_stack;
  agc_task_observe(vm, t);
  return failure(vm, vm->rt->program, &o, s->loaded);
}

/* An entry that ran but gave back what no entry gives: its effects stay, so it is not refused. */
static agc_string *invalid(agc_vm *vm, agc_session *s, const char *message) {
  agc_json_member *m = members(3);
  size_t n = 0;
  m[n++] = agc_json_pair("invalid", json_text(lit(message)));
  if (s->loaded) m[n++] = yes("loaded");
  m[n++] = agc_json_pair("ok", agc_json_leaf(AGC_JSON_BOOL, agc_bool(false)));
  return agc_json_line(vm, m, n);
}

static void grow_slots(agc_session *s, uint32_t count) {
  if (count <= s->slot_count) return;
  if (count > s->slot_cap) {
    uint32_t cap = s->slot_cap ? s->slot_cap : 16;
    while (cap < count) cap *= 2;
    agc_value *grown = agc_alloc(agc_size_mul(cap, sizeof(agc_value)));
    for (uint32_t k = 0; k < s->slot_count; k++) grown[k] = s->slots[k];
    s->slots = grown;
    s->slot_cap = cap;
  }
  for (uint32_t k = s->slot_count; k < count; k++) s->slots[k] = agc_void();
  s->slot_count = count;
}

/* The answer of an entry that returned: its result is a List of the shown value (a String, Void for none, or any
   value, shown with inspect) and the values of the written slots, in order. */
static agc_string *returned(agc_vm *vm, agc_session *s, agc_value result) {
  if (!agc_is(result, AGC_T_LIST)) return invalid(vm, s, "the entry did not return a list");
  const agc_list *list = agc_as_list(vm, result);
  if (agc_list_len(list) != (size_t)s->write_count + 1)
    return invalid(vm, s, "the entry returned a list of another size");
  uint32_t top = 0;
  for (uint32_t k = 0; k < s->write_count; k++)
    if (s->writes[k] + 1 > top) top = s->writes[k] + 1;
  grow_slots(s, top);
  for (uint32_t k = 0; k < s->write_count; k++) s->slots[s->writes[k]] = agc_list_get(list, k + 1);
  agc_value shown = agc_list_get(list, 0);
  agc_json_member *m = members(3);
  size_t n = 0;
  if (s->loaded) m[n++] = yes("loaded");
  m[n++] = yes("ok");
  if (agc_is(shown, AGC_T_STRING))
    m[n++] = agc_json_pair("value", json_text(agc_as_string(vm, shown)));
  else if (!agc_is(shown, AGC_T_VOID))
    m[n++] = agc_json_pair("value", json_text(agc_debug(vm, shown)));
  return agc_json_line(vm, m, n);
}

static int hex_digit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  return -1;
}

/* "chunk HEX": the next bytes of the program, in lower-case hex. */
static const char *take_chunk(agc_session *s, const char *hex, size_t n) {
  if (n % 2) return "a chunk has an odd number of digits";
  size_t add = n / 2;
  if (add > AGC_MAX_FILE_BYTES - s->len) return "the program is too large";
  if (s->len + add > s->cap) {
    size_t cap = s->cap ? s->cap : 4096;
    while (cap < s->len + add) cap = agc_size_mul(cap, 2);
    uint8_t *grown = agc_alloc_atomic(cap);
    if (s->len) memcpy(grown, s->bytes, s->len);
    s->bytes = grown;
    s->cap = cap;
  }
  for (size_t k = 0; k < add; k++) {
    int high = hex_digit(hex[2 * k]), low = hex_digit(hex[2 * k + 1]);
    if (high < 0 || low < 0) return "a chunk has a character that is not a hex digit";
    s->bytes[s->len++] = (uint8_t)(high * 16 + low);
  }
  return NULL;
}

/* A decimal of at most 9 digits at *at, which moves past it. */
static bool take_number(const char **at, const char *end, uint32_t *out) {
  const char *p = *at;
  uint32_t n = 0;
  int digits = 0;
  while (p < end && *p >= '0' && *p <= '9' && digits < 9) {
    n = n * 10 + (uint32_t)(*p - '0');
    p++;
    digits++;
  }
  if (!digits) return false;
  *at = p;
  *out = n;
  return true;
}

/* A list of slots: "-" for none, else decimals joined by ",". */
static bool take_slots(const char **at, const char *end, uint32_t **out, uint32_t *count) {
  const char *p = *at;
  *count = 0;
  *out = NULL;
  if (p < end && *p == '-') {
    *at = p + 1;
    return true;
  }
  size_t n = 1;
  for (const char *q = p; q < end && *q != ' '; q++)
    if (*q == ',') n++;
  if (n > SLOTS_MAX) return false;
  uint32_t *slots = agc_alloc_atomic(n * sizeof(uint32_t));
  for (size_t k = 0; k < n; k++) {
    if (k && (p >= end || *p++ != ',')) return false;
    if (!take_number(&p, end, &slots[k]) || slots[k] >= SLOTS_MAX) return false;
  }
  *at = p;
  *out = slots;
  *count = (uint32_t)n;
  return true;
}

static agc_task *spawn(agc_vm *vm, uint32_t function, const agc_value *args, uint32_t argc, uint32_t span) {
  agc_task *t = agc_task_spawn_seeded(vm, vm->task, agc_fn_value(agc_new_fn(function, 0)), args, argc, span);
  t->session = true;
  return t;
}

static void start_entry(agc_vm *vm, agc_session *s, uint32_t span) {
  agc_value *args = agc_alloc(agc_size_mul(s->read_count ? s->read_count : 1, sizeof(agc_value)));
  for (uint32_t k = 0; k < s->read_count; k++) args[k] = s->slots[s->reads[k]];
  s->current = spawn(vm, s->entry, args, s->read_count, span);
}

/* "entry FN READS WRITES": load the program received so far (none: the running one stays), then run its init
   function when it is new and the entry function FN with the values of the slots READS as arguments. */
static const char *take_entry(agc_vm *vm, agc_session *s, const char *at, const char *end, uint32_t span) {
  const uint8_t *bytes = s->bytes;
  size_t len = s->len;
  const char *problem = s->problem;
  s->bytes = NULL;
  s->len = s->cap = 0;
  s->problem = NULL;
  if (problem) return problem;
  if (!take_number(&at, end, &s->entry) || at >= end || *at++ != ' ' ||
      !take_slots(&at, end, &s->reads, &s->read_count) || at >= end || *at++ != ' ' ||
      !take_slots(&at, end, &s->writes, &s->write_count) || at != end)
    return "a bad entry line";
  for (uint32_t k = 0; k < s->read_count; k++)
    if (s->reads[k] >= s->slot_count) return "the entry reads a slot that has no value";
  const agc_program *base = vm->rt->program;
  const agc_program *next = base;
  if (len) {
    agc_program *loaded = NULL;
    char error[160];
    if (!agc_load_session(bytes, len, base, &loaded, error, sizeof error, &vm->rt->trace)) {
      s->record = refused(vm, error);
      return NULL;
    }
    agc_outcome o;
    memset(&o, 0, sizeof o);
    o.kind = AGC_FAILED;
    o.code = agc_ffi_refusal(loaded, s->deny_native, &o.message, &o.span);
    if (o.code) {
      o.message_len = strlen(o.message);
      s->record = failure(vm, loaded, &o, false);
      return NULL;
    }
    next = loaded;
  }
  const agc_function *f = s->entry < next->function_count ? &next->functions[s->entry] : NULL;
  if (!f || f->params != s->read_count || f->captures != 0) return "the entry function does not take the slots";
  for (uint32_t pc = 0; pc < f->count; pc++)
    if (f->code[pc].op == AGC_OP_GLOBAL_SET) return "the entry function is an init function";
  /* One scheduler runs (run --session), so no other turn holds the old program, and this task parks below before its
     own turn reads the table again (turn_loop reads it once per turn). */
  vm->rt->program = next;
  s->loaded = next != base;
  /* agc_load_session refused new slots without a new init function to set them. */
  if (next != base && next->entry >= base->function_count) {
    s->in_init = true;
    s->current = spawn(vm, next->entry, NULL, 0, span);
  } else {
    start_entry(vm, s, span);
  }
  return NULL;
}

static void serve_line(agc_vm *vm, agc_session *s, const agc_string *line, uint32_t span) {
  const char *text = line->data, *end = line->data + line->bytes;
  if (line->bytes > 6 && memcmp(text, "chunk ", 6) == 0) {
    /* A chunk has no answer: its problem is the answer of the entry that follows. */
    if (!s->problem) s->problem = take_chunk(s, text + 6, line->bytes - 6);
    return;
  }
  const char *problem = "an unknown request";
  s->loaded = false;
  if (line->bytes > 6 && memcmp(text, "entry ", 6) == 0) problem = take_entry(vm, s, text + 6, end, span);
  if (problem) s->record = refused(vm, problem);
}

/* A retry builtin of the main task, like Test.run (vm/testing.c): each wake comes back here and goes on from the
   session's state. The end of the channel ends the run with 0, a broken or missing channel with 1. */
agc_value agc_session_serve(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  agc_session *s = vm->rt->session;
  if (!s)
    agc_fail(vm, "RUNTIME-FRONT-END-ONLY", "FrontEnd.serve_session is for the session child of agentica repl", span);
  if (vm->task != vm->rt->main)
    agc_fail(vm, "RUNTIME-FRONT-END-ONLY", "call FrontEnd.serve_session from main", span);
  if (!agc_parent_open(vm)) agc_exit(vm, 1);
  for (;;) {
    if (s->record) {
      if (!agc_drain(vm) || !agc_parent_send(vm, s->record)) return agc_void();
      s->record = NULL;
    }
    if (s->current) {
      if (agc_task_join(vm, s->current)) return agc_void();
      agc_task *t = s->current;
      s->current = NULL;
      if (t->crashed) {
        /* A crashed init leaves its program loaded, as the front end keeps its declarations; a later read of a slot it
           did not set fails that entry with RUNTIME-NO-VALUE (vm/task.c). */
        s->in_init = false;
        s->record = crashed(vm, s, t);
      } else if (s->in_init) {
        s->in_init = false;
        start_entry(vm, s, span);
      } else {
        s->record = returned(vm, s, t->result);
      }
      continue;
    }
    agc_string *line = NULL;
    agc_input_status status = agc_parent_line(vm, &line);
    if (status == AGC_INPUT_WAIT) return agc_void();
    /* The end of the channel ends the session, as the front end has gone; a line the channel refused (over 1 MiB, or
       cut off at the end) is a broken session. */
    if (status != AGC_INPUT_OK) agc_exit(vm, status == AGC_INPUT_EOF ? 0 : 1);
    serve_line(vm, s, line, span);
  }
}

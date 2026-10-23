/*
 * The profile (AGENTICA_VM_TRACE=profile): the counters of a run, which interp.c fills through its profile hooks, the
 * sections of Profile.measure, the stacks sampled for folded output (AGENTICA_PROFILE_FORMAT=folded), and the report
 * written at the end of the run. Profile.steps, the step count of a task, works with the profile off too.
 * Core layer. Design: docs/vm/08-loader-and-cli.md §9.
 */
#include "core.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#define PROFILE_TOP 30
#define PROFILE_FILES 12
#define PROFILE_PAIRS 20
#define SHARE_TEXT 48
#define OPCODE_PAIRS ((size_t)AGC_OP_COUNT * AGC_OP_COUNT)
#define FOLDED_FLUSH 65536
/* The most labels of Profile.measure with a section of their own; later ones share OVERFLOW_LABEL. A dynamic label
   ("item #{i}") would otherwise keep one entry per value for the whole run. */
#define PROFILE_SECTIONS 4096
#define OVERFLOW_LABEL "[overflow]"
#define NO_SECTION UINT32_MAX
/* The most distinct folded stacks, and the most frames they hold together (256 MiB): recursion that branches on its
   data can see a new stack of up to AGC_PROFILE_FRAMES frames on most samples. Past either limit the weight goes to one
   "[truncated]" stack. */
#define PROFILE_STACKS (1u << 20)
#define PROFILE_CODES (((size_t)256 << 20) / sizeof(uint64_t))

/* One label of Profile.measure and its counts: calls, and the steps, wall time and GC time of the outermost calls. */
typedef struct {
  const agc_string *label;
  uint64_t calls, steps, ns, gc_ms;
} section;

/* The labels in the order they were first seen, and an open-addressing index of them (slot = position + 1, 0 free).
   `overflow` is the section that the labels past PROFILE_SECTIONS share (NO_SECTION until one comes); it is not in
   the index, so a label with its text keeps a section of its own. */
struct agc_profile_sections {
  section *items;
  uint32_t count, cap;
  uint32_t *index;
  uint32_t slots;
  uint32_t overflow;
};

/* One distinct stack of the folded output: its frames (codes[at .. at + len)), their hash and the weight of the
   samples that saw it. */
typedef struct {
  uint64_t hash, weight;
  size_t at;
  uint32_t len;
} stack;

/* The stacks in the order they were first seen (so the output is the same on every run), their frames in one array,
   and an open-addressing index like the sections'. `limit` is the most stacks it keeps; `truncated` is the weight of
   the samples whose new stack did not fit. */
struct agc_profile_stacks {
  stack *items;
  uint32_t count, cap;
  uint32_t *index;
  uint32_t slots;
  uint32_t limit;
  uint64_t truncated;
  uint64_t *codes;
  size_t used, room;
};

/* A running Profile.measure. With the profile on, `section` is its label's and the call is linked into its task's
   list of measures (`outer` is the enclosing one), whose `frame` is the native frame that runs it; `counted` is set
   when no enclosing measure of the task has the same label, and only then do its steps, time and GC time count, so a
   recursive label is counted once. The other fields are the task's counts when it began. */
typedef struct agc_measure {
  agc_stepper stepper;
  agc_value label;
  struct agc_measure *outer;
  uint32_t frame, section;
  bool called, counted;
  uint64_t steps, ns, gc_ms;
} measure;

/* A growing line buffer for the folded output, written out in pieces. */
typedef struct {
  char *data;
  size_t len, room;
  int fd;
} out_buffer;

/* The name of each opcode in the order of agc_opcode (vm/value.h), spelled as OPCODES in
   compiler/bytecode/bytecode_tables.agc and --dump-ir spell it; tests/test_frontend_bytecode.py checks the list. */
static const char *const opcode_names[] = {
  "move", "const", "step", "add-i", "sub-i", "mul-i", "div-i", "mod-i", "neg-i", "not", "lt-i", "le-i", "eq", "ne",
  "jump", "jump-if-false", "jump-if-true", "call", "call-builtin", "return", "add-f", "sub-f", "mul-f", "div-f",
  "neg-f", "lt-f", "le-f", "concat", "to-text", "inspect", "list", "list-len", "list-get", "struct", "field", "enum",
  "is-variant", "payload", "same", "tail-call", "try", "is-ok", "result-value", "map", "map-get", "call-value",
  "closure", "range", "range-bounds", "struct-with", "global", "global-set", "try-step",
};
_Static_assert(sizeof opcode_names / sizeof opcode_names[0] == AGC_OP_COUNT, "one name for each opcode");
/* report_loop ranks the pairs in the AGC_OP_COUNT slots it ranks the opcodes in. */
_Static_assert(PROFILE_PAIRS <= AGC_OP_COUNT, "the top pairs fit the opcode ranking");

static uint64_t hash_bytes(uint64_t h, const void *data, size_t n) {
  const unsigned char *p = data;
  for (size_t k = 0; k < n; k++) h = (h ^ p[k]) * 0x100000001b3ULL;
  return h;
}

static uint64_t gc_ms_now(void) {
  agc_gc_info gc = {0};
  agc_gc_stats(&gc);
  return gc.total_ms;
}

/* A new index of SLOTS slots (a power of two) for COUNT entries whose hashes HASH_OF gives. */
static uint32_t *build_index(uint32_t slots, uint32_t count, uint64_t (*hash_of)(const void *, uint32_t),
                             const void *items) {
  uint32_t *index = agc_alloc_atomic(agc_size_mul(slots, sizeof *index));
  memset(index, 0, (size_t)slots * sizeof *index);
  for (uint32_t k = 0; k < count; k++) {
    uint32_t at = (uint32_t)hash_of(items, k) & (slots - 1);
    while (index[at]) at = (at + 1) & (slots - 1);
    index[at] = k + 1;
  }
  return index;
}

static uint64_t label_hash(const agc_string *label) {
  return hash_bytes(0xcbf29ce484222325ULL, label->data, label->bytes);
}

static uint64_t section_hash(const void *items, uint32_t k) { return label_hash(((const section *)items)[k].label); }

static uint64_t stack_hash(const void *items, uint32_t k) { return ((const stack *)items)[k].hash; }

/* ITEMS of COUNT entries of SIZE bytes, copied to twice the room when they fill *CAP; ATOMIC when they hold no
   pointer. */
static void *room_for_one(void *items, uint32_t count, uint32_t *cap, size_t size, bool atomic) {
  if (count < *cap) return items;
  size_t bytes = agc_size_mul((size_t)*cap * 2, size);
  void *bigger = atomic ? agc_alloc_atomic(bytes) : agc_alloc(bytes);
  memcpy(bigger, items, (size_t)count * size);
  *cap *= 2;
  return bigger;
}

/* Puts entry COUNT - 1, just added, in free slot AT of INDEX, or rebuilds the index twice as large once it is half
   full. Returns the index. */
static uint32_t *index_add(uint32_t *index, uint32_t *slots, uint32_t at, uint32_t count,
                           uint64_t (*hash_of)(const void *, uint32_t), const void *items) {
  if ((uint64_t)count * 2 <= *slots) {
    index[at] = count;
    return index;
  }
  *slots *= 2;
  return build_index(*slots, count, hash_of, items);
}

/* The section that the labels past PROFILE_SECTIONS share, made on first use. */
static uint32_t overflow_section(struct agc_profile_sections *s) {
  if (s->overflow == NO_SECTION) {
    s->items = room_for_one(s->items, s->count, &s->cap, sizeof *s->items, false);
    s->overflow = s->count++;
    s->items[s->overflow] = (section){.label = agc_make_string(OVERFLOW_LABEL, strlen(OVERFLOW_LABEL),
                                                               strlen(OVERFLOW_LABEL))};
  }
  return s->overflow;
}

/* The section of LABEL, made on first use while there are fewer than PROFILE_SECTIONS. */
static uint32_t section_of(agc_profile *profile, const agc_string *label) {
  struct agc_profile_sections *s = profile->sections;
  uint64_t h = label_hash(label);
  uint32_t at = (uint32_t)h & (s->slots - 1);
  for (; s->index[at]; at = (at + 1) & (s->slots - 1)) {
    const agc_string *seen = s->items[s->index[at] - 1].label;
    if (seen->bytes == label->bytes && memcmp(seen->data, label->data, label->bytes) == 0) return s->index[at] - 1;
  }
  if (s->count >= PROFILE_SECTIONS) return overflow_section(s);
  s->items = room_for_one(s->items, s->count, &s->cap, sizeof *s->items, false);
  uint32_t id = s->count++;
  s->items[id] = (section){.label = label};
  s->index = index_add(s->index, &s->slots, at, s->count, section_hash, s->items);
  return id;
}

/* Adds WEIGHT to the stack of N frames CODES, outermost first, recording the stack the first time it is seen, or to
   the truncated weight when a new stack does not fit in the limits. */
void agc_profile_add_stack(agc_profile *profile, const uint64_t *codes, uint32_t n, uint64_t weight) {
  struct agc_profile_stacks *s = profile->stacks;
  uint64_t h = hash_bytes(0xcbf29ce484222325ULL, codes, (size_t)n * sizeof *codes);
  uint32_t at = (uint32_t)h & (s->slots - 1);
  for (; s->index[at]; at = (at + 1) & (s->slots - 1)) {
    stack *seen = &s->items[s->index[at] - 1];
    if (seen->hash == h && seen->len == n && memcmp(s->codes + seen->at, codes, (size_t)n * sizeof *codes) == 0) {
      seen->weight += weight;
      return;
    }
  }
  if (s->count >= s->limit || n > PROFILE_CODES - s->used) {
    s->truncated += weight;
    return;
  }
  if (s->room - s->used < n) {
    size_t room = agc_size_mul(agc_size_add(s->room, n), 2);
    uint64_t *bigger = agc_alloc_atomic(agc_size_mul(room, sizeof *bigger));
    memcpy(bigger, s->codes, s->used * sizeof *bigger);
    s->codes = bigger;
    s->room = room;
  }
  memcpy(s->codes + s->used, codes, (size_t)n * sizeof *codes);
  s->items = room_for_one(s->items, s->count, &s->cap, sizeof *s->items, true);
  uint32_t id = s->count++;
  s->items[id] = (stack){.hash = h, .weight = weight, .at = s->used, .len = n};
  s->used += n;
  s->index = index_add(s->index, &s->slots, at, s->count, stack_hash, s->items);
}

/* The start of a counted call: its section, its place in the task's list, and whether an enclosing call of the same
   label already counts. Entries whose frame has ended (a runtime error or a cancel left no exit) are dropped first:
   frames are a stack, so once the innermost entry is live, every entry under it is too. */
static void measure_enter(agc_vm *vm, measure *m) {
  agc_task *t = vm->task;
  agc_profile *profile = vm->profile;
  m->section = section_of(profile, agc_as_string(vm, m->label));
  m->frame = t->frame_count - 1;
  profile->sections->items[m->section].calls++;
  while (t->measures && !agc_frame_runs(t, t->measures->frame, &t->measures->stepper)) t->measures = t->measures->outer;
  m->counted = true;
  for (const measure *o = t->measures; o; o = o->outer)
    if (o->section == m->section) m->counted = false;
  m->outer = t->measures;
  t->measures = m;
  if (!m->counted) return;
  m->steps = agc_task_steps(vm);
  m->ns = agc_trace_now();
  m->gc_ms = gc_ms_now();
}

static void measure_exit(agc_vm *vm, measure *m) {
  agc_task *t = vm->task;
  if (t->measures == m) t->measures = m->outer;
  if (!m->counted) return;
  section *s = &vm->profile->sections->items[m->section];
  s->steps += agc_task_steps(vm) - m->steps;
  s->ns += agc_trace_now() - m->ns;
  s->gc_ms += gc_ms_now() - m->gc_ms;
}

/* The first step calls the block with no argument; the second ends the call with what the block returned, a Result
   from a `try` included. */
agc_step agc_profile_measure_step(agc_vm *vm, agc_stepper *self, agc_value last) {
  measure *m = (measure *)self;
  if (!m->called) {
    m->called = true;
    measure_enter(vm, m);
    return (agc_step){.kind = AGC_STEP_CALL0, .fn = agc_void()};
  }
  measure_exit(vm, m);
  return (agc_step){.kind = AGC_STEP_END, .value = last};
}

uint32_t agc_profile_measure_label(const agc_stepper *stepper) { return ((const measure *)stepper)->section; }

/* Profile.measure(label, block). With the profile off it only has the block called in its place. With it on it is a
   stepper, whose native frame stands for the label in a folded stack; the step touches only the task and the profile,
   which runs on one scheduler, so it needs no lock. Both ways count the same one step for the call of the block. */
static agc_value builtin_measure(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_as_string(vm, args[0]);
  if (!AGC_PROFILE_ON(vm)) {
    agc_task_call_block(vm);
    return agc_void();
  }
  measure *m = agc_alloc(sizeof *m);
  m->stepper.step = agc_profile_measure_step;
  m->stepper.unlocked = true;
  m->label = args[0];
  agc_task_stepper(vm, &m->stepper);
  return agc_void();
}

static agc_value builtin_steps(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  uint64_t steps = agc_task_steps(vm);
  return agc_int(steps > (uint64_t)INT64_MAX ? INT64_MAX : (int64_t)steps);
}

const agc_builtin agc_profile_builtins[] = {
  {"Profile.measure", 2, builtin_measure, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Profile.steps", 0, builtin_steps, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
};

const size_t agc_profile_builtin_count = sizeof agc_profile_builtins / sizeof agc_profile_builtins[0];

/* Whether entry A comes before entry B: a larger count, then a larger THEN (when given). */
static bool ranks_before(const uint64_t *counts, const uint64_t *then, size_t a, size_t b) {
  if (counts[a] != counts[b]) return counts[a] > counts[b];
  return then && then[a] > then[b];
}

/* The indexes of the `limit` (the room of TOP) entries with the largest counts, ranked by COUNTS and then by THEN
 * (NULL: counts alone), the lower index first among equal ones; entries whose keys are all zero are left out. Returns
 * how many there are. */
static size_t top_counts(const uint64_t *counts, const uint64_t *then, size_t n, uint32_t *top, size_t limit) {
  size_t found = 0;
  for (size_t k = 0; k < n; k++) {
    if (counts[k] == 0 && (!then || then[k] == 0)) continue;
    size_t at = found;
    while (at > 0 && ranks_before(counts, then, k, top[at - 1])) at--;
    if (at >= limit) continue;
    if (found < limit) found++;
    memmove(top + at + 1, top + at, (found - at - 1) * sizeof *top);
    top[at] = (uint32_t)k;
  }
  return found;
}

static uint64_t sum_counts(const uint64_t *counts, size_t n) {
  uint64_t sum = 0;
  for (size_t k = 0; k < n; k++) sum += counts[k];
  return sum;
}

/* Starts the counters of the run when the profile category is on. Called before the first task enters a function. */
void agc_profile_start(agc_vm *vm) {
  const agc_trace *tr = &vm->rt->trace;
  if (!AGC_TRACE_ON(tr, AGC_TRACE_PROFILE)) return;
  const agc_program *p = vm->rt->program;
  agc_profile *profile = agc_alloc(sizeof *profile);
  profile->functions = p->function_count;
  profile->builtins = p->builtin_count;
  profile->calls = agc_alloc(agc_size_mul((size_t)p->function_count + 1, sizeof(uint64_t)));
  profile->steps = agc_alloc(agc_size_mul((size_t)p->function_count + 1, sizeof(uint64_t)));
  profile->builtin_calls = agc_alloc(agc_size_mul((size_t)p->builtin_count + 1, sizeof(uint64_t)));
  profile->builtin_ns = agc_alloc(agc_size_mul((size_t)p->builtin_count + 1, sizeof(uint64_t)));
  profile->ops = agc_alloc_atomic(AGC_OP_COUNT * sizeof(uint64_t));
  memset(profile->ops, 0, AGC_OP_COUNT * sizeof(uint64_t));
  profile->pairs = agc_alloc_atomic(OPCODE_PAIRS * sizeof(uint64_t));
  memset(profile->pairs, 0, OPCODE_PAIRS * sizeof(uint64_t));
  struct agc_profile_sections *sections = agc_alloc(sizeof *sections);
  sections->cap = 8;
  sections->items = agc_alloc(sections->cap * sizeof *sections->items);
  sections->slots = 16;
  sections->index = build_index(sections->slots, 0, section_hash, NULL);
  sections->overflow = NO_SECTION;
  profile->sections = sections;
  profile->every = profile->left = tr->profile_every;
  if (profile->every) {
    struct agc_profile_stacks *stacks = agc_alloc(sizeof *stacks);
    stacks->cap = 64;
    stacks->items = agc_alloc_atomic(stacks->cap * sizeof *stacks->items);
    stacks->slots = 128;
    stacks->index = build_index(stacks->slots, 0, stack_hash, NULL);
    stacks->limit = tr->profile_stacks && tr->profile_stacks < PROFILE_STACKS ? tr->profile_stacks : PROFILE_STACKS;
    stacks->room = 1024;
    stacks->codes = agc_alloc_atomic(stacks->room * sizeof *stacks->codes);
    profile->stacks = stacks;
    profile->frames = agc_alloc_atomic(AGC_PROFILE_FRAMES * sizeof *profile->frames);
  }
  profile->start_ns = agc_trace_now();
  agc_gc_measure();
  vm->profile = profile;
}

/* The steps and calls of the functions defined in each source file, in the order of the program's sources. */
static void sum_by_file(const agc_program *p, const agc_profile *profile, uint64_t *steps, uint64_t *calls) {
  for (uint32_t id = 0; id < profile->functions; id++) {
    uint32_t file = p->spans[p->functions[id].span].source;
    steps[file] += profile->steps[id];
    calls[file] += profile->calls[id];
  }
}

/* The sections with the most steps, then the most calls (a recursive or failed call leaves its steps at 0), with
   their counts. */
static void report_sections(const agc_trace *tr, const struct agc_profile_sections *s) {
  uint64_t *steps = agc_alloc_atomic(agc_size_mul((size_t)s->count + 1, sizeof *steps));
  uint64_t *calls = agc_alloc_atomic(agc_size_mul((size_t)s->count + 1, sizeof *calls));
  for (uint32_t k = 0; k < s->count; k++) {
    steps[k] = s->items[k].steps;
    calls[k] = s->items[k].calls;
  }
  uint32_t top[PROFILE_TOP];
  size_t found = top_counts(steps, calls, s->count, top, PROFILE_TOP);
  for (size_t k = 0; k < found; k++) {
    const section *it = &s->items[top[k]];
    AGC_TRACE(tr, AGC_TRACE_PROFILE,
              "section calls=%" PRIu64 " steps=%" PRIu64 " us=%" PRIu64 " gc_ms=%" PRIu64 " name=%.*s", it->calls,
              it->steps, it->ns / 1000u, it->gc_ms, agc_trace_len(it->label->bytes), it->label->data);
  }
}

/* COUNT as a share of TOTAL in percent with two decimals ("12.34"), written in TEXT. */
static const char *share_of(uint64_t count, uint64_t total, char text[SHARE_TEXT]) {
  uint64_t hundredths = total ? (uint64_t)((double)count * 10000.0 / (double)total + 0.5) : 0;
  snprintf(text, SHARE_TEXT, "%" PRIu64 ".%02" PRIu64, hundredths / 100u, hundredths % 100u);
  return text;
}

/* What the turn loop did: one `events` line (instructions, frame reloads and the paths of CALL_BUILTIN), every opcode
   that ran with its share of the instructions, the most first, and the PROFILE_PAIRS pairs of opcodes run one after
   the other in a frame with their share of all pairs. */
static void report_loop(const agc_trace *tr, const agc_profile *profile) {
  uint64_t instructions = sum_counts(profile->ops, AGC_OP_COUNT), pairs = sum_counts(profile->pairs, OPCODE_PAIRS);
  AGC_TRACE(tr, AGC_TRACE_PROFILE,
            "events instructions=%" PRIu64 " reloads=%" PRIu64 " builtin_leaf=%" PRIu64 " builtin_tail=%" PRIu64
            " builtin_native=%" PRIu64,
            instructions, profile->reloads, profile->builtin_leaf, profile->builtin_tail, profile->builtin_native);
  char share[SHARE_TEXT];
  uint32_t top[AGC_OP_COUNT];
  size_t found = top_counts(profile->ops, NULL, AGC_OP_COUNT, top, AGC_OP_COUNT);
  for (size_t k = 0; k < found; k++)
    AGC_TRACE(tr, AGC_TRACE_PROFILE, "op count=%" PRIu64 " share=%s name=%s", profile->ops[top[k]],
              share_of(profile->ops[top[k]], instructions, share), opcode_names[top[k]]);
  found = top_counts(profile->pairs, NULL, OPCODE_PAIRS, top, PROFILE_PAIRS);
  for (size_t k = 0; k < found; k++)
    AGC_TRACE(tr, AGC_TRACE_PROFILE, "pair count=%" PRIu64 " share=%s first=%s then=%s", profile->pairs[top[k]],
              share_of(profile->pairs[top[k]], pairs, share), opcode_names[top[k] / AGC_OP_COUNT],
              opcode_names[top[k] % AGC_OP_COUNT]);
}

static void out_bytes(out_buffer *out, const char *s, size_t n) {
  if (out->room - out->len < n) {
    agc_trace_write(out->fd, out->data, out->len);
    out->len = 0;
    if (out->room < n) {
      out->room = n;
      out->data = agc_alloc_atomic(n);
    }
  }
  memcpy(out->data + out->len, s, n);
  out->len += n;
}

/* A name in a frame: ';' separates frames and a line ends the stack, so those and the other control bytes are written
   as %XX, and so is '%' itself, which keeps two different names apart and no stack is written twice. Spaces stay:
   the readers take the weight after the last one. Every caller writes a frame that is not empty for an empty name
   (`measure:`, `@FILE:LINE`), so an empty name stays empty. */
static void out_name(out_buffer *out, const char *s, size_t n) {
  static const char hex[] = "0123456789ABCDEF";
  for (size_t k = 0; k < n; k++) {
    unsigned char c = (unsigned char)s[k];
    if (c == ';' || c == '%' || c < 0x20 || c == 0x7f) {
      char escaped[3] = {'%', hex[c >> 4], hex[c & 15]};
      out_bytes(out, escaped, 3);
    } else {
      out_bytes(out, s + k, 1);
    }
  }
}

static void out_frame(out_buffer *out, const agc_program *p, const agc_profile *profile, uint64_t code) {
  uint32_t id = (uint32_t)code;
  switch (code >> 32) {
    case AGC_PROFILE_FUNCTION: {
      const agc_function *fn = &p->functions[id];
      out_name(out, fn->name->data, fn->name->bytes);
      if (fn->name->bytes >= 6 && memcmp(fn->name->data, "block@", 6) == 0) return;
      const agc_span *at = &p->spans[fn->span];
      const agc_string *file = p->sources[at->source].name;
      char line[16];
      int n = snprintf(line, sizeof line, ":%" PRIu32, at->start_line);
      out_bytes(out, "@", 1);
      out_name(out, file->data, file->bytes);
      out_bytes(out, line, (size_t)n);
      return;
    }
    case AGC_PROFILE_BUILTIN: {
      const char *name = id < profile->builtins && p->builtins[id] ? p->builtins[id]->name : "<native>";
      out_name(out, name, strlen(name));
      return;
    }
    case AGC_PROFILE_LABEL: {
      if (id == profile->sections->overflow) {
        out_bytes(out, "measure" OVERFLOW_LABEL, sizeof "measure" OVERFLOW_LABEL - 1);
        return;
      }
      const agc_string *label = profile->sections->items[id].label;
      out_bytes(out, "measure:", 8);
      out_name(out, label->data, label->bytes);
      return;
    }
    default: out_bytes(out, "...", 3); return;
  }
}

/* The folded stacks, one line each: the frames outermost first, separated by ';', a space and the weight in steps.
   The weight of the stacks that did not fit comes last, as the one-frame stack "[truncated]", with a warning line. */
static void report_folded(const agc_vm *vm, const agc_profile *profile) {
  const agc_program *p = vm->rt->program;
  const struct agc_profile_stacks *s = profile->stacks;
  out_buffer out = {.data = agc_alloc_atomic(FOLDED_FLUSH), .room = FOLDED_FLUSH, .fd = vm->rt->trace.fd};
  for (uint32_t k = 0; k < s->count; k++) {
    const stack *it = &s->items[k];
    for (uint32_t f = 0; f < it->len; f++) {
      if (f) out_bytes(&out, ";", 1);
      out_frame(&out, p, profile, s->codes[it->at + f]);
    }
    char weight[24];
    int n = snprintf(weight, sizeof weight, " %" PRIu64 "\n", it->weight);
    out_bytes(&out, weight, (size_t)n);
  }
  if (s->truncated) {
    char weight[40];
    int n = snprintf(weight, sizeof weight, "[truncated] %" PRIu64 "\n", s->truncated);
    out_bytes(&out, weight, (size_t)n);
  }
  agc_trace_write(out.fd, out.data, out.len);
  if (s->truncated) {
    char kept[16];
    int n = snprintf(kept, sizeof kept, "%" PRIu32, s->count);
    agc_trace_message(out.fd, "folded profile full: new stacks weigh on [truncated]; stacks kept", kept, (size_t)n,
                      false);
  }
}

/* One total line, then the functions with the most steps, the source files with the most steps, the builtins that
 * took the most time and the sections of Profile.measure, each with its counts, and last what the turn loop ran
 * (report_loop). The step that a counting loop (Range#each, Int#times, upto, downto) or a stepper builtin
 * (File.each_line) takes for each pass is the function "<native>"; List.map, each, filter and the like count no step
 * of their own, only the steps of their callbacks.
 * Builtin time is wall time of the call itself: a builtin that waits (a sleep, a read) is timed until it parks, and
 * the garbage collector runs inside the allocations of any of them. `gc_ms` and `collections` are those of the whole
 * process so far, not of this runtime: the report of the program that `agentica FILE.agc` runs counts the front
 * end's collections too.
 *
 * With folded output the run writes its stacks instead. The front end of `agentica FILE.agc` writes none once it has
 * handed a program over, so the output is the program's alone. */
void agc_profile_report(agc_vm *vm) {
  const agc_profile *profile = vm->profile;
  if (!profile) return;
  if (profile->every) {
    if (!vm->rt->front_end || !vm->rt->front_end->handed) report_folded(vm, profile);
    return;
  }
  const agc_trace *tr = &vm->rt->trace;
  const agc_program *p = vm->rt->program;
  size_t functions = (size_t)profile->functions + 1, builtins = (size_t)profile->builtins + 1;
  agc_gc_info gc = {0};
  agc_gc_stats(&gc);
  AGC_TRACE(tr, AGC_TRACE_PROFILE,
            "total wall_ms=%" PRIu64 " steps=%" PRIu64 " calls=%" PRIu64 " builtin_calls=%" PRIu64
            " builtin_ms=%" PRIu64 " gc_ms=%" PRIu64 " collections=%" PRIu64,
            (agc_trace_now() - profile->start_ns) / 1000000u, sum_counts(profile->steps, functions),
            sum_counts(profile->calls, functions), sum_counts(profile->builtin_calls, builtins),
            sum_counts(profile->builtin_ns, builtins) / 1000000u, gc.total_ms, gc.collections);
  uint32_t top[PROFILE_TOP];
  size_t found = top_counts(profile->steps, NULL, functions, top, PROFILE_TOP);
  for (size_t k = 0; k < found; k++) {
    uint32_t id = top[k];
    if (id == profile->functions) {
      AGC_TRACE(tr, AGC_TRACE_PROFILE, "fn calls=0 steps=%" PRIu64 " name=<native>", profile->steps[id]);
      continue;
    }
    const agc_function *fn = &p->functions[id];
    const agc_span *at = &p->spans[fn->span];
    const agc_string *file = p->sources[at->source].name;
    AGC_TRACE(tr, AGC_TRACE_PROFILE, "fn calls=%" PRIu64 " steps=%" PRIu64 " name=%.*s at=%.*s:%" PRIu32,
              profile->calls[id], profile->steps[id], agc_trace_len(fn->name->bytes), fn->name->data,
              agc_trace_len(file->bytes), file->data, at->start_line);
  }
  uint64_t *file_steps = agc_alloc(agc_size_mul((size_t)p->source_count + 1, sizeof(uint64_t)));
  uint64_t *file_calls = agc_alloc(agc_size_mul((size_t)p->source_count + 1, sizeof(uint64_t)));
  sum_by_file(p, profile, file_steps, file_calls);
  found = top_counts(file_steps, NULL, p->source_count, top, PROFILE_FILES);
  for (size_t k = 0; k < found; k++) {
    const agc_string *file = p->sources[top[k]].name;
    AGC_TRACE(tr, AGC_TRACE_PROFILE, "file calls=%" PRIu64 " steps=%" PRIu64 " name=%.*s", file_calls[top[k]],
              file_steps[top[k]], agc_trace_len(file->bytes), file->data);
  }
  found = top_counts(profile->builtin_ns, NULL, builtins, top, PROFILE_TOP);
  for (size_t k = 0; k < found; k++) {
    uint32_t id = top[k];
    const char *name = id < profile->builtins ? p->builtins[id]->name : "";
    AGC_TRACE(tr, AGC_TRACE_PROFILE, "builtin calls=%" PRIu64 " us=%" PRIu64 " name=%s", profile->builtin_calls[id],
              profile->builtin_ns[id] / 1000u, name);
  }
  report_sections(tr, profile->sections);
  report_loop(tr, profile);
}

/* The name of a file opcode as --dump-ir spells it, or "?" past them (the fused opcodes have none). */
const char *agc_opcode_name(uint32_t op) { return op < AGC_OP_COUNT ? opcode_names[op] : "?"; }

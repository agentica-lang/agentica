/*
 * Line coverage of a run (`agentica --coverage PATH FILE.agc`): a counter for each span of the program, to which
 * step_slow (vm/interp.c) adds one for each span of a STEP that runs, and the LCOV text of the counts, which the driver
 * writes at the end of the run (vm/launch.c). A STEP stands for the statements and expressions that the front end
 * marked with a step, so the lines that start one of its spans are the lines that can be covered. The counters are
 * atomic: every scheduler adds to them, and the end reads them once the schedulers are joined.
 * Core layer.
 */
#include "core.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

/* The counters, one for each span of the program. */
struct agc_cover {
  uint32_t spans;
  _Atomic uint64_t *hits;
};

/* What is being written: the sink, and for each source the highest count of each of its lines (index 0 unused), or
   UINT64_MAX for a line that starts no span of a STEP. */
typedef struct {
  agc_cover_emit emit;
  void *context;
  uint64_t **lines;
} writer;

agc_cover *agc_cover_new(const agc_program *program) {
  agc_cover *cover = agc_alloc(sizeof *cover);
  size_t size = agc_size_mul(program->span_count ? program->span_count : 1, sizeof *cover->hits);
  cover->hits = agc_alloc_atomic(size);
  memset((void *)cover->hits, 0, size);
  cover->spans = program->span_count;
  return cover;
}

void agc_cover_hit(agc_cover *cover, uint32_t span, int64_t n) {
  for (int64_t k = 0; k < n && (uint64_t)span + (uint64_t)k < cover->spans; k++)
    atomic_fetch_add_explicit(&cover->hits[span + (uint32_t)k], 1, memory_order_relaxed);
}

/* A STEP, alone or fused with the instruction after it (the loader's fuse_steps); its `a` is the number of spans. */
static bool is_step(uint16_t op) {
  return op == AGC_OP_STEP || (op >= AGC_OP_COUNT && op <= AGC_FUSED_STEP_CONST_NE);
}

static bool starts_with(const agc_string *text, const char *prefix) {
  size_t size = strlen(prefix);
  return text->bytes >= size && memcmp(text->data, prefix, size) == 0;
}

/* The files that are not the program's own: std/, the prelude and fetched packages (`pkg/NAME@VERSION/...`). A
   package that the project reads in place, a workspace member (`pkg/NAME@workspace/`) or a path dependency
   (`pkg/NAME@path/`), is the project's code, so it is counted. */
static bool left_out(const agc_string *name) {
  if (starts_with(name, "std/") || starts_with(name, "<prelude>/")) return true;
  if (!starts_with(name, "pkg/")) return false;
  const char *label = name->data + 4;
  const char *end = memchr(label, '/', name->bytes - 4);
  size_t size = end ? (size_t)(end - label) : name->bytes - 4;
  static const char *const in_place[] = {"@workspace", "@path"};
  for (size_t k = 0; k < sizeof in_place / sizeof in_place[0]; k++) {
    size_t tail = strlen(in_place[k]);
    if (size > tail && memcmp(label + size - tail, in_place[k], tail) == 0) return false;
  }
  return true;
}

static void put(writer *w, const char *text, size_t size) { w->emit(w->context, text, size); }

/* The name of F as its source writes it: without the `@N::` that the front end puts before a function of an imported
   module, so that two modules' functions of one name stay apart. */
static void put_name(writer *w, const agc_string *name) {
  size_t at = 0;
  if (name->bytes > 1 && name->data[0] == '@') {
    size_t digits = 1;
    while (digits < name->bytes && name->data[digits] >= '0' && name->data[digits] <= '9') digits++;
    if (digits > 1 && digits + 2 < name->bytes && memcmp(name->data + digits, "::", 2) == 0) at = digits + 2;
  }
  put(w, name->data + at, name->bytes - at);
}

static void put_text(writer *w, const char *text) { put(w, text, strlen(text)); }

/* A field such as `FNF:4` or `FN:12,name`: the key, the number, then `,` and the function's name, if any, and the
   line feed. */
static void put_field(writer *w, const char *key, uint64_t number, const agc_string *name) {
  char text[48];
  int size = snprintf(text, sizeof text, "%s:%" PRIu64, key, number);
  put(w, text, (size_t)size);
  if (name) {
    put(w, ",", 1);
    put_name(w, name);
  }
  put(w, "\n", 1);
}

static void put_count(writer *w, const char *key, uint64_t count, uint64_t number) {
  char text[64];
  int size = snprintf(text, sizeof text, "%s:%" PRIu64 ",%" PRIu64 "\n", key, count, number);
  put(w, text, (size_t)size);
}

/* The count of the first STEP of F, which runs on each call, or false when F does not start with a STEP (a function
   of at most two instructions that calls nothing may not, and it has no line to cover either). */
static bool calls_of(const agc_cover *cover, const agc_function *f, uint64_t *calls) {
  if (f->count == 0 || !is_step(f->code[0].op) || f->spans[0] >= cover->spans) return false;
  *calls = atomic_load_explicit(&cover->hits[f->spans[0]], memory_order_relaxed);
  return true;
}

/* The functions of SOURCE that LCOV lists: the program's own, but not the entry (`<start>`), which is no function of
   the source. */
static bool listed(const agc_program *p, const agc_function *f, uint32_t source) {
  if (f->prelude || f->span >= p->span_count || p->spans[f->span].source != source) return false;
  return !(f->name->bytes == 7 && memcmp(f->name->data, "<start>", 7) == 0);
}

/* The record of one source: its functions (FN, FNDA, FNF, FNH), then its lines (DA, LF, LH). */
static void put_source(writer *w, const agc_cover *cover, const agc_program *p, uint32_t source) {
  const agc_source *s = &p->sources[source];
  put_text(w, "SF:");
  put(w, s->name->data, s->name->bytes);
  put(w, "\n", 1);
  uint64_t found = 0, hit = 0, calls = 0;
  for (uint32_t k = 0; k < p->function_count; k++) {
    const agc_function *f = &p->functions[k];
    if (!listed(p, f, source) || !calls_of(cover, f, &calls)) continue;
    put_field(w, "FN", p->spans[f->span].start_line, f->name);
  }
  for (uint32_t k = 0; k < p->function_count; k++) {
    const agc_function *f = &p->functions[k];
    if (!listed(p, f, source) || !calls_of(cover, f, &calls)) continue;
    put_field(w, "FNDA", calls, f->name);
    found++;
    if (calls) hit++;
  }
  put_field(w, "FNF", found, NULL);
  put_field(w, "FNH", hit, NULL);
  found = hit = 0;
  for (uint32_t line = 1; line <= s->lines; line++) {
    uint64_t count = w->lines[source][line];
    if (count == UINT64_MAX) continue;
    put_count(w, "DA", line, count);
    found++;
    if (count) hit++;
  }
  put_field(w, "LF", found, NULL);
  put_field(w, "LH", hit, NULL);
  put_text(w, "end_of_record\n");
}

/* For each source the program counts, the highest count of each line that starts a span of a STEP. A line past the
   end of its source (no such span comes from the front end) is not counted. */
static void count_lines(writer *w, const agc_cover *cover, const agc_program *p) {
  for (uint32_t k = 0; k < p->function_count; k++) {
    const agc_function *f = &p->functions[k];
    if (f->prelude) continue;
    for (uint32_t pc = 0; pc < f->count; pc++) {
      if (!is_step(f->code[pc].op)) continue;
      for (uint32_t n = 0; n < f->code[pc].a; n++) {
        uint64_t at = (uint64_t)f->spans[pc] + n;
        if (at >= cover->spans) break;
        const agc_span *span = &p->spans[at];
        uint64_t *lines = span->source < p->source_count ? w->lines[span->source] : NULL;
        if (!lines || span->start_line == 0 || span->start_line > p->sources[span->source].lines) continue;
        uint64_t count = atomic_load_explicit(&cover->hits[at], memory_order_relaxed);
        uint64_t *best = &lines[span->start_line];
        if (*best == UINT64_MAX || count > *best) *best = count;
      }
    }
  }
}

void agc_cover_lcov(const agc_cover *cover, const agc_program *p, agc_cover_emit emit, void *context) {
  writer w = {emit, context, agc_alloc(agc_size_mul((size_t)p->source_count + 1, sizeof(uint64_t *)))};
  for (uint32_t k = 0; k < p->source_count; k++) {
    if (left_out(p->sources[k].name)) {
      w.lines[k] = NULL;
      continue;
    }
    size_t size = agc_size_mul((size_t)p->sources[k].lines + 1, sizeof(uint64_t));
    w.lines[k] = agc_alloc_atomic(size);
    memset(w.lines[k], 0xff, size);
  }
  count_lines(&w, cover, p);
  for (uint32_t k = 0; k < p->source_count; k++)
    if (w.lines[k]) put_source(&w, cover, p, k);
}

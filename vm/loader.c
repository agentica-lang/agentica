/*
 * The loader: full validation of an untrusted .agcb file before any of its
 * code runs, section by section (constants, struct and enum tables, Types,
 * struct updates, Globals, code). Core layer. Design:
 * docs/vm/08-loader-and-cli.md §8.
 */
#include "core.h"

#include <inttypes.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#ifndef AGC_VERSION
#error "AGC_VERSION must be defined"
#endif

/* Total bytes that the root may add to the source names. The loader's own budget covers the names as stored; a long
 * root repeated over thousands of sources is not in it, so it gets its own cap. */
#define SOURCE_ROOT_BUDGET ((size_t)1 << 26)

typedef struct {
  const uint8_t *data;
  size_t len, pos;
  uint64_t budget;
  uint32_t format;
  bool any_version;
  const agc_trace *trace;
  uint64_t start;
  char *error;
  size_t error_size;
  jmp_buf fail;
} reader;

static uint64_t elapsed_us(uint64_t start) {
  uint64_t now = agc_trace_now();
  return now > start ? (now - start) / 1000u : 0;
}

static void trace_reject(const reader *r) {
  AGC_TRACE(r->trace, AGC_TRACE_LOADER, "reject reason=%.*s pos=%zu us=%" PRIu64,
            agc_trace_len(strnlen(r->error, r->error_size)), r->error, r->pos, elapsed_us(r->start));
}

static _Noreturn void reject(reader *r, const char *format, ...) {
  va_list args;
  va_start(args, format);
  vsnprintf(r->error, r->error_size, format, args);
  va_end(args);
  trace_reject(r);
  longjmp(r->fail, 1);
}

static size_t left(const reader *r) { return r->len - r->pos; }

static inline const uint8_t *take(reader *r, size_t n) {
  if (n > left(r)) reject(r, "truncated file");
  const uint8_t *p = r->data + r->pos;
  r->pos += n;
  return p;
}

/* A little-endian field at p. The caller has taken the bytes, so there is no bounds check here; the loops that read
 * a whole table of fixed-size entries take each entry (or the whole table) once and decode it with these. */
static inline uint16_t get_u16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

static inline uint32_t get_u32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void *load_alloc(reader *r, size_t size, bool atomic) {
  if (size == 0) return NULL;
  if (size > r->budget) reject(r, "file needs too much memory");
  r->budget -= size;
  return atomic ? agc_alloc_atomic(size) : agc_alloc(size);
}

static uint8_t read_u8(reader *r) { return *take(r, 1); }

static inline uint32_t read_u32(reader *r) { return get_u32(take(r, 4)); }

static uint64_t read_u64(reader *r) {
  uint64_t lo = read_u32(r);
  uint64_t hi = read_u32(r);
  return lo | (hi << 32);
}

static uint32_t read_count(reader *r, size_t min_entry, const char *what) {
  uint32_t count = read_u32(r);
  if ((uint64_t)count * min_entry > left(r)) reject(r, "%s count exceeds the file", what);
  return count;
}

static agc_string *read_string(reader *r) {
  uint32_t len = read_u32(r);
  const uint8_t *bytes = take(r, len);
  size_t chars;
  if (!agc_utf8_chars(bytes, len, &chars)) reject(r, "invalid UTF-8 text");
  agc_string *s = load_alloc(r, agc_size_add(sizeof(agc_string), len), true);
  s->bytes = len;
  s->chars = chars;
  if (len) memcpy(s->data, bytes, len);
  return s;
}

static bool same_text(const agc_string *s, const char *text) {
  size_t n = strlen(text);
  return s->bytes == n && memcmp(s->data, text, n) == 0;
}

/* The number of '\n' bytes in s, eight at a time: the exact zero-byte test sets 0x80 in the bytes of w ^ 0x0A0A.. that
 * are zero, which are the newlines of w, and the multiplication adds those eight flags in its top byte. */
static size_t count_newlines(const uint8_t *s, size_t len) {
  const uint64_t low = UINT64_C(0x7F7F7F7F7F7F7F7F), ones = UINT64_C(0x0101010101010101);
  size_t count = 0, i = 0;
  for (; len - i >= 8; i += 8) {
    uint64_t w;
    memcpy(&w, s + i, sizeof w);
    w ^= ones * '\n';
    uint64_t zero_bytes = ~(((w & low) + low) | w | low);
    count += (size_t)(((zero_bytes >> 7) * ones) >> 56);
  }
  for (; i < len; i++) count += s[i] == '\n';
  return count;
}

/* Where each line starts and how many characters it has, for the checks of the spans and for the diagnostics. The text
 * is valid UTF-8 (read_string), so the characters of a line are its bytes less its continuation bytes; when the text
 * is all ASCII (chars equals bytes), they are its bytes. */
static void index_lines(reader *r, agc_source *source) {
  const uint8_t *text = (const uint8_t *)source->text->data;
  const uint8_t *end = text + source->text->bytes;
  bool ascii = source->text->chars == source->text->bytes;
  size_t lines = 1 + count_newlines(text, source->text->bytes);
  source->lines = (uint32_t)lines;
  source->line_start = load_alloc(r, agc_size_mul(lines, sizeof(uint32_t)), true);
  source->line_chars = load_alloc(r, agc_size_mul(lines, sizeof(uint32_t)), true);
  size_t line = 0;
  const uint8_t *start = text;
  source->line_start[0] = 0;
  for (const uint8_t *at; (at = memchr(start, '\n', (size_t)(end - start))); start = at + 1) {
    source->line_chars[line] = (uint32_t)(ascii ? (size_t)(at - start) : agc_utf8_count(start, (size_t)(at - start)));
    line++;
    source->line_start[line] = (uint32_t)(at + 1 - text);
  }
  source->line_chars[line] = (uint32_t)(ascii ? (size_t)(end - start) : agc_utf8_count(start, (size_t)(end - start)));
}

static void check_position(reader *r, const agc_source *source, uint32_t line, uint32_t column) {
  if (line < 1 || line > source->lines) reject(r, "span line out of range");
  if (column < 1 || (uint64_t)column > (uint64_t)source->line_chars[line - 1] + 1)
    reject(r, "span column out of range");
}

static void check_register(reader *r, uint32_t reg, const agc_function *f) {
  if (reg >= f->registers) reject(r, "register out of range");
}

static void check_window(reader *r, uint32_t start, uint32_t size, const agc_function *f) {
  check_register(r, start, f);
  if ((uint64_t)start + size > f->registers) reject(r, "register range out of range");
}

static void check_spans(reader *r, const agc_program *p, uint32_t first, uint32_t count) {
  if ((uint64_t)first + count > p->span_count) reject(r, "span index out of range");
}

static bool calls_anything(const agc_function *f) {
  for (uint32_t pc = 0; pc < f->count; pc++)
    if (f->code[pc].op == AGC_OP_CALL || f->code[pc].op == AGC_OP_TAIL_CALL || f->code[pc].op == AGC_OP_CALL_BUILTIN ||
        f->code[pc].op == AGC_OP_CALL_VALUE)
      return true;
  return false;
}

/* A file with Globals slots lets only the entry function write them (check_function), and the writes are
   safe because the entry runs once, first, on the main task. A call, tail call or closure of the entry would
   run it again, possibly after main started and other tasks read the slots, so it is rejected. With no slots
   the entry is plain main, which a program may call. */
static void check_not_entry(reader *r, const agc_program *p, uint32_t target) {
  if (p->global_count && target == p->entry) reject(r, "call or closure of the entry function of a file with globals");
}

static void check_function(reader *r, const agc_program *p, const agc_function *f) {
  bool sets_global = false, jumps_back = false;
  uint16_t last = f->code[f->count - 1].op;
  if (last != AGC_OP_RETURN && last != AGC_OP_JUMP) reject(r, "function does not end with RETURN or JUMP");
  if (f->code[0].op != AGC_OP_STEP && (f->count > 2 || calls_anything(f)))
    reject(r, "function does not start with STEP");
  for (uint32_t pc = 0; pc < f->count; pc++) {
    agc_instr in = f->code[pc];
    uint32_t bx = (uint32_t)in.b | ((uint32_t)in.c << 16);
    uint32_t span = f->spans[pc];
    check_spans(r, p, span, 1);
    switch (in.op) {
      case AGC_OP_MOVE:
      case AGC_OP_NEG_I:
      case AGC_OP_NEG_F:
      case AGC_OP_NOT:
      case AGC_OP_TO_TEXT:
      case AGC_OP_INSPECT:
      case AGC_OP_LIST_LEN:
      case AGC_OP_TRY:
      case AGC_OP_TRY_STEP:
      case AGC_OP_IS_OK:
      case AGC_OP_RESULT_VALUE:
        check_register(r, in.a, f);
        check_register(r, in.b, f);
        break;
      case AGC_OP_FIELD:
        check_register(r, in.a, f);
        check_register(r, in.b, f);
        if (in.c >= p->max_fields) reject(r, "field index out of range");
        break;
      case AGC_OP_PAYLOAD:
        check_register(r, in.a, f);
        check_register(r, in.b, f);
        if (in.c >= p->max_arity) reject(r, "payload index out of range");
        break;
      case AGC_OP_IS_VARIANT:
        check_register(r, in.a, f);
        check_register(r, in.b, f);
        if (in.c >= p->variant_count) reject(r, "variant index out of range");
        break;
      case AGC_OP_STRUCT:
        check_register(r, in.a, f);
        if (in.c >= p->struct_count) reject(r, "struct index out of range");
        check_window(r, in.b, p->structs[in.c].count, f);
        break;
      case AGC_OP_ENUM:
        check_register(r, in.a, f);
        if (in.c >= p->variant_count) reject(r, "variant index out of range");
        check_window(r, in.b, p->variants[in.c].arity, f);
        break;
      case AGC_OP_STRUCT_WITH:
        check_register(r, in.a, f);
        if (in.c >= p->update_count) reject(r, "struct update index out of range");
        check_window(r, in.b, 1 + p->updates[in.c].count, f);
        break;
      case AGC_OP_CONST:
        check_register(r, in.a, f);
        if (bx >= p->constant_count) reject(r, "constant index out of range");
        break;
      case AGC_OP_GLOBAL:
      case AGC_OP_GLOBAL_SET:
        check_register(r, in.a, f);
        if (bx >= p->global_count) reject(r, "global index out of range");
        if (in.op == AGC_OP_GLOBAL_SET) {
          if (f != &p->functions[p->entry]) reject(r, "GLOBAL_SET outside the entry function");
          sets_global = true;
        }
        break;
      case AGC_OP_STEP:
        if (in.a < 1) reject(r, "STEP count is zero");
        check_spans(r, p, span, in.a);
        break;
      case AGC_OP_ADD_I:
      case AGC_OP_SUB_I:
      case AGC_OP_MUL_I:
      case AGC_OP_DIV_I:
      case AGC_OP_MOD_I:
      case AGC_OP_LT_I:
      case AGC_OP_LE_I:
      case AGC_OP_EQ:
      case AGC_OP_NE:
      case AGC_OP_ADD_F:
      case AGC_OP_SUB_F:
      case AGC_OP_MUL_F:
      case AGC_OP_DIV_F:
      case AGC_OP_LT_F:
      case AGC_OP_LE_F:
      case AGC_OP_CONCAT:
      case AGC_OP_LIST_GET:
      case AGC_OP_MAP_GET:
      case AGC_OP_SAME:
        check_register(r, in.a, f);
        check_register(r, in.b, f);
        check_register(r, in.c, f);
        break;
      case AGC_OP_LIST:
        check_register(r, in.a, f);
        check_window(r, in.b, in.c, f);
        break;
      case AGC_OP_MAP:
        check_register(r, in.a, f);
        if (in.c > AGC_MAX_MAP_CHUNK) reject(r, "map literal chunk too large");
        check_window(r, in.b, 2 * (uint32_t)in.c, f);
        break;
      case AGC_OP_JUMP_IF_FALSE:
      case AGC_OP_JUMP_IF_TRUE:
        check_register(r, in.a, f);
        /* fall through */
      case AGC_OP_JUMP:
        if (bx >= f->count) reject(r, "jump target out of range");
        if (bx <= pc && f->code[bx].op != AGC_OP_STEP) reject(r, "backward jump does not target a STEP");
        if (bx <= pc) jumps_back = true;
        break;
      case AGC_OP_CALL:
      case AGC_OP_TAIL_CALL:
        if (bx >= p->function_count) reject(r, "function index out of range");
        check_not_entry(r, p, bx);
        if (p->functions[bx].captures) reject(r, "direct call to a function with captures");
        check_window(r, in.a, p->functions[bx].params, f);
        /* A call of a prelude function carries the span of each argument after its own (like CALL_BUILTIN), so
           the error of a prelude function can be reported at an argument (report_span in interp.c). */
        if (in.op == AGC_OP_CALL && p->functions[bx].prelude) check_spans(r, p, span, p->functions[bx].params + 1);
        break;
      case AGC_OP_CALL_BUILTIN:
        if (bx >= p->builtin_count) reject(r, "builtin index out of range");
        /* __fail_arg and the other prelude-only builtins fail at a place the prelude rule picks, so only the
           compiler prelude may call them. */
        if (agc_builtin_prelude_only(p->builtins[bx]) && !f->prelude) reject(r, "prelude-only builtin outside the prelude");
        check_window(r, in.a, p->builtins[bx]->arity, f);
        check_spans(r, p, span, p->builtins[bx]->arity + 1);
        break;
      case AGC_OP_CALL_VALUE:
        check_window(r, in.a, (uint32_t)in.b + 1, f);
        break;
      case AGC_OP_CLOSURE:
        if (bx >= p->function_count) reject(r, "function index out of range");
        check_not_entry(r, p, bx);
        check_window(r, in.a, p->functions[bx].captures, f);
        break;
      case AGC_OP_RANGE:
        check_register(r, in.a, f);
        check_window(r, in.b, 2, f);
        if (in.c > 1) reject(r, "bad range kind");
        break;
      case AGC_OP_RANGE_BOUNDS:
        check_window(r, in.a, 3, f);
        check_register(r, in.b, f);
        break;
      case AGC_OP_RETURN:
        check_register(r, in.a, f);
        break;
      default:
        reject(r, "unknown opcode %u", (unsigned)in.op);
    }
  }
  /* The writes must happen once each, before main: a loop around a GLOBAL_SET would write a slot again. */
  if (sets_global && jumps_back) reject(r, "GLOBAL_SET in a function with a backward jump");
}

/* Turns each STEP whose next instruction is a common one into the fused form for that opcode (AGC_FUSED_STEP_*),
   which saves the interpreter one dispatch. It runs after every function is checked, so the checks see only file
   opcodes. A STEP never ends a function (the last instruction is RETURN or JUMP) and never branches, so the next
   instruction is the one that runs after it; that instruction stays in place, so a jump to it, or a resume after the
   STEP yielded, runs it alone, as before. */
static void fuse_steps(agc_function *f) {
  for (uint32_t pc = 0; pc + 1 < f->count; pc++) {
    if (f->code[pc].op != AGC_OP_STEP) continue;
    switch (f->code[pc + 1].op) {
      case AGC_FUSED_CONST_ARITH_I: f->code[pc].op = AGC_FUSED_STEP_CONST_ARITH_I; break;
      case AGC_FUSED_CONST_DIV_I: f->code[pc].op = AGC_FUSED_STEP_CONST_DIV_I; break;
      case AGC_FUSED_CONST_MOD_I: f->code[pc].op = AGC_FUSED_STEP_CONST_MOD_I; break;
      case AGC_FUSED_CONST_LT_I: f->code[pc].op = AGC_FUSED_STEP_CONST_LT_I; break;
      case AGC_FUSED_CONST_LE_I: f->code[pc].op = AGC_FUSED_STEP_CONST_LE_I; break;
      case AGC_FUSED_CONST_EQ: f->code[pc].op = AGC_FUSED_STEP_CONST_EQ; break;
      case AGC_FUSED_CONST_NE: f->code[pc].op = AGC_FUSED_STEP_CONST_NE; break;
      case AGC_OP_MOVE: f->code[pc].op = AGC_FUSED_STEP_MOVE; break;
      case AGC_OP_CONST: f->code[pc].op = AGC_FUSED_STEP_CONST; break;
      case AGC_OP_FIELD: f->code[pc].op = AGC_FUSED_STEP_FIELD; break;
      case AGC_OP_LIST_GET: f->code[pc].op = AGC_FUSED_STEP_LIST_GET; break;
      case AGC_OP_IS_VARIANT: f->code[pc].op = AGC_FUSED_STEP_IS_VARIANT; break;
      case AGC_OP_GLOBAL: f->code[pc].op = AGC_FUSED_STEP_GLOBAL; break;
      case AGC_OP_ADD_I:
      case AGC_OP_SUB_I:
      case AGC_OP_MUL_I: f->code[pc].op = AGC_FUSED_STEP_ARITH_I; break;
      case AGC_OP_LT_I: f->code[pc].op = AGC_FUSED_STEP_LT_I; break;
      case AGC_OP_RETURN: f->code[pc].op = AGC_FUSED_STEP_RETURN; break;
      default: break;
    }
  }
}

/* Turns each CONST whose next instruction is an Int operator or a compare into the fused form for that opcode
   (AGC_FUSED_CONST_*), which saves one dispatch on `i + 1`, `n % 2 == 0` or `i < 10`. The fused form still writes the
   constant's register, since the loader does not know whether a later instruction reads it, and the operator runs
   exactly as it does alone (same checks, errors and span). Like fuse_steps, it runs after the checks, a CONST never
   ends a function, and the next instruction stays in place, so a jump to it runs it alone. It runs before fuse_steps,
   which then chains a STEP before a fused CONST. */
static void fuse_consts(agc_function *f) {
  for (uint32_t pc = 0; pc + 1 < f->count; pc++) {
    if (f->code[pc].op != AGC_OP_CONST) continue;
    switch (f->code[pc + 1].op) {
      case AGC_OP_ADD_I:
      case AGC_OP_SUB_I:
      case AGC_OP_MUL_I: f->code[pc].op = AGC_FUSED_CONST_ARITH_I; break;
      case AGC_OP_DIV_I: f->code[pc].op = AGC_FUSED_CONST_DIV_I; break;
      case AGC_OP_MOD_I: f->code[pc].op = AGC_FUSED_CONST_MOD_I; break;
      case AGC_OP_LT_I: f->code[pc].op = AGC_FUSED_CONST_LT_I; break;
      case AGC_OP_LE_I: f->code[pc].op = AGC_FUSED_CONST_LE_I; break;
      case AGC_OP_EQ: f->code[pc].op = AGC_FUSED_CONST_EQ; break;
      case AGC_OP_NE: f->code[pc].op = AGC_FUSED_CONST_NE; break;
      default: break;
    }
  }
}

static void skip_string(reader *r) { take(r, read_u32(r)); }

static uint64_t count_variants(reader *r, uint32_t enums) {
  size_t start = r->pos;
  uint64_t total = 0;
  for (uint32_t i = 0; i < enums; i++) {
    skip_string(r);
    uint32_t count = read_count(r, 8, "variant");
    for (uint32_t k = 0; k < count; k++) {
      skip_string(r);
      read_u32(r);
    }
    total += count;
  }
  r->pos = start;
  return total;
}

static int compare_names(const void *a, const void *b) {
  const agc_string *x = *(agc_string *const *)a;
  const agc_string *y = *(agc_string *const *)b;
  size_t n = x->bytes < y->bytes ? x->bytes : y->bytes;
  int c = n ? memcmp(x->data, y->data, n) : 0;
  if (c) return c;
  return x->bytes < y->bytes ? -1 : x->bytes > y->bytes;
}

static void load_types(reader *r, agc_program *p) {
  p->type_count = read_count(r, 1, "type");
  if (p->type_count > AGC_MAX_TYPES) reject(r, "too many types");
  p->types = load_alloc(r, agc_size_mul(p->type_count, sizeof(agc_type)), true);
  uint16_t *depth = load_alloc(r, agc_size_mul(p->type_count, sizeof(uint16_t)), true);
  for (uint32_t i = 0; i < p->type_count; i++) {
    depth[i] = 0;
    agc_type *t = &p->types[i];
    t->kind = read_u8(r);
    t->arg = 0;
    if (t->kind > AGC_TYPE_OPTIONAL) reject(r, "unknown type kind %u", (unsigned)t->kind);
    if (t->kind < AGC_TYPE_LIST) continue;
    t->arg = read_u32(r);
    if (t->kind == AGC_TYPE_STRUCT && t->arg >= p->struct_count) reject(r, "struct index out of range");
    if (t->kind == AGC_TYPE_STRUCT) continue;
    if (t->arg >= i) reject(r, "element type is not an earlier type");
    if (depth[t->arg] >= AGC_MAX_TYPE_DEPTH) reject(r, "type nesting too deep");
    depth[i] = (uint16_t)(depth[t->arg] + 1);
  }
  uint32_t count = read_count(r, 8, "decodable struct");
  agc_string **names = load_alloc(r, agc_size_mul(count, sizeof(agc_string *)), false);
  for (uint32_t i = 0, last = 0; i < count; i++) {
    uint32_t index = read_u32(r);
    if (index >= p->struct_count) reject(r, "struct index out of range");
    if (i && index <= last) reject(r, "decodable structs out of order");
    last = index;
    agc_struct_def *d = &p->structs[index];
    d->json_name = read_string(r);
    names[i] = d->json_name;
    if ((uint64_t)d->count * 4 > left(r)) reject(r, "field type count exceeds the file");
    d->field_types = load_alloc(r, agc_size_mul(d->count, sizeof(uint32_t)), true);
    for (uint32_t k = 0; k < d->count; k++) {
      d->field_types[k] = read_u32(r);
      if (d->field_types[k] >= p->type_count) reject(r, "type index out of range");
    }
  }
  if (count) qsort(names, count, sizeof(agc_string *), compare_names);
  for (uint32_t i = 1; i < count; i++)
    if (compare_names(&names[i - 1], &names[i]) == 0) reject(r, "duplicate JSON type name");
  for (uint32_t i = 0; i < p->type_count; i++)
    if (p->types[i].kind == AGC_TYPE_STRUCT && !p->structs[p->types[i].arg].json_name)
      reject(r, "type names a struct without field types");
}

/* The builtin JsonField enum, by its display name (a reserved name, so no user enum has it): exactly Absent, Null and
   Value(T) in that order, at most once. A type of kind JsonField needs it, since typed JSON builds its variants. */
static void find_json_field(reader *r, agc_program *p) {
  static const char *const names[] = {"Absent", "Null", "Value"};
  p->json_field = UINT32_MAX;
  for (uint32_t i = 0; i < p->enum_count; i++) {
    const agc_enum_def *d = &p->enums[i];
    if (!same_text(d->name, "JsonField")) continue;
    if (p->json_field != UINT32_MAX) reject(r, "duplicate JsonField enum");
    if (d->count != 3) reject(r, "bad JsonField enum");
    for (uint32_t k = 0; k < 3; k++) {
      const agc_variant_def *v = &p->variants[d->first + k];
      if (!same_text(v->name, names[k]) || v->arity != (k == AGC_JSON_FIELD_VALUE)) reject(r, "bad JsonField enum");
    }
    p->json_field = d->first;
  }
  for (uint32_t i = 0; i < p->type_count; i++)
    if (p->types[i].kind == AGC_TYPE_JSON_FIELD && p->json_field == UINT32_MAX)
      reject(r, "JsonField type without the JsonField enum");
}

/* The builtin Optional enum: named Optional, with None (no payload) and Some (one) in that order, at most once. No
   declaration may take the name now, but a .agcb file from before could declare its own enum Optional, so one of
   another shape is an ordinary enum, not an error. A type of kind Optional needs the enum, since typed JSON builds
   its variants. */
static void find_optional(reader *r, agc_program *p) {
  p->optional = UINT32_MAX;
  for (uint32_t i = 0; i < p->enum_count; i++) {
    const agc_enum_def *d = &p->enums[i];
    if (!same_text(d->name, "Optional") || d->count != 2) continue;
    const agc_variant_def *none = &p->variants[d->first];
    const agc_variant_def *some = &p->variants[d->first + 1];
    if (!same_text(none->name, "None") || none->arity != 0 || !same_text(some->name, "Some") || some->arity != 1)
      continue;
    if (p->optional != UINT32_MAX) reject(r, "duplicate Optional enum");
    p->optional = d->first;
  }
  for (uint32_t i = 0; i < p->type_count; i++)
    if (p->types[i].kind == AGC_TYPE_OPTIONAL && p->optional == UINT32_MAX)
      reject(r, "Optional type without the Optional enum");
}

static void load_tables(reader *r, agc_program *p) {
  p->struct_count = read_count(r, 8, "struct");
  p->structs = load_alloc(r, agc_size_mul(p->struct_count, sizeof(agc_struct_def)), false);
  for (uint32_t i = 0; i < p->struct_count; i++) {
    agc_struct_def *d = &p->structs[i];
    d->name = read_string(r);
    d->count = read_count(r, 4, "field");
    if (d->count > 65535) reject(r, "too many fields");
    d->fields = load_alloc(r, agc_size_mul(d->count, sizeof(agc_string *)), false);
    for (uint32_t k = 0; k < d->count; k++) d->fields[k] = read_string(r);
    if (d->count > p->max_fields) p->max_fields = d->count;
    d->json_name = NULL;
    d->field_types = NULL;
  }

  load_types(r, p);

  p->enum_count = read_count(r, 8, "enum");
  p->enums = load_alloc(r, agc_size_mul(p->enum_count, sizeof(agc_enum_def)), false);
  uint64_t total = count_variants(r, p->enum_count);
  p->variant_count = (uint32_t)total;
  p->variants = load_alloc(r, agc_size_mul(p->variant_count, sizeof(agc_variant_def)), false);
  for (uint32_t i = 0, next = 0; i < p->enum_count; i++) {
    agc_enum_def *d = &p->enums[i];
    d->name = read_string(r);
    d->first = next;
    d->count = read_count(r, 8, "variant");
    for (uint32_t k = 0; k < d->count; k++, next++) {
      agc_variant_def *v = &p->variants[next];
      v->name = read_string(r);
      v->owner = i;
      v->arity = read_u32(r);
      if (v->arity > 65535) reject(r, "variant arity too large");
      if (v->arity > p->max_arity) p->max_arity = v->arity;
      if (v->arity == 0) {
        v->shared = load_alloc(r, sizeof(agc_enum), false);
        v->shared->variant = next;
        v->shared->n = 0;
      }
    }
  }
  find_json_field(r, p);
  find_optional(r, p);
}

static void load_updates(reader *r, agc_program *p) {
  p->update_count = read_count(r, 8, "struct update");
  p->updates = load_alloc(r, agc_size_mul(p->update_count, sizeof(agc_update_def)), false);
  for (uint32_t i = 0; i < p->update_count; i++) {
    agc_update_def *u = &p->updates[i];
    u->type = read_u32(r);
    if (u->type >= p->struct_count) reject(r, "struct index out of range");
    u->count = read_count(r, 4, "updated field");
    /* Strictly increasing and below the field count: the interpreter writes
       fields[k] of a copy of that many fields without a bounds check. */
    if (u->count == 0 || u->count > p->structs[u->type].count) reject(r, "bad updated field count");
    u->fields = load_alloc(r, agc_size_mul(u->count, sizeof(uint32_t)), true);
    for (uint32_t k = 0; k < u->count; k++) {
      u->fields[k] = read_u32(r);
      if (u->fields[k] >= p->structs[u->type].count) reject(r, "updated field out of range");
      if (k && u->fields[k] <= u->fields[k - 1]) reject(r, "updated fields out of order");
    }
  }
}

/* Only a slot count: the initializers are ordinary functions that the entry calls. The count has no minimum
   bytes per entry, so read_count cannot bound it by the file size; the cap and the load budget do. The array
   is zeroed memory (AGC_T_VOID), hence "unset", and is scanned by the collector through the program. */
static void load_globals(reader *r, agc_program *p) {
  p->global_count = read_u32(r);
  if (p->global_count > AGC_MAX_GLOBALS) reject(r, "too many globals");
  p->globals = load_alloc(r, agc_size_mul(p->global_count, sizeof(agc_value)), false);
}

/* The first function that calls the native import: the span of a refusal at load (agc_ffi_refusal). */
static void note_native_function(agc_program *p) {
  for (uint32_t i = 0; i < p->function_count; i++) {
    const agc_function *f = &p->functions[i];
    for (uint32_t pc = 0; pc < f->count; pc++) {
      agc_instr in = f->code[pc];
      if (in.op == AGC_OP_CALL_BUILTIN && ((uint32_t)in.b | ((uint32_t)in.c << 16)) == p->native_import) {
        p->native_function = i;
        return;
      }
    }
  }
}

static void load(reader *r, agc_program *p) {
  if (memcmp(take(r, 4), AGC_MAGIC, 4) != 0) reject(r, "bad magic");
  r->format = read_u32(r);
  if (r->format != AGC_FORMAT_VERSION && r->format != AGC_FORMAT_PREVIOUS)
    reject(r, "unsupported format version");
  /* The version is read in both cases, so the text is validated and the file is parsed the same way. */
  if (!same_text(read_string(r), AGC_VERSION) && !r->any_version) reject(r, "built for another Agentica version");

  p->source_count = read_count(r, 8, "source");
  p->sources = load_alloc(r, agc_size_mul(p->source_count, sizeof(agc_source)), false);
  for (uint32_t i = 0; i < p->source_count; i++) {
    p->sources[i].name = read_string(r);
    p->sources[i].text = read_string(r);
    index_lines(r, &p->sources[i]);
  }

  p->span_count = read_count(r, 20, "span");
  if (p->span_count == 0) reject(r, "missing program span");
  p->spans = load_alloc(r, agc_size_mul(p->span_count, sizeof(agc_span)), true);
  for (uint32_t i = 0; i < p->span_count; i++) {
    const uint8_t *e = take(r, 20);
    agc_span s;
    s.source = get_u32(e);
    s.start_line = get_u32(e + 4);
    s.start_column = get_u32(e + 8);
    s.end_line = get_u32(e + 12);
    s.end_column = get_u32(e + 16);
    if (s.source >= p->source_count) reject(r, "span source out of range");
    const agc_source *source = &p->sources[s.source];
    check_position(r, source, s.start_line, s.start_column);
    check_position(r, source, s.end_line, s.end_column);
    if (s.start_line > s.end_line || (s.start_line == s.end_line && s.start_column > s.end_column))
      reject(r, "span starts after it ends");
    p->spans[i] = s;
  }

  p->constant_count = read_count(r, 1, "constant");
  p->constants = load_alloc(r, agc_size_mul(p->constant_count, sizeof(agc_value)), false);
  for (uint32_t i = 0; i < p->constant_count; i++) {
    uint8_t kind = read_u8(r);
    switch (kind) {
      case 0: p->constants[i] = agc_void(); break;
      case 1: p->constants[i] = agc_nil(); break;
      case 2: p->constants[i] = agc_bool(false); break;
      case 3: p->constants[i] = agc_bool(true); break;
      case 4: p->constants[i] = agc_int((int64_t)read_u64(r)); break;
      case 5: {
        uint64_t bits = read_u64(r);
        double f;
        memcpy(&f, &bits, sizeof f);
        p->constants[i] = agc_float(f);
        break;
      }
      case 6: p->constants[i] = agc_string_value(read_string(r)); break;
      default: reject(r, "unsupported constant kind %u", (unsigned)kind);
    }
  }

  load_tables(r, p);
  load_updates(r, p);
  load_globals(r, p);

  p->native_import = UINT32_MAX;
  p->native_function = UINT32_MAX;
  p->builtin_count = read_count(r, 8, "builtin");
  p->builtins = load_alloc(r, agc_size_mul(p->builtin_count, sizeof(agc_builtin *)), false);
  for (uint32_t i = 0; i < p->builtin_count; i++) {
    agc_string *name = read_string(r);
    uint32_t arity = read_u32(r);
    p->builtins[i] = agc_find_builtin((const uint8_t *)name->data, name->bytes, arity);
    if (!p->builtins[i]) reject(r, "unknown builtin");
    if (p->native_import == UINT32_MAX && strncmp(p->builtins[i]->name, AGC_NATIVE_PREFIX, AGC_NATIVE_PREFIX_LEN) == 0)
      p->native_import = i;
  }

  p->function_count = read_count(r, 36, "function");
  if (p->function_count == 0) reject(r, "no functions");
  p->functions = load_alloc(r, agc_size_mul(p->function_count, sizeof(agc_function)), false);
  for (uint32_t i = 0; i < p->function_count; i++) {
    agc_function *f = &p->functions[i];
    f->name = read_string(r);
    f->params = read_u32(r);
    f->captures = read_u32(r);
    f->registers = read_u32(r);
    f->span = read_u32(r);
    /* Version 6 added the prelude flag after the span (0 or 1); a version 5 file has no prelude function. */
    f->prelude = false;
    if (r->format >= AGC_FORMAT_VERSION) {
      uint32_t flag = read_u32(r);
      if (flag > 1) reject(r, "bad prelude flag");
      f->prelude = flag == 1;
    }
    if (f->registers == 0 || f->registers > 65535 || (uint64_t)f->params + f->captures > f->registers)
      reject(r, "bad register count");
    if (f->span >= p->span_count) reject(r, "span index out of range");
    f->count = read_count(r, 12, "instruction");
    if (f->count == 0) reject(r, "empty function");
    f->code = load_alloc(r, agc_size_mul(f->count, sizeof(agc_instr)), true);
    /* read_count has shown that 12 bytes per instruction are in the file, so these two bounds checks cannot fail. */
    const uint8_t *words = take(r, (size_t)f->count * 8);
    for (uint32_t k = 0; k < f->count; k++, words += 8) {
      f->code[k].op = get_u16(words);
      f->code[k].a = get_u16(words + 2);
      f->code[k].b = get_u16(words + 4);
      f->code[k].c = get_u16(words + 6);
    }
    f->spans = load_alloc(r, agc_size_mul(f->count, sizeof(uint32_t)), true);
    const uint8_t *indexes = take(r, (size_t)f->count * 4);
    for (uint32_t k = 0; k < f->count; k++) f->spans[k] = get_u32(indexes + (size_t)k * 4);
  }

  p->entry = read_u32(r);
  if (p->entry >= p->function_count) reject(r, "entry out of range");
  if (p->functions[p->entry].params != 0) reject(r, "entry takes parameters");
  if (p->functions[p->entry].captures != 0) reject(r, "entry has captures");
  if (left(r) != 0) reject(r, "trailing bytes");

  for (uint32_t i = 0; i < p->function_count; i++) check_function(r, p, &p->functions[i]);
  for (uint32_t i = 0; i < p->function_count; i++) {
    fuse_consts(&p->functions[i]);
    fuse_steps(&p->functions[i]);
  }
  if (p->native_import != UINT32_MAX) note_native_function(p);
}

static void trace_tables(const agc_trace *tr, const agc_program *p) {
  AGC_TRACE(tr, AGC_TRACE_LOADER,
            "tables sources=%" PRIu32 " spans=%" PRIu32 " constants=%" PRIu32 " builtins=%" PRIu32
            " functions=%" PRIu32 " structs=%" PRIu32 " types=%" PRIu32 " enums=%" PRIu32 " variants=%" PRIu32
            " updates=%" PRIu32 " globals=%" PRIu32,
            p->source_count, p->span_count, p->constant_count, p->builtin_count, p->function_count, p->struct_count,
            p->type_count, p->enum_count, p->variant_count, p->update_count, p->global_count);
}

static bool load_guarded(reader *r, agc_program *p) {
  if (setjmp(r->fail)) return false;
  load(r, p);
  return true;
}

static bool load_program(const uint8_t *data, size_t len, agc_program **program, char *error, size_t error_size,
                         const agc_trace *trace, bool any_version) {
  static const agc_trace off = {0, 2, 0, 0, 0};
  const agc_trace *tr = trace ? trace : &off;
  reader r;
  r.data = data;
  r.len = len;
  r.pos = 0;
  r.format = 0;
  r.any_version = any_version;
  r.trace = tr;
  r.start = AGC_TRACE_ON(tr, AGC_TRACE_LOADER) ? agc_trace_now() : 0;
  r.error = error;
  r.error_size = error_size;
  r.budget = (uint64_t)len * 4 + ((uint64_t)1 << 20);
  agc_program *p = agc_alloc(sizeof(agc_program));
  AGC_TRACE(tr, AGC_TRACE_LOADER, "file bytes=%zu", len);
  if (len > AGC_MAX_FILE_BYTES) {
    snprintf(error, error_size, "file is larger than 256 MiB");
    trace_reject(&r);
    return false;
  }
  agc_gc_pause();
  bool loaded = load_guarded(&r, p);
  agc_gc_resume();
  if (!loaded) return false;
  AGC_TRACE(tr, AGC_TRACE_LOADER, "format version=%" PRIu32, r.format);
  trace_tables(tr, p);
  AGC_TRACE(tr, AGC_TRACE_LOADER, "done us=%" PRIu64, elapsed_us(r.start));
  *program = p;
  return true;
}

bool agc_load_traced(const uint8_t *data, size_t len, agc_program **program, char *error, size_t error_size,
                     const agc_trace *trace) {
  return load_program(data, len, program, error, error_size, trace, false);
}

bool agc_load_front_end(const uint8_t *data, size_t len, agc_program **program, char *error, size_t error_size,
                        const agc_trace *trace) {
  return load_program(data, len, program, error, error_size, trace, true);
}

bool agc_load(const uint8_t *data, size_t len, agc_program **program, char *error, size_t error_size) {
  return agc_load_traced(data, len, program, error, error_size, NULL);
}

/* A relative name that is not under std/ (those are the embedded standard modules, which have no folder) and not the
 * name of a prelude file, which has no folder or text either. */
static bool takes_root(const agc_string *name) {
  if (name->bytes > 0 && name->data[0] == '/') return false;
  if (name->bytes >= 10 && memcmp(name->data, "<prelude>/", 10) == 0) return false;
  return !(name->bytes >= 4 && memcmp(name->data, "std/", 4) == 0);
}

/* The front end writes a user file that sits in a std/ folder as "./std/NAME.agc", so it is told apart from a
 * standard module. The "./" is dropped from the printed name. */
static size_t dot_slash(const agc_string *name) { return name->bytes >= 2 && name->data[0] == '.' && name->data[1] == '/' ? 2 : 0; }

bool agc_program_set_source_root(agc_program *program, const char *root, size_t root_chars) {
  size_t root_bytes = strlen(root);
  if (root_bytes == 0) return true;
  size_t slash = root[root_bytes - 1] != '/' ? 1 : 0;
  size_t joined_count = 0;
  for (uint32_t i = 0; i < program->source_count; i++)
    if (takes_root(program->sources[i].name)) joined_count++;
  if (agc_size_mul(joined_count, agc_size_add(root_bytes, slash)) > SOURCE_ROOT_BUDGET) return false;
  for (uint32_t i = 0; i < program->source_count; i++) {
    const agc_string *name = program->sources[i].name;
    if (!takes_root(name)) continue;
    size_t skip = dot_slash(name);
    size_t bytes = name->bytes - skip;
    /* chars is kept exact although nothing reads it after the join: agc_string says it counts the characters. */
    agc_string *joined = agc_new_string(agc_size_add(agc_size_add(root_bytes, slash), bytes),
                                        agc_size_add(agc_size_add(root_chars, slash), name->chars - skip));
    memcpy(joined->data, root, root_bytes);
    if (slash) joined->data[root_bytes] = '/';
    memcpy(joined->data + root_bytes + slash, name->data + skip, bytes);
    program->sources[i].name = joined;
  }
  return true;
}

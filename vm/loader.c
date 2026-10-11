#include "agc.h"

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#ifndef AGC_VERSION
#error "AGC_VERSION must be defined"
#endif

typedef struct {
  const uint8_t *data;
  size_t len, pos;
  uint64_t budget;
  char *error;
  size_t error_size;
  jmp_buf fail;
} reader;

static _Noreturn void reject(reader *r, const char *format, ...) {
  va_list args;
  va_start(args, format);
  vsnprintf(r->error, r->error_size, format, args);
  va_end(args);
  longjmp(r->fail, 1);
}

static size_t left(const reader *r) { return r->len - r->pos; }

static const uint8_t *take(reader *r, size_t n) {
  if (n > left(r)) reject(r, "truncated file");
  const uint8_t *p = r->data + r->pos;
  r->pos += n;
  return p;
}

static void *load_alloc(reader *r, size_t size, bool atomic) {
  if (size == 0) return NULL;
  if (size > r->budget) reject(r, "file needs too much memory");
  r->budget -= size;
  return atomic ? agc_alloc_atomic(size) : agc_alloc(size);
}

static uint8_t read_u8(reader *r) { return *take(r, 1); }

static uint16_t read_u16(reader *r) {
  const uint8_t *p = take(r, 2);
  return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t read_u32(reader *r) {
  const uint8_t *p = take(r, 4);
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

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

static void index_lines(reader *r, agc_source *source) {
  const agc_string *text = source->text;
  size_t lines = 1;
  for (size_t i = 0; i < text->bytes; i++)
    if (text->data[i] == '\n') lines++;
  source->lines = (uint32_t)lines;
  source->line_start = load_alloc(r, agc_size_mul(lines, sizeof(uint32_t)), true);
  source->line_chars = load_alloc(r, agc_size_mul(lines, sizeof(uint32_t)), true);
  size_t line = 0, chars = 0;
  source->line_start[0] = 0;
  for (size_t i = 0; i < text->bytes; i++) {
    uint8_t c = (uint8_t)text->data[i];
    if (c == '\n') {
      source->line_chars[line] = (uint32_t)chars;
      line++;
      source->line_start[line] = (uint32_t)(i + 1);
      chars = 0;
    } else if ((c & 0xC0) != 0x80) {
      chars++;
    }
  }
  source->line_chars[line] = (uint32_t)chars;
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

static void check_function(reader *r, const agc_program *p, const agc_function *f) {
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
      case AGC_OP_CONST:
        check_register(r, in.a, f);
        if (bx >= p->constant_count) reject(r, "constant index out of range");
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
        break;
      case AGC_OP_CALL:
      case AGC_OP_TAIL_CALL:
        if (bx >= p->function_count) reject(r, "function index out of range");
        if (p->functions[bx].captures) reject(r, "direct call to a function with captures");
        check_window(r, in.a, p->functions[bx].params, f);
        break;
      case AGC_OP_CALL_BUILTIN:
        if (bx >= p->builtin_count) reject(r, "builtin index out of range");
        check_window(r, in.a, p->builtins[bx]->arity, f);
        check_spans(r, p, span, p->builtins[bx]->arity + 1);
        break;
      case AGC_OP_CALL_VALUE:
        check_window(r, in.a, (uint32_t)in.b + 1, f);
        break;
      case AGC_OP_CLOSURE:
        if (bx >= p->function_count) reject(r, "function index out of range");
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
    if (t->kind > AGC_TYPE_STRUCT) reject(r, "unknown type kind %u", (unsigned)t->kind);
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
}

static void load(reader *r, agc_program *p) {
  if (memcmp(take(r, 4), "AGCB", 4) != 0) reject(r, "bad magic");
  if (read_u32(r) != AGC_FORMAT_VERSION) reject(r, "unsupported format version");
  if (!same_text(read_string(r), AGC_VERSION)) reject(r, "built for another Agentica version");

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
    agc_span s;
    s.source = read_u32(r);
    s.start_line = read_u32(r);
    s.start_column = read_u32(r);
    s.end_line = read_u32(r);
    s.end_column = read_u32(r);
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

  p->builtin_count = read_count(r, 8, "builtin");
  p->builtins = load_alloc(r, agc_size_mul(p->builtin_count, sizeof(agc_builtin *)), false);
  for (uint32_t i = 0; i < p->builtin_count; i++) {
    agc_string *name = read_string(r);
    uint32_t arity = read_u32(r);
    p->builtins[i] = agc_find_builtin((const uint8_t *)name->data, name->bytes, arity);
    if (!p->builtins[i]) reject(r, "unknown builtin");
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
    if (f->registers == 0 || f->registers > 65535 || (uint64_t)f->params + f->captures > f->registers)
      reject(r, "bad register count");
    if (f->span >= p->span_count) reject(r, "span index out of range");
    f->count = read_count(r, 12, "instruction");
    if (f->count == 0) reject(r, "empty function");
    f->code = load_alloc(r, agc_size_mul(f->count, sizeof(agc_instr)), true);
    for (uint32_t k = 0; k < f->count; k++) {
      f->code[k].op = read_u16(r);
      f->code[k].a = read_u16(r);
      f->code[k].b = read_u16(r);
      f->code[k].c = read_u16(r);
    }
    f->spans = load_alloc(r, agc_size_mul(f->count, sizeof(uint32_t)), true);
    for (uint32_t k = 0; k < f->count; k++) f->spans[k] = read_u32(r);
  }

  p->entry = read_u32(r);
  if (p->entry >= p->function_count) reject(r, "entry out of range");
  if (p->functions[p->entry].params != 0) reject(r, "entry takes parameters");
  if (p->functions[p->entry].captures != 0) reject(r, "entry has captures");
  if (left(r) != 0) reject(r, "trailing bytes");

  for (uint32_t i = 0; i < p->function_count; i++) check_function(r, p, &p->functions[i]);
}

bool agc_load(const uint8_t *data, size_t len, agc_program **program, char *error, size_t error_size) {
  reader r;
  r.data = data;
  r.len = len;
  r.pos = 0;
  r.error = error;
  r.error_size = error_size;
  r.budget = (uint64_t)len * 4 + ((uint64_t)1 << 20);
  agc_program *p = agc_alloc(sizeof(agc_program));
  if (len > AGC_MAX_FILE_BYTES) {
    snprintf(error, error_size, "file is larger than 256 MiB");
    return false;
  }
  if (setjmp(r.fail)) return false;
  load(&r, p);
  *program = p;
  return true;
}

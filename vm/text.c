/*
 * Text and debug forms: agc_text (the print form), agc_debug (the inspect
 * form), agc_test_text (the inspect form with a Json at any depth as its
 * canonical text and a Bytes as quoted text, for Test.eq), agc_concat, and
 * agc_write_form, the one escaper for String debug output. Core layer. Design:
 * docs/vm/02-reference-behavior.md §2.3 and §2.4.
 */
#include "core.h"

#include <inttypes.h>
#include <string.h>

/* The inspect and test forms of a Bytes show this many bytes, then "..." when there are more. */
#define BYTES_SHOWN 32
/* "<Bytes ", a size_t, a space, the shown bytes (two hex digits each, or two quotes and at most four characters each
   when quoted), "..." and ">". */
#define BYTES_FORM (7 + 20 + 1 + 2 + 4 * BYTES_SHOWN + 3 + 1)

/* How bytes_form writes a Bytes: its size alone (to_s), the first bytes in hex (inspect), or as quoted text (test
   messages). */
typedef enum { BYTES_SIZE, BYTES_HEX, BYTES_QUOTED } bytes_style;

typedef struct {
  agc_string *s;
  size_t cap;
} builder;

typedef struct {
  agc_value value;
  size_t next;
  agc_value *keys;
} debug_frame;

/* The builtin records and enums that a std/ module re-exports, by their builtin name, with the name a program writes:
   a printed value shows the written name (HTTP.Response(...), Logger.Level.Info), while the builtin name stays the key
   of the bytecode and the lowering. The records and enums of REEXPORTED_TYPES (compiler/syntax/types.agc); its
   handles print in agc_scalar_text (<HTTP.Client>). tests/test_frontend_catalog.py checks that they agree. Each name
   keeps its length, so a print compares lengths first and calls no strlen. */
#define WRITTEN(builtin, written) {builtin, sizeof builtin - 1, written, sizeof written - 1}
static const struct {
  const char *builtin;
  size_t builtin_len;
  const char *written;
  size_t written_len;
} written_names[] = {
    WRITTEN("HttpWire.ClientOptions", "HTTP.ClientOptions"),
    WRITTEN("HttpWire.Header", "HTTP.Header"),
    WRITTEN("HttpWire.Request", "HTTP.Request"),
    WRITTEN("HttpWire.Response", "HTTP.Response"),
    WRITTEN("HttpWire.ServerOptions", "HTTP.ServerOptions"),
    WRITTEN("LogRegistry.Event", "Logger.Event"),
    WRITTEN("LogRegistry.Level", "Logger.Level"),
};
#undef WRITTEN

bool agc_in_ranges(const uint32_t (*ranges)[2], size_t count, uint32_t cp) {
  size_t lo = 0, hi = count;
  while (lo < hi) {
    size_t mid = lo + (hi - lo) / 2;
    if (cp < ranges[mid][0])
      hi = mid;
    else if (cp > ranges[mid][1])
      lo = mid + 1;
    else
      return true;
  }
  return false;
}

bool agc_write_raw(uint32_t cp) { return agc_in_ranges(agc_write_raw_ranges, agc_write_raw_count, cp); }

static const char *short_escape(uint32_t cp) {
  switch (cp) {
    case 7: return "\\a";
    case 8: return "\\b";
    case 9: return "\\t";
    case 10: return "\\n";
    case 11: return "\\v";
    case 12: return "\\f";
    case 13: return "\\r";
    case 27: return "\\e";
    case '"': return "\\\"";
    case '\\': return "\\\\";
    default: return NULL;
  }
}

size_t agc_write_form(const agc_string *s, char *out, size_t *chars) {
  const uint8_t *data = (const uint8_t *)s->data;
  size_t n = 1, count = 2, at = 0;
  bool join = false;
  if (out) out[0] = '"';
  while (at < s->bytes) {
    uint8_t c = data[at];
    if (c >= 0x20 && c < 0x7F && c != '"' && c != '\\') {
      if (out) out[n] = (char)c;
      n++;
      count++;
      at++;
      join = c != ' ';
      continue;
    }
    size_t start = at;
    uint32_t cp = agc_utf8_next(data, s->bytes, &at);
    size_t width = at - start;
    const char *escape = short_escape(cp);
    bool raw = !escape && (agc_write_raw(cp) || (join && agc_in_ranges(agc_write_joiner_ranges, agc_write_joiner_count, cp)));
    join = raw && !agc_in_ranges(agc_write_blank_ranges, agc_write_blank_count, cp);
    char hex[12];
    const char *piece = (const char *)data + start;
    size_t len = width;
    if (raw) {
      count++;
    } else {
      if (!escape) {
        snprintf(hex, sizeof hex, cp < 0x10000 ? "\\u%04" PRIX32 : "\\U%08" PRIX32, cp);
        escape = hex;
      }
      piece = escape;
      len = strlen(escape);
      count += len;
    }
    if (out) memcpy(out + n, piece, len);
    n = agc_size_add(n, len);
  }
  if (out) out[n] = '"';
  *chars = count;
  return agc_size_add(n, 1);
}

agc_string *agc_concat(const agc_string *a, const agc_string *b) {
  agc_string *s = agc_new_string(agc_size_add(a->bytes, b->bytes), agc_size_add(a->chars, b->chars));
  if (a->bytes) memcpy(s->data, a->data, a->bytes);
  if (b->bytes) memcpy(s->data + a->bytes, b->data, b->bytes);
  return s;
}

/* One byte of the quoted form, with the escapes of agc_write_form: the short escapes by name (\n, \e, \", ...),
   printable ASCII as itself, any other byte as \xHH in upper-case hex. At most four characters. */
static size_t quoted_byte(uint8_t c, char *out) {
  static const char digits[] = "0123456789ABCDEF";
  const char *named = short_escape(c);
  if (named) {
    out[0] = named[0];
    out[1] = named[1];
    return 2;
  }
  if (c >= 0x20 && c < 0x7f) {
    out[0] = (char)c;
    return 1;
  }
  out[0] = '\\';
  out[1] = 'x';
  out[2] = digits[c >> 4];
  out[3] = digits[c & 15];
  return 4;
}

/* The text of a Bytes: "<Bytes N>" for to_s, the inspect form "<Bytes N 616263>" with the first BYTES_SHOWN bytes in
   hex, and the test form <Bytes 7 "+OK\r\n\x00\xFF"> with them quoted. Raw bytes are not text and may not be UTF-8,
   so no form holds them as they are: every form is ASCII. */
static size_t bytes_form(const agc_bytes *b, bytes_style style, char out[BYTES_FORM]) {
  static const char digits[] = "0123456789abcdef";
  size_t n = (size_t)snprintf(out, BYTES_FORM, "<Bytes %zu", b->len);
  if (style == BYTES_QUOTED || (style == BYTES_HEX && b->len)) {
    size_t shown = b->len < BYTES_SHOWN ? b->len : BYTES_SHOWN;
    out[n++] = ' ';
    if (style == BYTES_QUOTED) out[n++] = '"';
    for (size_t k = 0; k < shown; k++) {
      if (style == BYTES_QUOTED) {
        n += quoted_byte(b->data[k], out + n);
      } else {
        out[n++] = digits[b->data[k] >> 4];
        out[n++] = digits[b->data[k] & 15];
      }
    }
    if (style == BYTES_QUOTED) out[n++] = '"';
    if (shown < b->len) {
      memcpy(out + n, "...", 3);
      n += 3;
    }
  }
  out[n++] = '>';
  return n;
}

size_t agc_scalar_text(agc_vm *vm, agc_value v, char text[AGC_SCALAR_TEXT]) {
  if (agc_is(v, AGC_T_NIL)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "nil");
  if (agc_is(v, AGC_T_BOOL)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "%s", agc_as_bool(vm, v) ? "true" : "false");
  if (agc_is(v, AGC_T_FLOAT)) return agc_float_text(agc_as_float(vm, v), text);
  if (agc_is(v, AGC_T_FN)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<Fn>");
  if (agc_is(v, AGC_T_JSON)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<JSON.Value>");
  if (agc_is(v, AGC_T_HANDLE)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<File.Handle>");
  if (agc_is(v, AGC_T_TASK)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<Task>");
  if (agc_is(v, AGC_T_PROCESS)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<Process>");
  if (agc_is(v, AGC_T_SOCKET)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<TCP.Socket>");
  if (agc_is(v, AGC_T_LISTENER)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<TCP.Listener>");
  if (agc_is(v, AGC_T_HTTP_CLIENT)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<HTTP.Client>");
  if (agc_is(v, AGC_T_TLS_CONTEXT)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<TLS.Context>");
  if (agc_is(v, AGC_T_TEST)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<Test.Case>");
  if (agc_is(v, AGC_T_HTTP_SERVER)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<HTTP.Server>");
  if (agc_is(v, AGC_T_CHANNEL)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<Channel>");
  if (agc_is(v, AGC_T_LAZY)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<Lazy>");
  if (agc_is(v, AGC_T_ATS)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<ATS>");
  if (agc_is(v, AGC_T_ADDRESS))
    return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<Address %" PRIu64 ">", agc_address_id(vm, v));
  if (agc_is(v, AGC_T_MUTEX)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<Native.Mutex>");
  if (agc_is(v, AGC_T_C_POINTER)) return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<C.Pointer>");
  /* A long resource name is cut to fit the scalar buffer. */
  if (agc_is(v, AGC_T_C_RESOURCE))
    return (size_t)snprintf(text, AGC_SCALAR_TEXT, "<%.*s>", AGC_SCALAR_TEXT - 3, agc_as_c_resource(vm, v)->name);
  if (agc_is(v, AGC_T_RANGE)) {
    const agc_range *r = agc_as_range(vm, v);
    return (size_t)snprintf(text, AGC_SCALAR_TEXT, "%" PRId64 "%s%" PRId64, r->start, r->exclusive ? "..." : "..",
                            r->end);
  }
  return (size_t)snprintf(text, AGC_SCALAR_TEXT, "%" PRId64, agc_as_int(vm, v));
}

static char *reserve(builder *b, size_t extra) {
  size_t need = agc_size_add(b->s->bytes, extra);
  if (need > b->cap) {
    size_t cap = b->cap;
    while (cap < need) cap = agc_size_mul(cap, 2);
    agc_string *bigger = agc_new_string(cap, b->s->chars);
    bigger->bytes = b->s->bytes;
    if (b->s->bytes) memcpy(bigger->data, b->s->data, b->s->bytes);
    b->s = bigger;
    b->cap = cap;
  }
  return b->s->data + b->s->bytes;
}

static void append(builder *b, const char *text, size_t len) {
  memcpy(reserve(b, len), text, len);
  b->s->bytes += len;
  b->s->chars += len;
}

static void append_string(builder *b, const agc_string *s) {
  if (s->bytes) memcpy(reserve(b, s->bytes), s->data, s->bytes);
  b->s->bytes += s->bytes;
  b->s->chars += s->chars;
}

/* The name of a struct or an enum as a program writes it. */
static void append_type_name(builder *b, const agc_string *name) {
  for (size_t k = 0; k < sizeof written_names / sizeof written_names[0]; k++) {
    if (written_names[k].builtin_len == name->bytes &&
        memcmp(written_names[k].builtin, name->data, name->bytes) == 0) {
      append(b, written_names[k].written, written_names[k].written_len);
      return;
    }
  }
  append_string(b, name);
}

/* A Void has no text form (the checker rejects one with CHECK-VOID-VALUE): where the formatter would reach
   agc_as_int and fail, a non-NULL is_void reports it instead and the partial text is discarded. */
static void append_item(agc_vm *vm, builder *b, agc_value v, bool json, bool *is_void) {
  if (is_void && agc_is(v, AGC_T_VOID)) {
    *is_void = true;
    return;
  }
  if (json && agc_is(v, AGC_T_JSON)) {
    append_string(b, agc_json_encode(vm, v, 0));
  } else if (agc_is(v, AGC_T_STRING)) {
    const agc_string *s = agc_as_string(vm, v);
    size_t chars;
    size_t len = agc_write_form(s, NULL, &chars);
    agc_write_form(s, reserve(b, len), &chars);
    b->s->bytes += len;
    b->s->chars += chars;
  } else if (agc_is(v, AGC_T_BYTES)) {
    char form[BYTES_FORM];
    append(b, form, bytes_form(agc_as_bytes(vm, v), json ? BYTES_QUOTED : BYTES_HEX, form));
  } else {
    char text[AGC_SCALAR_TEXT];
    append(b, text, agc_scalar_text(vm, v, text));
  }
}

static bool compound(agc_value v) {
  return agc_is(v, AGC_T_LIST) || agc_is(v, AGC_T_MAP) || agc_is(v, AGC_T_SET) || agc_is(v, AGC_T_STRUCT) ||
         agc_is(v, AGC_T_ENUM) || agc_is(v, AGC_T_RESULT);
}

const agc_struct_def *agc_struct_def_of(agc_vm *vm, const agc_struct *st) {
  const agc_program *p = vm->rt->program;
  if (!p || st->type >= p->struct_count || p->structs[st->type].count != st->n)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: unknown struct type", 0);
  return &p->structs[st->type];
}

static const agc_variant_def *variant_def(agc_vm *vm, const agc_enum *e) {
  const agc_program *p = vm->rt->program;
  if (!p || e->variant >= p->variant_count || p->variants[e->variant].arity != e->n)
    agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: unknown enum variant", 0);
  return &p->variants[e->variant];
}

/* The builtin enum Optional, which the loader found by its name and shape (program->optional); an enum named Optional
   of another shape, from an older .agcb, prints as Enum.Variant. */
static bool optional_enum(const agc_program *p, const agc_enum_def *def) {
  return p->optional != UINT32_MAX && def->first == p->optional;
}

/* An Error prints as the error(...) call that builds it: the message, then each of kind, code, details and cause that
   is not its default, by name, with code and cause out of their some(...). The location never prints. So an Error is
   a struct whose items are these shown fields (error_shown), not its six fields: item_count and item_at of an Error
   count and give only those. A field of a hostile struct that holds another type is shown as it is. */
static bool error_default(agc_vm *vm, uint32_t field, agc_value v) {
  if (field == AGC_ERROR_KIND) {
    if (!agc_is(v, AGC_T_STRING)) return false;
    const agc_string *kind = agc_as_string(vm, v);
    return kind->bytes == 5 && memcmp(kind->data, "error", 5) == 0;
  }
  if (field == AGC_ERROR_DETAILS) return agc_is(v, AGC_T_MAP) && agc_as_map(vm, v)->size == 0;
  return agc_is(v, AGC_T_ENUM) && agc_as_enum(vm, v)->variant == vm->rt->program->optional;
}

/* The fields of Error E that print, in the order of the call's arguments; returns how many. */
static size_t error_shown(agc_vm *vm, const agc_struct *e, uint32_t shown[5]) {
  static const uint32_t named[] = {AGC_ERROR_KIND, AGC_ERROR_CODE, AGC_ERROR_DETAILS, AGC_ERROR_CAUSE};
  size_t n = 0;
  shown[n++] = AGC_ERROR_MESSAGE;
  for (size_t k = 0; k < sizeof named / sizeof named[0]; k++)
    if (!error_default(vm, named[k], e->fields[named[k]])) shown[n++] = named[k];
  return n;
}

/* A shown field of an Error: code and cause without their some(...), which the call does not write. */
static agc_value error_item(agc_vm *vm, const agc_struct *e, size_t k) {
  uint32_t shown[5];
  (void)error_shown(vm, e, shown);
  agc_value v = e->fields[shown[k]];
  if ((shown[k] == AGC_ERROR_CODE || shown[k] == AGC_ERROR_CAUSE) && agc_is(v, AGC_T_ENUM)) {
    const agc_enum *some = agc_as_enum(vm, v);
    if (some->variant == vm->rt->program->optional + 1 && some->n == 1) return some->payload[0];
  }
  return v;
}

/* A failed Result that holds an Error prints as the Error alone, which is already the error(...) call: not
   error(error(...)). */
static agc_value printed(agc_vm *vm, agc_value v) {
  if (!agc_is(v, AGC_T_RESULT)) return v;
  const agc_result *r = agc_as_result(vm, v);
  return !r->ok && agc_is_error(vm, r->value) ? r->value : v;
}

static size_t item_count(agc_vm *vm, agc_value v) {
  if (agc_is_error(vm, v)) {
    uint32_t shown[5];
    return error_shown(vm, agc_as_struct(vm, v), shown);
  }
  if (agc_is(v, AGC_T_LIST)) return agc_list_len(agc_as_list(vm, v));
  if (agc_is(v, AGC_T_MAP)) return agc_as_map(vm, v)->size;
  if (agc_is(v, AGC_T_SET)) return agc_as_set(vm, v)->size;
  if (agc_is(v, AGC_T_STRUCT)) return agc_as_struct(vm, v)->n;
  if (agc_is(v, AGC_T_RESULT)) {
    const agc_result *r = agc_as_result(vm, v);
    return r->ok && agc_is(r->value, AGC_T_VOID) ? 0 : 1;
  }
  const agc_enum *e = agc_as_enum(vm, v);
  return e->n == 1 && agc_is(e->payload[0], AGC_T_VOID) ? 0 : e->n;
}

static agc_value item_at(agc_vm *vm, agc_value v, size_t k) {
  if (agc_is_error(vm, v)) return error_item(vm, agc_as_struct(vm, v), k);
  if (agc_is(v, AGC_T_LIST)) return agc_list_get(agc_as_list(vm, v), k);
  if (agc_is(v, AGC_T_STRUCT)) return agc_as_struct(vm, v)->fields[k];
  if (agc_is(v, AGC_T_RESULT)) return agc_as_result(vm, v)->value;
  return agc_as_enum(vm, v)->payload[k];
}

static bool open_value(agc_vm *vm, builder *b, agc_value v) {
  if (agc_is(v, AGC_T_LIST)) {
    append(b, "[", 1);
    return true;
  }
  if (agc_is(v, AGC_T_MAP)) {
    append(b, "{", 1);
    return true;
  }
  if (agc_is(v, AGC_T_SET)) {
    append(b, "Set[", 4);
    return true;
  }
  if (agc_is_error(vm, v)) {
    append(b, "error(", 6);
    return true;
  }
  if (agc_is(v, AGC_T_STRUCT)) {
    append_type_name(b, agc_struct_def_of(vm, agc_as_struct(vm, v))->name);
    append(b, "(", 1);
    return true;
  }
  if (agc_is(v, AGC_T_RESULT)) {
    if (agc_as_result(vm, v)->ok)
      append(b, "ok(", 3);
    else
      append(b, "error(", 6);
    return true;
  }
  const agc_enum *e = agc_as_enum(vm, v);
  const agc_variant_def *variant = variant_def(vm, e);
  const agc_program *program = vm->rt->program;
  const agc_string *owner = program->enums[variant->owner].name;
  if (optional_enum(program, &program->enums[variant->owner])) {
    /* The builtin enum Optional prints as its constructors are written: none and some(x). */
    if (e->n == 0) {
      append(b, "none", 4);
      return false;
    }
    append(b, "some(", 5);
    return true;
  }
  append_type_name(b, owner);
  append(b, ".", 1);
  append_string(b, variant->name);
  if (e->n == 0) return false;
  append(b, "(", 1);
  return true;
}

static agc_string *compound_debug(agc_vm *vm, agc_value root, bool json, bool *is_void) {
  builder b;
  b.cap = 64;
  b.s = agc_new_string(b.cap, 0);
  b.s->bytes = 0;
  size_t depth = 0, capacity = 16;
  debug_frame *stack = agc_alloc(agc_size_mul(capacity, sizeof(debug_frame)));
  agc_value item = root;
  for (;;) {
    item = printed(vm, item);
    if (!compound(item)) {
      append_item(vm, &b, item, json, is_void);
      if (is_void && *is_void) return b.s;
    } else if (open_value(vm, &b, item)) {
      if (depth == capacity) {
        size_t bigger = agc_size_mul(capacity, 2);
        debug_frame *grown = agc_alloc(agc_size_mul(bigger, sizeof(debug_frame)));
        memcpy(grown, stack, depth * sizeof(debug_frame));
        stack = grown;
        capacity = bigger;
      }
      stack[depth].value = item;
      stack[depth].next = 0;
      stack[depth].keys = agc_is(item, AGC_T_MAP)   ? agc_map_keys(vm, agc_as_map(vm, item), 0)
                          : agc_is(item, AGC_T_SET) ? agc_map_keys(vm, agc_as_set(vm, item), 0)
                                                    : NULL;
      depth++;
    }
    for (;;) {
      if (!depth) return b.s;
      debug_frame *top = &stack[depth - 1];
      if (top->next < item_count(vm, top->value)) break;
      bool square = agc_is(top->value, AGC_T_LIST) || agc_is(top->value, AGC_T_SET);
      append(&b, square ? "]" : agc_is(top->value, AGC_T_MAP) ? "}" : ")", 1);
      depth--;
    }
    debug_frame *top = &stack[depth - 1];
    if (top->next) append(&b, ", ", 2);
    if (agc_is_error(vm, top->value)) {
      /* The message is the call's first argument, without a name; the shown fields after it are named. */
      if (top->next) {
        uint32_t shown[5];
        (void)error_shown(vm, agc_as_struct(vm, top->value), shown);
        append_string(&b, agc_struct_def_of(vm, agc_as_struct(vm, top->value))->fields[shown[top->next]]);
        append(&b, ": ", 2);
      }
    } else if (agc_is(top->value, AGC_T_STRUCT)) {
      append_string(&b, agc_struct_def_of(vm, agc_as_struct(vm, top->value))->fields[top->next]);
      append(&b, ": ", 2);
    }
    if (agc_is(top->value, AGC_T_MAP)) {
      agc_value key = top->keys[top->next++];
      append_item(vm, &b, key, json, is_void);
      if (is_void && *is_void) return b.s;
      append(&b, ": ", 2);
      if (!agc_map_get(vm, agc_as_map(vm, top->value), key, &item))
        agc_fail(vm, "RUNTIME-INTERNAL", "invalid map", 0);
      continue;
    }
    if (agc_is(top->value, AGC_T_SET)) {
      item = top->keys[top->next++];
      continue;
    }
    item = item_at(vm, top->value, top->next++);
  }
}

/* The to_s form of a Bytes at the top level ("<Bytes N>"); inside a List, Map or other value it takes the inspect form,
   as a String there is quoted. */
static agc_string *bytes_text(agc_vm *vm, agc_value v) {
  char form[BYTES_FORM];
  size_t n = bytes_form(agc_as_bytes(vm, v), BYTES_SIZE, form);
  return agc_make_string(form, n, n);
}

agc_string *agc_text(agc_vm *vm, agc_value v) {
  if (agc_is(v, AGC_T_STRING)) return agc_as_string(vm, v);
  /* to_s of an Error is its message, as Ruby's Exception#to_s; inspect is the error(...) call. */
  if (agc_is_error(vm, v)) return agc_error_message(vm, v);
  if (agc_is(v, AGC_T_JSON)) return agc_json_encode(vm, v, 0);
  if (agc_is(v, AGC_T_BYTES)) return bytes_text(vm, v);
  return agc_debug(vm, v);
}

static agc_string *debug_text(agc_vm *vm, agc_value v, bool json, bool *is_void) {
  if (json && agc_is(v, AGC_T_JSON)) return agc_json_encode(vm, v, 0);
  if (compound(v)) {
    agc_string *text = compound_debug(vm, v, json, is_void);
    if (is_void && *is_void) return text;
    agc_charge_bytes(vm, text->bytes);
    return text;
  }
  if (is_void && agc_is(v, AGC_T_VOID)) {
    *is_void = true;
    return vm->rt->empty_string;
  }
  if (agc_is(v, AGC_T_BYTES)) {
    char form[BYTES_FORM];
    size_t n = bytes_form(agc_as_bytes(vm, v), json ? BYTES_QUOTED : BYTES_HEX, form);
    return agc_make_string(form, n, n);
  }
  if (!agc_is(v, AGC_T_STRING)) {
    char text[AGC_SCALAR_TEXT];
    size_t n = agc_scalar_text(vm, v, text);
    return agc_small_string(vm, text, n, n);
  }
  const agc_string *s = agc_as_string(vm, v);
  agc_charge_bytes(vm, s->bytes);
  size_t chars;
  size_t bytes = agc_write_form(s, NULL, &chars);
  agc_string *result = agc_new_string(bytes, chars);
  agc_write_form(s, result->data, &chars);
  return result;
}

agc_string *agc_debug(agc_vm *vm, agc_value v) { return debug_text(vm, v, false, NULL); }

/* Like agc_text, but a Void at the top level or inside a list, map value, set, struct, enum or Result, or a top-level
   Error whose message is not a String, reports through the result instead of failing: every other invalid value
   still fails as agc_text does. */
bool agc_text_checked(agc_vm *vm, agc_value v, agc_string **text) {
  if (agc_is(v, AGC_T_VOID)) return false;
  if (agc_is(v, AGC_T_STRING)) {
    *text = agc_as_string(vm, v);
    return true;
  }
  if (agc_is_error(vm, v)) {
    agc_value message = agc_as_struct(vm, v)->fields[AGC_ERROR_MESSAGE];
    if (!agc_is(message, AGC_T_STRING)) return false;
    *text = agc_as_string(vm, message);
    return true;
  }
  if (agc_is(v, AGC_T_JSON)) {
    *text = agc_json_encode(vm, v, 0);
    return true;
  }
  if (agc_is(v, AGC_T_BYTES)) {
    *text = bytes_text(vm, v);
    return true;
  }
  bool is_void = false;
  agc_string *s = debug_text(vm, v, false, &is_void);
  if (is_void) return false;
  *text = s;
  return true;
}

/* The inspect form, except that a Json at any depth is its canonical text and a Bytes is quoted text (most protocol
   bytes are text), for Test.eq's expected and actual. */
agc_string *agc_test_text(agc_vm *vm, agc_value v) { return debug_text(vm, v, true, NULL); }

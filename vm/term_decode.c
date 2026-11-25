/*
 * Term.decode: CBOR written by Term.encode, read into the type of the target (a struct or enum of the type table).
 * The bytes may come from anyone: heads must be the shortest, lengths are definite and checked against the bytes
 * left, floats have the size of their type, and nothing is read past TERM_MAX_DEPTH levels, TERM_MAX_ITEMS values or
 * 64 MiB. One explicit frame stack walks the type, so no C recursion follows the depth. Service layer.
 * Design: docs/vm/02-reference-behavior.md §2.9.
 */
#include "services.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

/* Not a kind of the type table: a value that no type names (a key of a struct that it has no field for). */
#define SKIP UINT32_MAX
#define NO_FIELD UINT32_MAX

typedef enum { FRAME_LIST, FRAME_MAP, FRAME_STRUCT, FRAME_ENUM, FRAME_OPTIONAL, FRAME_SKIP } frame_kind;

/* An open container. next counts the children taken, n the children it has: a Map and a struct have a key and a value
   for each entry, so twice their size, and a struct reads its key together with the start of its value. */
typedef struct {
  frame_kind kind;
  uint32_t arg;                /* LIST, MAP, OPTIONAL, JSON.Field: the type of the items or values; STRUCT: its index */
  uint32_t field;              /* STRUCT: the field that the value being read is for, or NO_FIELD */
  uint32_t guess;              /* STRUCT: the field that the next key should name, as encode writes them */
  const uint32_t *types;       /* STRUCT: the field types; ENUM: the payload types, NULL for JSON.Field.Value */
  size_t next, n;
  size_t base;                 /* LIST, MAP: where its children start in the value stack */
  size_t key_at, key_len;      /* STRUCT: the key of the entry being read */
  size_t matched;              /* STRUCT: the fields read */
  bool int_keys;               /* MAP: the keys are Ints */
  uint8_t *seen;               /* STRUCT: a flag for each field read */
  agc_map *ignored;            /* STRUCT: the keys that name no field, to refuse a repeated one */
  agc_value key;               /* MAP: the key of the entry being read */
  agc_value value;             /* OPTIONAL: the value inside */
  agc_struct *record;
  agc_enum *tagged;
} frame;

typedef struct {
  uint32_t kind, arg;
  bool nullable; /* the type is the one inside an Optional: a mismatch says "or nil" */
} want_t;

typedef struct {
  agc_vm *vm;
  const agc_program *p;
  uint32_t span;
  const uint8_t *data;
  size_t len, at;
  frame *stack;
  size_t depth, capacity, levels;
  agc_value *vals;
  size_t nvals, vcap;
  size_t items;
} decoder;

typedef struct {
  uint8_t major, info;
  uint64_t arg;
} head;

typedef enum { HEAD_OK, HEAD_SHORT, HEAD_LONG, HEAD_INDEFINITE, HEAD_RESERVED } head_status;
typedef enum { READ_VALUE, READ_NEXT, READ_FAIL } read_status;

static const char *head_reason(head_status status) {
  switch (status) {
    case HEAD_SHORT: return "unexpected end of data";
    case HEAD_LONG: return "head is not the shortest form";
    case HEAD_INDEFINITE: return "indefinite lengths are not allowed";
    default: return "reserved additional information";
  }
}

/* The head at d->at: the major type, the additional information and the argument. A head of the types 0 to 5 must be
   the shortest one that holds its argument. A float of the type 7 gives its bits as the argument. */
static head_status read_head(decoder *d, head *h) {
  if (d->at >= d->len) return HEAD_SHORT;
  uint8_t first = d->data[d->at];
  h->major = first >> 5;
  h->info = first & 31;
  if (h->info < 24) {
    h->arg = h->info;
    d->at++;
    return HEAD_OK;
  }
  if (h->info > 27) return h->info == 31 ? HEAD_INDEFINITE : HEAD_RESERVED;
  size_t width = (size_t)1 << (h->info - 24);
  if (d->len - d->at - 1 < width) return HEAD_SHORT;
  uint64_t v = 0;
  for (size_t k = 0; k < width; k++) v = (v << 8) | d->data[d->at + 1 + k];
  static const uint64_t least[] = {24, 256, 65536, UINT64_C(4294967296)};
  if (h->major < 6 && v < least[h->info - 24]) return HEAD_LONG;
  h->arg = v;
  d->at += 1 + width;
  return HEAD_OK;
}

static const char *const narrow_names[] = {"Int8", "Int16", "Int32", "UInt8", "UInt16", "UInt32"};

/* What a mismatch expects, for the kind of the type table. */
static void expected_text(const decoder *d, const want_t *w, char *out, size_t size) {
  int64_t least, greatest;
  const char *text = NULL;
  char owned[96];
  if (agc_type_narrow(w->kind, &least, &greatest)) {
    snprintf(owned, sizeof owned, "%s from %" PRId64 " to %" PRId64, narrow_names[w->kind - AGC_TYPE_INT8], least,
             greatest);
    text = owned;
  } else if (w->kind == AGC_TYPE_STRUCT || w->kind == AGC_TYPE_INSTANCE || w->kind == AGC_TYPE_ENUM) {
    const agc_string *name = w->kind == AGC_TYPE_STRUCT     ? d->p->structs[w->arg].name
                             : w->kind == AGC_TYPE_INSTANCE ? d->p->structs[d->p->instances[w->arg].struct_index].name
                                                            : d->p->enums[w->arg].name;
    const char *what = w->kind == AGC_TYPE_ENUM ? "enum" : "struct";
    snprintf(owned, sizeof owned, "%s %.*s", what, (int)name->bytes, name->data);
    text = owned;
  } else {
    switch (w->kind) {
      case AGC_TYPE_INT: text = "signed 64-bit Int"; break;
      case AGC_TYPE_UINT64: text = "UInt64 from 0 to 18446744073709551615"; break;
      case AGC_TYPE_FLOAT: text = "Float"; break;
      case AGC_TYPE_FLOAT32: text = "Float32"; break;
      case AGC_TYPE_BOOL: text = "Bool"; break;
      case AGC_TYPE_NIL: text = "nil"; break;
      case AGC_TYPE_STRING: text = "String"; break;
      case AGC_TYPE_BYTES: text = "Bytes"; break;
      case AGC_TYPE_LIST: text = "List"; break;
      case AGC_TYPE_MAP: case AGC_TYPE_INT_MAP: text = "Map"; break;
      default: text = "enum JSON.Field"; break;
    }
  }
  snprintf(out, size, "expected %s%s", text, w->nullable ? " or nil" : "");
}

static void put_path(const decoder *d, agc_json_buffer *b) {
  for (size_t i = 0; i < d->depth; i++) {
    const frame *f = &d->stack[i];
    char text[48];
    if (f->kind == FRAME_LIST) {
      agc_json_put(b, text, (size_t)snprintf(text, sizeof text, "[%zu]", f->next));
    } else if (f->kind == FRAME_MAP && (f->next & 1)) {
      if (f->int_keys) {
        agc_json_put(b, text, (size_t)snprintf(text, sizeof text, "[%" PRId64 "]", f->key.as.i));
      } else {
        const agc_string *key = agc_as_string(d->vm, f->key);
        agc_json_put(b, "[", 1);
        agc_term_path_key(b, (const uint8_t *)key->data, key->bytes);
        agc_json_put(b, "]", 1);
      }
    } else if (f->kind == FRAME_STRUCT && (f->next & 1)) {
      if (f->field == NO_FIELD) {
        agc_json_put(b, "[", 1);
        agc_term_path_key(b, d->data + f->key_at, f->key_len);
        agc_json_put(b, "]", 1);
      } else {
        const agc_string *name = d->p->structs[f->arg].fields[f->field];
        if (b->len) agc_json_put(b, ".", 1);
        agc_json_put(b, name->data, name->bytes);
      }
    } else if (f->kind == FRAME_ENUM) {
      agc_json_put(b, text, (size_t)snprintf(text, sizeof text, "%svalues[%zu]", b->len ? "." : "", f->next));
    }
  }
}

/* The error Result "path: reason", the path being the open frames; the reason is text followed by tail. */
static agc_value fail(const decoder *d, const char *text, const uint8_t *tail, size_t tail_bytes) {
  agc_json_buffer b = {agc_alloc_atomic(64), 0, 64};
  put_path(d, &b);
  if (!b.len) agc_json_put(&b, "$", 1);
  agc_json_put(&b, ": ", 2);
  agc_json_put(&b, text, strlen(text));
  if (tail) agc_term_path_key(&b, tail, tail_bytes);
  agc_charge_bytes(d->vm, b.len);
  agc_string *message = agc_make_string(b.data, b.len, agc_utf8_count((const uint8_t *)b.data, b.len));
  return agc_error_string(d->vm, AGC_KIND_TERM_DECODE, message);
}

static agc_value fail_expected(const decoder *d, const want_t *w) {
  char text[160];
  expected_text(d, w, text, sizeof text);
  return fail(d, text, NULL, 0);
}

static frame *push_frame(decoder *d, frame_kind kind, uint32_t arg, size_t n) {
  d->stack = agc_json_grow(d->stack, &d->capacity, d->depth, sizeof(frame));
  frame *f = &d->stack[d->depth++];
  *f = (frame){.kind = kind, .arg = arg, .field = NO_FIELD, .n = n, .base = d->nvals};
  if (kind != FRAME_OPTIONAL) d->levels++;
  return f;
}

static void store_value(decoder *d, agc_value v) {
  if (d->nvals == d->vcap) {
    size_t cap = d->vcap ? d->vcap * 2 : 64;
    agc_value *grown = agc_alloc(agc_size_mul(cap, sizeof(agc_value)));
    if (d->nvals) memcpy(grown, d->vals, d->nvals * sizeof(agc_value));
    d->vals = grown;
    d->vcap = cap;
  }
  d->vals[d->nvals++] = v;
}

static void frame_store(decoder *d, frame *f, agc_value v) {
  switch (f->kind) {
    case FRAME_LIST: store_value(d, v); break;
    case FRAME_MAP:
      if (!(f->next & 1)) f->key = v;
      store_value(d, v);
      break;
    case FRAME_STRUCT:
      if (f->field != NO_FIELD) f->record->fields[f->field] = v;
      break;
    case FRAME_ENUM: f->tagged->payload[f->next] = v; break;
    case FRAME_OPTIONAL: f->value = v; break;
    case FRAME_SKIP: break;
  }
  f->next++;
}

static want_t want_of(const decoder *d, uint32_t type) {
  return (want_t){d->p->types[type].kind, d->p->types[type].arg, false};
}

/* The first field of the struct that the entries did not name, for the error of a struct that is short of fields. */
static const agc_string *missing_field(const decoder *d, const frame *f) {
  const agc_struct_def *def = &d->p->structs[f->arg];
  uint32_t k = 0;
  while (k < def->count && f->seen[k]) k++;
  return def->fields[k];
}

/* The value of a frame whose children were all taken, or false with *error. The frame is still open. */
static bool close_frame(decoder *d, frame *f, agc_value *v, agc_value *error) {
  agc_vm *vm = d->vm;
  switch (f->kind) {
    case FRAME_LIST: *v = agc_list_value(agc_list_from_array(d->vals + f->base, f->n)); break;
    case FRAME_MAP: {
      agc_map *m = agc_as_map(vm, vm->rt->empty_map);
      for (size_t k = 0; k < f->n; k += 2) {
        size_t before = m->size;
        m = agc_map_put(vm, m, d->vals[f->base + k], d->vals[f->base + k + 1]);
        if (m->size == before) {
          f->key = d->vals[f->base + k];
          f->next = f->n - 1;
          *error = fail(d, "duplicate key", NULL, 0);
          return false;
        }
      }
      *v = agc_map_value(m);
      break;
    }
    case FRAME_STRUCT:
      if (f->matched != d->p->structs[f->arg].count) {
        const agc_string *name = missing_field(d, f);
        *error = fail(d, "missing field ", (const uint8_t *)name->data, name->bytes);
        return false;
      }
      *v = agc_struct_value(f->record);
      break;
    case FRAME_ENUM: *v = agc_enum_value(f->tagged); break;
    case FRAME_OPTIONAL: *v = agc_optional_make(d->p, true, f->value); break;
    case FRAME_SKIP: *v = agc_void(); break;
  }
  d->nvals = f->base;
  return true;
}

static bool same_bytes(const agc_string *name, const uint8_t *text, size_t n) {
  return name->bytes == n && memcmp(name->data, text, n) == 0;
}

/* Reads the key of the next entry of a struct frame: a text that names a field, or one that does not (SKIP). */
static bool read_field_key(decoder *d, frame *f, want_t *w, agc_value *error) {
  const agc_struct_def *def = &d->p->structs[f->arg];
  head h;
  head_status status = read_head(d, &h);
  if (status != HEAD_OK) {
    *error = fail(d, head_reason(status), NULL, 0);
    return false;
  }
  if (h.major != 3) {
    *error = fail(d, "expected String key", NULL, 0);
    return false;
  }
  size_t chars = 0;
  if (h.arg > d->len - d->at || !agc_utf8_chars(d->data + d->at, (size_t)h.arg, &chars)) {
    *error = fail(d, h.arg > d->len - d->at ? "unexpected end of data" : "invalid UTF-8", NULL, 0);
    return false;
  }
  const uint8_t *key = d->data + d->at;
  size_t n = (size_t)h.arg;
  f->key_at = d->at;
  f->key_len = n;
  d->at += n;
  uint32_t found = NO_FIELD;
  if (f->guess < def->count && same_bytes(def->fields[f->guess], key, n)) {
    found = f->guess;
  } else {
    agc_charge(d->vm, def->count / 8);
    for (uint32_t k = 0; k < def->count && found == NO_FIELD; k++)
      if (same_bytes(def->fields[k], key, n)) found = k;
  }
  if (found != NO_FIELD && f->seen[found]) {
    *error = fail(d, "duplicate field ", key, n);
    return false;
  }
  if (found == NO_FIELD) {
    agc_map *ignored = f->ignored ? f->ignored : agc_as_map(d->vm, d->vm->rt->empty_map);
    size_t before = ignored->size;
    f->ignored = agc_map_put(d->vm, ignored, agc_string_value(agc_make_string((const char *)key, n, chars)), agc_nil());
    if (f->ignored->size == before) {
      *error = fail(d, "duplicate field ", key, n);
      return false;
    }
  }
  f->field = found;
  f->next++;
  if (found == NO_FIELD) {
    *w = (want_t){SKIP, 0, false};
    return true;
  }
  f->seen[found] = 1;
  f->matched++;
  f->guess = found + 1;
  *w = want_of(d, f->types[found]);
  return true;
}

/* What the next child of the frame is: its key or value, ready to read. False means a failure, in *error. */
static bool next_child(decoder *d, frame *f, want_t *w, agc_value *error) {
  switch (f->kind) {
    case FRAME_LIST: *w = want_of(d, f->arg); return true;
    case FRAME_MAP:
      if (f->next & 1) *w = want_of(d, f->arg);
      else *w = (want_t){f->int_keys ? AGC_TYPE_INT : AGC_TYPE_STRING, 0, false};
      return true;
    case FRAME_STRUCT: return read_field_key(d, f, w, error);
    case FRAME_ENUM: *w = want_of(d, f->types ? f->types[f->next] : f->arg); return true;
    default: *w = (want_t){SKIP, 0, false}; return true;
  }
}

/* A text or byte string of the head h: the bytes are checked to be there. */
static bool read_body(decoder *d, const head *h, const uint8_t **body, agc_value *error) {
  if (h->arg > d->len - d->at) {
    *error = fail(d, "unexpected end of data", NULL, 0);
    return false;
  }
  *body = d->data + d->at;
  d->at += (size_t)h->arg;
  return true;
}

static bool canonical_nan(const head *h) {
  if (h->info == 27) return h->arg == UINT64_C(0x7FF8000000000000);
  return h->arg == UINT32_C(0x7FC00000);
}

static bool is_nan(const head *h) {
  if (h->info == 27) return (h->arg & UINT64_C(0x7FF0000000000000)) == UINT64_C(0x7FF0000000000000) &&
                            (h->arg & UINT64_C(0x000FFFFFFFFFFFFF)) != 0;
  return (h->arg & UINT32_C(0x7F800000)) == UINT32_C(0x7F800000) && (h->arg & UINT32_C(0x007FFFFF)) != 0;
}

static bool int_of(const head *h, int64_t *n) {
  if ((h->major != 0 && h->major != 1) || h->arg > (uint64_t)INT64_MAX) return false;
  *n = h->major == 0 ? (int64_t)h->arg : -1 - (int64_t)h->arg;
  return true;
}

/* The enum of the head h (an array of two items) as a frame, or for a variant with no payload its shared value. */
static bool open_enum(decoder *d, const want_t *w, const head *h, agc_value *v, bool *opened, agc_value *error) {
  const agc_program *p = d->p;
  if (h->major != 4) {
    *error = fail_expected(d, w);
    return false;
  }
  if (h->arg != 2) {
    *error = fail(d, "expected array of 2 items", NULL, 0);
    return false;
  }
  head tag;
  head_status status = read_head(d, &tag);
  if (status != HEAD_OK) {
    *error = fail(d, head_reason(status), NULL, 0);
    return false;
  }
  const uint8_t *name;
  if (tag.major != 3) {
    *error = fail(d, "expected String tag", NULL, 0);
    return false;
  }
  if (!read_body(d, &tag, &name, error)) return false;
  if (!agc_utf8_chars(name, (size_t)tag.arg, &(size_t){0})) {
    *error = fail(d, "invalid UTF-8", NULL, 0);
    return false;
  }
  bool plain = w->kind == AGC_TYPE_ENUM;
  uint32_t first = plain ? p->enums[w->arg].first : p->json_field;
  uint32_t count = plain ? p->enums[w->arg].count : 3;
  const uint32_t *types = plain ? p->enums[w->arg].payload_types : NULL;
  const agc_variant_def *found = NULL;
  size_t offset = 0; /* the payload types of the variants before the one found */
  agc_charge(d->vm, count / 8);
  for (uint32_t k = 0; k < count && !found; k++) {
    const agc_variant_def *candidate = &p->variants[first + k];
    if (same_bytes(candidate->name, name, (size_t)tag.arg)) found = candidate;
    else offset += candidate->arity;
  }
  if (!found) {
    *error = fail(d, "unknown tag ", name, (size_t)tag.arg);
    return false;
  }
  head payload;
  status = read_head(d, &payload);
  if (status != HEAD_OK) {
    *error = fail(d, head_reason(status), NULL, 0);
    return false;
  }
  if (payload.major != 4 || payload.arg != found->arity) {
    char text[48];
    snprintf(text, sizeof text, "expected %u values", (unsigned)found->arity);
    *error = fail(d, text, NULL, 0);
    return false;
  }
  if (!found->arity) {
    *v = agc_enum_value(found->shared);
    return true;
  }
  frame *f = push_frame(d, FRAME_ENUM, w->arg, found->arity);
  f->types = types ? types + offset : NULL;
  f->tagged = agc_new_enum((uint32_t)(found - p->variants), found->arity);
  *opened = true;
  return true;
}

/* A struct of the head h as a frame. */
static void open_struct(decoder *d, const want_t *w, size_t entries) {
  const agc_program *p = d->p;
  uint32_t index = w->kind == AGC_TYPE_INSTANCE ? p->instances[w->arg].struct_index : w->arg;
  const agc_struct_def *def = &p->structs[index];
  frame *f = push_frame(d, FRAME_STRUCT, index, entries * 2);
  f->types = w->kind == AGC_TYPE_INSTANCE ? p->instances[w->arg].field_types : def->field_types;
  f->seen = agc_alloc_atomic(def->count ? def->count : 1);
  memset(f->seen, 0, def->count ? def->count : 1);
  f->record = agc_new_struct(index, def->count);
}

/* Reads the item that w says, or opens it as a frame. READ_VALUE puts the value in *v. READ_NEXT means a frame is open
   and *w is its first child. READ_FAIL puts the error in *v. */
static read_status read_item(decoder *d, want_t *w, agc_value *v) {
  agc_vm *vm = d->vm;
  const agc_program *p = d->p;
  if (w->kind == AGC_TYPE_OPTIONAL) {
    if (d->at >= d->len) {
      *v = fail(d, "unexpected end of data", NULL, 0);
      return READ_FAIL;
    }
    if (d->data[d->at] != 0xF6) {
      push_frame(d, FRAME_OPTIONAL, w->arg, 1);
      *w = want_of(d, w->arg);
      w->nullable = true;
      return READ_NEXT;
    }
  }
  if (++d->items > AGC_TERM_MAX_ITEMS) {
    *v = fail(d, "more than 4000000 values", NULL, 0);
    return READ_FAIL;
  }
  agc_charge(vm, 1);
  head h;
  head_status status = read_head(d, &h);
  if (status != HEAD_OK || h.major == 6) {
    *v = fail(d, status != HEAD_OK ? head_reason(status) : "tags are not allowed", NULL, 0);
    return READ_FAIL;
  }
  int64_t n;
  const uint8_t *body;
  agc_value error;
  switch (w->kind) {
    case AGC_TYPE_OPTIONAL: /* the null that the peek found */
      *v = agc_optional_make(p, false, agc_void());
      return READ_VALUE;
    case AGC_TYPE_INT:
      if (!int_of(&h, &n)) goto mismatch;
      *v = agc_int(n);
      return READ_VALUE;
    case AGC_TYPE_UINT64:
      if (h.major != 0) goto mismatch;
      *v = agc_uint64(h.arg);
      return READ_VALUE;
    case AGC_TYPE_INT8: case AGC_TYPE_INT16: case AGC_TYPE_INT32: case AGC_TYPE_UINT8: case AGC_TYPE_UINT16:
    case AGC_TYPE_UINT32: {
      int64_t least, greatest;
      agc_type_narrow(w->kind, &least, &greatest);
      if (!int_of(&h, &n) || n < least || n > greatest) goto mismatch;
      *v = agc_int(n);
      return READ_VALUE;
    }
    case AGC_TYPE_FLOAT: {
      if (h.major != 7 || h.info != 27) goto mismatch;
      if (is_nan(&h) && !canonical_nan(&h)) {
        *v = fail(d, "NaN is not the canonical one", NULL, 0);
        return READ_FAIL;
      }
      double x;
      memcpy(&x, &h.arg, sizeof x);
      *v = agc_float(x);
      return READ_VALUE;
    }
    case AGC_TYPE_FLOAT32: {
      if (h.major != 7 || h.info != 26) goto mismatch;
      if (is_nan(&h) && !canonical_nan(&h)) {
        *v = fail(d, "NaN is not the canonical one", NULL, 0);
        return READ_FAIL;
      }
      uint32_t bits = (uint32_t)h.arg;
      float x;
      memcpy(&x, &bits, sizeof x);
      *v = agc_float32((double)x);
      return READ_VALUE;
    }
    case AGC_TYPE_BOOL:
      if (h.major != 7 || (h.info != 20 && h.info != 21)) goto mismatch;
      *v = agc_bool(h.info == 21);
      return READ_VALUE;
    case AGC_TYPE_NIL:
      if (h.major != 7 || h.info != 22) goto mismatch;
      *v = agc_nil();
      return READ_VALUE;
    case AGC_TYPE_STRING: {
      size_t chars;
      if (h.major != 3) goto mismatch;
      if (!read_body(d, &h, &body, &error)) goto failed;
      if (!agc_utf8_chars(body, (size_t)h.arg, &chars)) {
        error = fail(d, "invalid UTF-8", NULL, 0);
        goto failed;
      }
      *v = agc_string_value(agc_make_string((const char *)body, (size_t)h.arg, chars));
      return READ_VALUE;
    }
    case AGC_TYPE_BYTES:
      if (h.major != 2) goto mismatch;
      if (!read_body(d, &h, &body, &error)) goto failed;
      *v = agc_bytes_value(agc_make_bytes(body, (size_t)h.arg));
      return READ_VALUE;
    case SKIP:
      if (h.major == 2 || h.major == 3) {
        size_t chars;
        if (!read_body(d, &h, &body, &error)) goto failed;
        if (h.major == 3 && !agc_utf8_chars(body, (size_t)h.arg, &chars)) {
          error = fail(d, "invalid UTF-8", NULL, 0);
          goto failed;
        }
      } else if (h.major == 7 && (h.info == 26 || h.info == 27)) {
        if (is_nan(&h) && !canonical_nan(&h)) {
          error = fail(d, "NaN is not the canonical one", NULL, 0);
          goto failed;
        }
      } else if (h.major == 7 && (h.info < 20 || h.info > 22)) {
        error = fail(d, "unsupported simple value or float", NULL, 0);
        goto failed;
      }
      if (h.major != 4 && h.major != 5) {
        *v = agc_void();
        return READ_VALUE;
      }
      break;
    default:
      if (w->kind == AGC_TYPE_LIST || w->kind == AGC_TYPE_MAP || w->kind == AGC_TYPE_INT_MAP) {
        if (h.major != (w->kind == AGC_TYPE_LIST ? 4 : 5)) goto mismatch;
      } else if (w->kind == AGC_TYPE_STRUCT || w->kind == AGC_TYPE_INSTANCE) {
        if (h.major != 5) goto mismatch;
      }
      break;
  }
  /* A container: an array or map, for a List, a Map, a struct, an enum or a value that no type names. */
  if (w->kind == AGC_TYPE_ENUM || w->kind == AGC_TYPE_JSON_FIELD) {
    if (d->levels >= AGC_TERM_MAX_DEPTH) goto deep;
    bool opened = false;
    if (!open_enum(d, w, &h, v, &opened, &error)) goto failed;
    if (!opened) return READ_VALUE;
    return next_child(d, &d->stack[d->depth - 1], w, &error) ? READ_NEXT : (*v = error, READ_FAIL);
  }
  if (h.major != 4 && h.major != 5) goto mismatch;
  size_t entries = (size_t)h.arg;
  if (h.arg > d->len - d->at || (h.major == 5 && h.arg > (d->len - d->at) / 2)) {
    *v = fail(d, "unexpected end of data", NULL, 0);
    return READ_FAIL;
  }
  if (d->levels >= AGC_TERM_MAX_DEPTH) goto deep;
  size_t children = h.major == 5 ? entries * 2 : entries;
  frame *f;
  if (w->kind == SKIP) {
    f = push_frame(d, FRAME_SKIP, 0, children);
  } else if (w->kind == AGC_TYPE_LIST) {
    f = push_frame(d, FRAME_LIST, w->arg, children);
  } else if (w->kind == AGC_TYPE_MAP || w->kind == AGC_TYPE_INT_MAP) {
    f = push_frame(d, FRAME_MAP, w->arg, children);
    f->int_keys = w->kind == AGC_TYPE_INT_MAP;
  } else {
    open_struct(d, w, entries);
    f = &d->stack[d->depth - 1];
  }
  if (children == 0) {
    agc_value closed;
    bool done = close_frame(d, f, &closed, &error);
    if (!done) goto failed;
    d->depth--;
    d->levels--;
    *v = closed;
    return READ_VALUE;
  }
  return next_child(d, f, w, &error) ? READ_NEXT : (*v = error, READ_FAIL);
mismatch:
  *v = fail_expected(d, w);
  return READ_FAIL;
deep:
  *v = fail(d, "nested deeper than 10000 levels", NULL, 0);
  return READ_FAIL;
failed:
  *v = error;
  return READ_FAIL;
}

agc_value agc_term_decode(agc_vm *vm, const uint8_t *data, size_t len, uint32_t kind, uint32_t type) {
  decoder d = {.vm = vm, .p = vm->rt->program, .data = data, .len = len, .capacity = 16};
  d.stack = agc_alloc(agc_size_mul(d.capacity, sizeof(frame)));
  agc_charge_bytes(vm, len);
  if (len > AGC_TERM_MAX_BYTES) return fail(&d, "larger than 67108864 bytes", NULL, 0);
  want_t w = {kind, type, false};
  for (;;) {
    agc_value v;
    read_status status = read_item(&d, &w, &v);
    if (status == READ_FAIL) return v;
    if (status == READ_NEXT) continue;
    for (;;) {
      if (!d.depth) {
        if (d.at != d.len) return fail(&d, "trailing bytes after the value", NULL, 0);
        return agc_result_value(true, v);
      }
      frame *top = &d.stack[d.depth - 1];
      frame_store(&d, top, v);
      agc_value error;
      if (top->next < top->n) {
        if (!next_child(&d, top, &w, &error)) return error;
        break;
      }
      if (!close_frame(&d, top, &v, &error)) return error;
      d.depth--;
      if (top->kind != FRAME_OPTIONAL) d.levels--;
    }
  }
}

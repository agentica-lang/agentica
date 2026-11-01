/*
 * RegexEngine.search, the matcher of std/regex (docs/future/48-regex.md §48.3, 48c): a Pike VM over the code points
 * of a String, run as a stepper (port.h) so that a long search yields between turns and meets --max-steps. std/regex
 * parses and compiles the pattern; this file runs the compiled program and checks it first, as any caller could pass
 * any lists. Service layer.
 *
 * The program is the one std/regex builds: instruction pc is (ops[pc], xs[pc], ys[pc]), with CHAR code, CLASS index
 * into classes, SPLIT preferred-pc other-pc, JUMP pc, SAVE slot and ASSERT kind; ANY, ANY_NL and MATCH take no
 * operand. A class is a list of sorted, disjoint [low, high] pairs of code points. pc 0 starts a match.
 */
#include "services.h"

#include <stdio.h>
#include <string.h>

enum { OP_CHAR, OP_CLASS, OP_ANY, OP_ANY_NL, OP_SPLIT, OP_JUMP, OP_SAVE, OP_ASSERT, OP_MATCH, OP_COUNT };
enum { BEGIN_TEXT, END_TEXT, BEGIN_LINE, END_LINE, WORD_EDGE, NOT_WORD_EDGE, ASSERT_COUNT };
/* What a search returns: TEST [end] of any match or [] (match?), FIRST the captures of the leftmost-first match or
   [], ALL the captures of every match one after the other (find_all, replace, split). */
enum { MODE_TEST, MODE_FIRST, MODE_ALL, MODE_COUNT };
/* What a skip found (skip) and how a search left off (search_run). */
enum { SKIP_NONE, SKIP_FOUND, SKIP_MORE };
enum { SEARCH_MORE, SEARCH_DONE };

/* std/regex's limits: 10000 instructions after the repetitions are expanded, then SAVE 0, SAVE 1 and MATCH; 256 groups
   and the whole match, two slots each. A class has at most one pair per code point. */
#define RX_MAX_INSTS 10003
#define RX_MAX_CAPS 514
#define RX_MAX_CODE 0x10FFFF
#define RX_MAX_RANGES ((size_t)2 * (RX_MAX_CODE + 1))
/* One STEP of the stepper does at most this much before it charges: characters stepped, instructions visited, and
   bytes skipped while no thread runs. Each instruction visit costs a unit of turn cost per RX_WORK_PER_COST, each
   character one unit and each skipped run of AGC_COST_BYTES bytes one unit. */
#define RX_CHUNK_CHARS 256
#define RX_CHUNK_WORK 4096
#define RX_CHUNK_SKIP 65536
#define RX_WORK_PER_COST 64
#define RX_NO_SLOT UINT32_MAX

typedef struct {
  uint32_t op, x, y;
} rx_inst;

/* A thread list in priority order, each pc at most once: pcs and, when the search keeps groups, ncap captures each. */
typedef struct {
  uint32_t *pc;
  int64_t *caps;
  uint32_t count, cap;
} rx_list;

/* One run of RegexEngine.search, reached only from the task's stepper (no bytecode can name it). Its arrays hold no
   pointers (atomic GC blocks); TEXT keeps the String alive while S points into it. */
typedef struct {
  agc_stepper stepper;
  agc_value text;
  const uint8_t *s;
  size_t len;
  int64_t chars;
  bool ascii;
  uint32_t span;
  int mode;
  rx_inst *code;
  uint32_t n, ncap, keep;
  uint32_t *class_start;
  uint32_t *ranges;
  uint8_t *class_ascii;
  /* Where a match may start: only at 0 (ANCHORED), after a newline (LINE_START), at PREFIX, or at a character of
     FIRST (the ASCII codes, and 128 for any other) when HAS_FIRST. */
  bool anchored, line_start, has_first;
  uint8_t first[129];
  uint8_t *prefix;
  size_t prefix_len;
  rx_list lists[2];
  int cur;
  uint32_t *marks, gen;
  uint32_t *stack_pc, *stack_slot;
  int64_t *stack_val;
  int64_t *work;
  /* The search in progress: at character Q (byte B), PREV the character before it and C the one at it (-1 past the
     ends), CLEN the bytes of C. FOUND holds the captures of the best match so far, FOUND_END and FOUND_BYTE where it
     ended. */
  bool searching, matched, done;
  int64_t q, found_end;
  size_t b, clen, found_byte;
  int32_t prev, c;
  int64_t *found;
  /* ALL: where the next search starts, and where the last match ended (-1 before the first). */
  int64_t pos, prev_end;
  size_t pos_byte;
  /* The Ints of the result so far (a list builder needs its final size first). */
  int64_t *res;
  size_t res_len, res_cap;
  agc_value result;
  uint64_t chars_done, work_done, skipped;
} rx_run;

static _Noreturn void refuse(agc_vm *vm, const char *what, uint32_t span) {
  char message[160];
  snprintf(message, sizeof message, "RegexEngine.search: %s", what);
  agc_fail(vm, "RUNTIME-INTERNAL", message, span);
}

/* The character at byte B and its length, or -1 at the end. A String is valid UTF-8; a byte that does not start a
   whole sequence still reads as one character of its own value, so no read leaves the text. */
static int32_t decode(const rx_run *r, size_t b, size_t *len) {
  if (b >= r->len) {
    *len = 0;
    return -1;
  }
  const uint8_t *s = r->s + b;
  uint8_t c0 = s[0];
  size_t need = c0 < 0x80 ? 1 : c0 >= 0xF0 ? 4 : c0 >= 0xE0 ? 3 : c0 >= 0xC0 ? 2 : 1;
  if (need > r->len - b) need = 1;
  for (size_t k = 1; k < need; k++)
    if ((s[k] & 0xC0) != 0x80) need = 1;
  *len = need;
  switch (need) {
    case 2: return (int32_t)(((c0 & 0x1F) << 6) | (s[1] & 0x3F));
    case 3: return (int32_t)(((c0 & 0x0F) << 12) | ((s[1] & 0x3F) << 6) | (s[2] & 0x3F));
    case 4: return (int32_t)(((c0 & 0x07) << 18) | ((s[1] & 0x3F) << 12) | ((s[2] & 0x3F) << 6) | (s[3] & 0x3F));
    default: return c0;
  }
}

static bool continuation(const rx_run *r, size_t b) { return !r->ascii && b < r->len && (r->s[b] & 0xC0) == 0x80; }

/* The character that ends just before byte B (B > 0). */
static int32_t char_before(const rx_run *r, size_t b) {
  size_t at = b - 1;
  for (int k = 0; k < 3 && at > 0 && continuation(r, at); k++) at--;
  size_t len;
  return decode(r, at, &len);
}

static bool word_char(int32_t c) {
  return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || c == '_' || (c >= 'a' && c <= 'z');
}

static bool holds(uint32_t kind, int64_t at, int32_t before, int32_t after) {
  switch (kind) {
    case BEGIN_TEXT: return at == 0;
    case END_TEXT: return after < 0;
    case BEGIN_LINE: return before < 0 || before == '\n';
    case END_LINE: return after < 0 || after == '\n';
    case WORD_EDGE: return word_char(before) != word_char(after);
    default: return word_char(before) == word_char(after);
  }
}

static bool in_class(const rx_run *r, uint32_t k, int32_t c) {
  if (c < 0) return false;
  if (c < 128) return (r->class_ascii[k * 16 + (uint32_t)c / 8] >> (c % 8)) & 1;
  uint32_t lo = r->class_start[k] / 2, hi = r->class_start[k + 1] / 2;
  while (lo < hi) {
    uint32_t mid = lo + (hi - lo) / 2;
    if ((uint32_t)c < r->ranges[(size_t)2 * mid])
      hi = mid;
    else if ((uint32_t)c > r->ranges[(size_t)2 * mid + 1])
      lo = mid + 1;
    else
      return true;
  }
  return false;
}

/* The next generation of marks: a pc is in the list being built when marks[pc] == gen. */
static void next_gen(rx_run *r) {
  if (++r->gen == 0) {
    memset(r->marks, 0, r->n * sizeof *r->marks);
    r->gen = 1;
  }
}

static void push_thread(rx_run *r, rx_list *l, uint32_t pc) {
  if (l->count == l->cap) {
    /* Each pc is at most once in a list, so a list never holds more than n threads. */
    uint32_t cap = l->cap ? l->cap * 2 : 16;
    if (cap > r->n) cap = r->n;
    uint32_t *pcs = agc_alloc_atomic(agc_size_mul(cap, sizeof *pcs));
    if (l->count) memcpy(pcs, l->pc, l->count * sizeof *pcs);
    l->pc = pcs;
    if (r->keep) {
      int64_t *caps = agc_alloc_atomic(agc_size_mul(agc_size_mul(cap, r->keep), sizeof *caps));
      if (l->count) memcpy(caps, l->caps, (size_t)l->count * r->keep * sizeof *caps);
      l->caps = caps;
    }
    l->cap = cap;
  }
  l->pc[l->count] = pc;
  if (r->keep) memcpy(l->caps + (size_t)l->count * r->keep, r->work, r->keep * sizeof *r->work);
  l->count++;
}

/* Adds the thread at PC0 with the captures in r->work to L, the list of position AT (BEFORE and AFTER the characters
   around it), following SPLIT (preferred branch first), JUMP, SAVE and ASSERT at once, so the list keeps priority
   order. A SAVE writes r->work and pushes the old value, which comes back before the other branch of a SPLIT runs.
   Without groups (TEST) a thread that reaches MATCH ends the search: true. */
static bool add_thread(rx_run *r, rx_list *l, uint32_t pc0, int64_t at, int32_t before, int32_t after) {
  uint32_t top = 0;
  r->stack_pc[top] = pc0;
  r->stack_slot[top++] = RX_NO_SLOT;
  while (top) {
    top--;
    if (r->stack_slot[top] != RX_NO_SLOT) {
      r->work[r->stack_slot[top]] = r->stack_val[top];
      continue;
    }
    uint32_t pc = r->stack_pc[top];
    while (r->marks[pc] != r->gen) {
      r->marks[pc] = r->gen;
      r->work_done++;
      const rx_inst *in = &r->code[pc];
      if (in->op == OP_JUMP) {
        pc = in->x;
      } else if (in->op == OP_SPLIT) {
        r->stack_pc[top] = in->y;
        r->stack_slot[top++] = RX_NO_SLOT;
        pc = in->x;
      } else if (in->op == OP_SAVE) {
        if (r->keep) {
          r->stack_slot[top] = in->x;
          r->stack_val[top++] = r->work[in->x];
          r->work[in->x] = at;
        }
        pc++;
      } else if (in->op == OP_ASSERT) {
        if (!holds(in->x, at, before, after)) break;
        pc++;
      } else {
        if (in->op == OP_MATCH && !r->keep) return true;
        push_thread(r, l, pc);
        break;
      }
    }
  }
  return false;
}

static void move_to(rx_run *r, size_t target) {
  if (target == r->b) return;
  int64_t count = 0;
  if (r->ascii) {
    count = (int64_t)(target - r->b);
  } else {
    for (size_t k = r->b; k < target; k++) count += (r->s[k] & 0xC0) != 0x80;
  }
  r->skipped += target - r->b;
  r->q += count;
  r->b = target;
  r->prev = char_before(r, target);
  r->c = decode(r, target, &r->clen);
  next_gen(r);
}

/* The first character boundary at or after byte B. */
static size_t boundary(const rx_run *r, size_t b) {
  while (continuation(r, b)) b++;
  return b;
}

/* With no thread running, moves to the next place a match may start: FOUND there, NONE when no place is left, MORE
   after RX_CHUNK_SKIP bytes with the scan not done (the state is at a character boundary on the way). */
static int skip(rx_run *r) {
  size_t from = r->b, limit = r->len - from > RX_CHUNK_SKIP ? from + RX_CHUNK_SKIP : r->len;
  if (r->line_start && r->prev >= 0 && r->prev != '\n') {
    const uint8_t *nl = memchr(r->s + from, '\n', limit - from);
    if (nl) {
      move_to(r, (size_t)(nl - r->s) + 1);
      return SKIP_FOUND;
    }
    if (limit == r->len) return SKIP_NONE;
    move_to(r, boundary(r, limit));
    return SKIP_MORE;
  }
  if (r->prefix_len) {
    size_t stop = limit + r->prefix_len - 1 < r->len ? limit + r->prefix_len - 1 : r->len;
    for (size_t at = from; at + r->prefix_len <= stop;) {
      const uint8_t *hit = memchr(r->s + at, r->prefix[0], stop - r->prefix_len + 1 - at);
      if (!hit) break;
      at = (size_t)(hit - r->s);
      if (memcmp(hit, r->prefix, r->prefix_len) == 0) {
        move_to(r, at);
        return SKIP_FOUND;
      }
      at++;
    }
    if (stop == r->len) return SKIP_NONE;
    move_to(r, boundary(r, limit));
    return SKIP_MORE;
  }
  if (!r->has_first) return SKIP_FOUND;
  for (size_t at = from; at < limit; at++) {
    uint8_t byte = r->s[at];
    if (byte < 0x80 ? r->first[byte] : byte >= 0xC0 && r->first[128]) {
      move_to(r, at);
      return SKIP_FOUND;
    }
  }
  /* A first set means no match is empty, so the end of the text starts none. */
  if (limit == r->len) return SKIP_NONE;
  move_to(r, boundary(r, limit));
  return SKIP_MORE;
}

/* Whether a match may start at the current position, while other threads run. */
static bool may_start(const rx_run *r) {
  if (r->anchored && r->q > 0) return false;
  if (r->line_start && r->prev >= 0 && r->prev != '\n') return false;
  if (!r->has_first) return true;
  if (r->c < 0) return false;
  return r->c < 128 ? r->first[r->c] : r->first[128];
}

static void search_begin(rx_run *r, int64_t q, size_t b) {
  r->q = q;
  r->b = b;
  r->prev = q == 0 ? -1 : char_before(r, b);
  r->c = decode(r, b, &r->clen);
  r->lists[r->cur].count = 0;
  r->matched = false;
  r->searching = true;
  next_gen(r);
}

static void reset_work(rx_run *r) {
  for (uint32_t k = 0; k < r->keep; k++) r->work[k] = -1;
}

static bool chunk_spent(const rx_run *r) {
  return r->chars_done >= RX_CHUNK_CHARS || r->work_done >= RX_CHUNK_WORK || r->skipped >= RX_CHUNK_SKIP;
}

/* Runs the search until it ends (DONE: r->matched says whether it found a match) or the chunk's work is spent. One
   pass of the loop is one position: a new attempt at it, while nothing has matched, then every thread over its
   character into the next list. A thread at MATCH ends the threads after it (leftmost-first). */
static int search_run(rx_run *r) {
  for (;;) {
    rx_list *cl = &r->lists[r->cur];
    if (!r->matched) {
      if (cl->count == 0) {
        if (r->anchored && r->q > 0) return SEARCH_DONE;
        int s = skip(r);
        if (s == SKIP_NONE) return SEARCH_DONE;
        /* A skip that found a place after the chunk's bytes are spent finds it again at once on the next resume. */
        if (s == SKIP_MORE || r->skipped >= RX_CHUNK_SKIP) return SEARCH_MORE;
      }
      if (cl->count == 0 || may_start(r)) {
        reset_work(r);
        if (add_thread(r, cl, 0, r->q, r->prev, r->c)) {
          r->matched = true;
          r->found_end = r->q;
          r->found_byte = r->b;
          return SEARCH_DONE;
        }
      }
    }
    /* With no thread left, the search ends once it has matched or read the whole text; else it moves on. */
    if (cl->count == 0 && (r->matched || r->c < 0)) return SEARCH_DONE;
    size_t next_len;
    int32_t next = decode(r, r->b + r->clen, &next_len);
    next_gen(r);
    rx_list *nl = &r->lists[1 - r->cur];
    nl->count = 0;
    for (uint32_t i = 0; i < cl->count; i++) {
      uint32_t pc = cl->pc[i];
      const rx_inst *in = &r->code[pc];
      r->work_done++;
      bool moves;
      switch (in->op) {
        case OP_CHAR: moves = r->c == (int32_t)in->x; break;
        case OP_CLASS: moves = in_class(r, in->x, r->c); break;
        case OP_ANY: moves = r->c >= 0 && r->c != '\n'; break;
        case OP_ANY_NL: moves = r->c >= 0; break;
        default:
          /* MATCH: the best match so far; the threads after it have lower priority. Only a search that keeps
             groups lists it (add_thread ends the others there). */
          if (r->keep) memcpy(r->found, cl->caps + (size_t)i * r->keep, r->keep * sizeof *r->found);
          r->matched = true;
          r->found_end = r->q;
          r->found_byte = r->b;
          moves = false;
          i = cl->count;
          break;
      }
      if (!moves) continue;
      if (r->keep) memcpy(r->work, cl->caps + (size_t)i * r->keep, r->keep * sizeof *r->work);
      if (add_thread(r, nl, pc + 1, r->q + 1, r->c, next)) {
        r->matched = true;
        r->found_end = r->q + 1;
        r->found_byte = r->b + r->clen;
        return SEARCH_DONE;
      }
    }
    r->cur = 1 - r->cur;
    if (r->c < 0) return SEARCH_DONE;
    r->q++;
    r->b += r->clen;
    r->prev = r->c;
    r->c = next;
    r->clen = next_len;
    r->chars_done++;
    if (chunk_spent(r)) return SEARCH_MORE;
  }
}

static void push_result(rx_run *r, const int64_t *items, size_t count) {
  if (r->res_cap - r->res_len < count) {
    size_t cap = r->res_cap ? r->res_cap : 16;
    while (cap - r->res_len < count) cap = agc_size_mul(cap, 2);
    int64_t *res = agc_alloc_atomic(agc_size_mul(cap, sizeof *res));
    if (r->res_len) memcpy(res, r->res, r->res_len * sizeof *res);
    r->res = res;
    r->res_cap = cap;
  }
  memcpy(r->res + r->res_len, items, count * sizeof *items);
  r->res_len += count;
}

static void push_caps(rx_run *r) { push_result(r, r->found, r->keep); }

static agc_value finish(rx_run *r) {
  r->done = true;
  agc_list_builder out;
  agc_list_builder_sized(&out, r->res_len);
  for (size_t k = 0; k < r->res_len; k++) agc_list_builder_push(&out, agc_int(r->res[k]));
  return agc_list_value(agc_list_builder_finish(&out));
}

/* Advances the run by one chunk of work. True when it is over, with its value in r->result. */
static bool advance(rx_run *r) {
  r->chars_done = r->work_done = r->skipped = 0;
  for (;;) {
    if (!r->searching) {
      if (r->pos > r->chars) {
        r->result = finish(r);
        return true;
      }
      search_begin(r, r->pos, r->pos_byte);
    }
    if (search_run(r) == SEARCH_MORE) return false;
    r->searching = false;
    if (!r->matched || r->mode != MODE_ALL) {
      if (r->matched && r->mode == MODE_TEST) push_result(r, &r->found_end, 1);
      if (r->matched && r->mode == MODE_FIRST) push_caps(r);
      r->result = finish(r);
      return true;
    }
    /* Go's rules: after an empty match the next search starts one character on, and an empty match right where the
       last match ended is dropped. The end is where MATCH ran, so the next search always starts further on. */
    if (r->found_end == r->pos) {
      if (r->found[0] != r->prev_end) push_caps(r);
      size_t len = 1;
      if (r->pos_byte < r->len) decode(r, r->pos_byte, &len);
      r->pos_byte += r->pos_byte < r->len ? len : 0;
      r->pos++;
    } else {
      push_caps(r);
      r->pos = r->found_end;
      r->pos_byte = r->found_byte;
    }
    r->prev_end = r->found_end;
    r->work_done += r->keep;
    /* The next search starts on the next resume once the chunk is spent, so many short matches stay bounded too. */
    if (chunk_spent(r)) return false;
  }
}

static agc_step regex_step(agc_vm *vm, agc_stepper *self, agc_value last) {
  (void)last;
  rx_run *r = (rx_run *)self;
  for (;;) {
    bool over = advance(r);
    agc_charge(vm, r->chars_done + r->work_done / RX_WORK_PER_COST + r->skipped / AGC_COST_BYTES);
    if (over) {
      agc_turn_charge(vm);
      return (agc_step){.kind = AGC_STEP_END, .value = r->result};
    }
    /* Both run: the charge must not be skipped when the step count ends the turn first. */
    bool charged = agc_turn_charge(vm);
    if (agc_step_turn(vm, r->span) || charged) return (agc_step){.kind = AGC_STEP_YIELD};
  }
}

/* The items of an Int list, each checked to lie in [low, high]. */
static uint32_t *int_items(agc_vm *vm, agc_value v, size_t n, int64_t low, int64_t high, uint32_t span) {
  const agc_list *l = agc_as_list(vm, v);
  if (agc_list_len(l) != n) refuse(vm, "the instruction lists differ in length", span);
  agc_value *items = agc_alloc(agc_size_mul(n ? n : 1, sizeof *items));
  agc_list_to_array(l, items);
  uint32_t *out = agc_alloc_atomic(agc_size_mul(n ? n : 1, sizeof *out));
  for (size_t k = 0; k < n; k++) {
    int64_t i = agc_as_int(vm, items[k]);
    if (i < low || i > high) refuse(vm, "an operand is out of range", span);
    out[k] = (uint32_t)i;
  }
  return out;
}

static void load_classes(agc_vm *vm, rx_run *r, agc_value v, uint32_t span) {
  const agc_list *l = agc_as_list(vm, v);
  size_t count = agc_list_len(l);
  if (count > RX_MAX_INSTS) refuse(vm, "too many classes", span);
  agc_value *lists = agc_alloc(agc_size_mul(count ? count : 1, sizeof *lists));
  agc_list_to_array(l, lists);
  size_t total = 0;
  for (size_t k = 0; k < count; k++) {
    size_t size = agc_list_len(agc_as_list(vm, lists[k]));
    if (size % 2 || size > RX_MAX_RANGES || total + size > RX_MAX_RANGES) refuse(vm, "a class is malformed", span);
    total += size;
  }
  r->class_start = agc_alloc_atomic(agc_size_mul(count + 1, sizeof *r->class_start));
  r->ranges = agc_alloc_atomic(agc_size_mul(total ? total : 1, sizeof *r->ranges));
  r->class_ascii = agc_alloc_atomic(agc_size_mul(count ? count : 1, 16));
  memset(r->class_ascii, 0, (count ? count : 1) * 16);
  size_t at = 0;
  for (size_t k = 0; k < count; k++) {
    r->class_start[k] = (uint32_t)at;
    size_t size = agc_list_len(agc_as_list(vm, lists[k]));
    uint32_t *pairs = int_items(vm, lists[k], size, 0, RX_MAX_CODE, span);
    for (size_t p = 0; p < size; p += 2) {
      if (pairs[p] > pairs[p + 1] || (p && pairs[p] <= pairs[p - 1])) refuse(vm, "a class is malformed", span);
      for (uint32_t c = pairs[p]; c <= pairs[p + 1] && c < 128; c++) r->class_ascii[k * 16 + c / 8] |= 1u << (c % 8);
      r->ranges[at++] = pairs[p];
      r->ranges[at++] = pairs[p + 1];
    }
  }
  r->class_start[count] = (uint32_t)at;
}

/* The program checked, in r: every operand in range, and no instruction but MATCH as the last, so every pc that a
   thread reaches is an instruction. */
static void load_program(agc_vm *vm, rx_run *r, agc_value *args, uint32_t span) {
  const agc_list *ops = agc_as_list(vm, args[1]);
  size_t n = agc_list_len(ops);
  if (n == 0 || n > RX_MAX_INSTS) refuse(vm, "the program is empty or too long", span);
  int64_t ncap = agc_as_int(vm, args[5]);
  if (ncap < 2 || ncap > RX_MAX_CAPS || ncap % 2) refuse(vm, "the number of captures is out of range", span);
  load_classes(vm, r, args[4], span);
  uint32_t classes = (uint32_t)agc_list_len(agc_as_list(vm, args[4]));
  uint32_t *op = int_items(vm, args[1], n, 0, OP_COUNT - 1, span);
  uint32_t *x = int_items(vm, args[2], n, 0, RX_MAX_CODE, span);
  uint32_t *y = int_items(vm, args[3], n, 0, RX_MAX_CODE, span);
  r->n = (uint32_t)n;
  r->ncap = (uint32_t)ncap;
  r->code = agc_alloc_atomic(agc_size_mul(n, sizeof *r->code));
  for (uint32_t pc = 0; pc < n; pc++) {
    bool ok = true;
    switch (op[pc]) {
      case OP_CLASS: ok = x[pc] < classes; break;
      case OP_SPLIT: ok = x[pc] < n && y[pc] < n; break;
      case OP_JUMP: ok = x[pc] < n; break;
      case OP_SAVE: ok = x[pc] < (uint32_t)ncap; break;
      case OP_ASSERT: ok = x[pc] < ASSERT_COUNT; break;
      default: break;
    }
    /* Every instruction but SPLIT, JUMP and MATCH goes on to pc + 1. */
    if (op[pc] != OP_SPLIT && op[pc] != OP_JUMP && op[pc] != OP_MATCH && pc + 1 >= n) ok = false;
    if (!ok) refuse(vm, "an operand is out of range", span);
    r->code[pc] = (rx_inst){op[pc], x[pc], y[pc]};
  }
}

/* The places where a match may start (rx_run), from the instructions that start it: the SAVEs and ASSERTs at pc 0,
   then the CHARs in a row past SAVEs (the prefix), else the characters the first consuming instructions take. */
static void load_starts(rx_run *r) {
  uint32_t pc = 0;
  while (r->code[pc].op == OP_SAVE || r->code[pc].op == OP_ASSERT) {
    if (r->code[pc].op == OP_ASSERT && r->code[pc].x == BEGIN_TEXT) r->anchored = true;
    if (r->code[pc].op == OP_ASSERT && r->code[pc].x == BEGIN_LINE) r->line_start = true;
    pc++;
  }
  size_t length = 0;
  for (uint32_t k = pc; r->code[k].op == OP_SAVE || r->code[k].op == OP_CHAR; k++)
    if (r->code[k].op == OP_CHAR) length += r->code[k].x < 0x80 ? 1 : r->code[k].x < 0x800 ? 2 : r->code[k].x < 0x10000 ? 3 : 4;
  r->prefix = agc_alloc_atomic(length ? length : 1);
  for (uint32_t k = pc; r->code[k].op == OP_SAVE || r->code[k].op == OP_CHAR; k++) {
    uint32_t c = r->code[k].x;
    if (r->code[k].op != OP_CHAR) continue;
    uint8_t *o = r->prefix + r->prefix_len;
    if (c < 0x80) {
      o[0] = (uint8_t)c;
      r->prefix_len += 1;
    } else if (c < 0x800) {
      o[0] = (uint8_t)(0xC0 | c >> 6);
      o[1] = (uint8_t)(0x80 | (c & 0x3F));
      r->prefix_len += 2;
    } else if (c < 0x10000) {
      o[0] = (uint8_t)(0xE0 | c >> 12);
      o[1] = (uint8_t)(0x80 | ((c >> 6) & 0x3F));
      o[2] = (uint8_t)(0x80 | (c & 0x3F));
      r->prefix_len += 3;
    } else {
      o[0] = (uint8_t)(0xF0 | c >> 18);
      o[1] = (uint8_t)(0x80 | ((c >> 12) & 0x3F));
      o[2] = (uint8_t)(0x80 | ((c >> 6) & 0x3F));
      o[3] = (uint8_t)(0x80 | (c & 0x3F));
      r->prefix_len += 4;
    }
  }
  /* The first set: every character an instruction reached from pc 0 by empty moves takes; none when such a way
     reaches MATCH or ANY_NL, or when every character is in it. */
  next_gen(r);
  uint32_t top = 0;
  r->stack_pc[top++] = 0;
  r->has_first = true;
  memset(r->first, 0, sizeof r->first);
  while (top && r->has_first) {
    uint32_t at = r->stack_pc[--top];
    if (r->marks[at] == r->gen) continue;
    r->marks[at] = r->gen;
    const rx_inst *in = &r->code[at];
    switch (in->op) {
      case OP_SPLIT:
        r->stack_pc[top++] = in->y;
        r->stack_pc[top++] = in->x;
        break;
      case OP_JUMP: r->stack_pc[top++] = in->x; break;
      case OP_SAVE:
      case OP_ASSERT: r->stack_pc[top++] = at + 1; break;
      case OP_CHAR: r->first[in->x < 128 ? in->x : 128] = 1; break;
      case OP_CLASS:
        for (uint32_t c = 0; c < 128; c++) r->first[c] |= (r->class_ascii[in->x * 16 + c / 8] >> (c % 8)) & 1;
        if (r->class_start[in->x + 1] > r->class_start[in->x] &&
            r->ranges[r->class_start[in->x + 1] - 1] >= 128)
          r->first[128] = 1;
        break;
      case OP_ANY: {
        /* Every character but a newline; a newline another way takes stays in. */
        uint8_t newline = r->first['\n'];
        memset(r->first, 1, sizeof r->first);
        r->first['\n'] = newline;
        break;
      }
      default: r->has_first = false; break;
    }
  }
  bool all = true;
  for (size_t c = 0; c < sizeof r->first; c++) all = all && r->first[c];
  if (all) r->has_first = false;
}

/* RegexEngine.search(text, ops, xs, ys, classes, ncap, mode): the stepper of one search (MODE_TEST, MODE_FIRST) or of
   every match (MODE_ALL), with the captures as character indexes, -1 for a group that did not take part. */
static agc_value builtin_search(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_string *text = agc_as_string(vm, args[0]);
  int64_t mode = agc_as_int(vm, args[6]);
  if (mode < 0 || mode >= MODE_COUNT) refuse(vm, "the mode is out of range", span);
  rx_run *r = agc_alloc(sizeof *r);
  r->text = args[0];
  r->s = (const uint8_t *)text->data;
  r->len = text->bytes;
  r->chars = (int64_t)text->chars;
  r->ascii = text->bytes == text->chars;
  r->span = span;
  r->mode = (int)mode;
  load_program(vm, r, args, span);
  r->keep = mode == MODE_TEST ? 0 : r->ncap;
  size_t n = r->n;
  r->marks = agc_alloc_atomic(agc_size_mul(n, sizeof *r->marks));
  memset(r->marks, 0, n * sizeof *r->marks);
  /* A pass of add_thread pushes the first entry and at most one per instruction it visits, each at most once;
     load_starts pushes two per SPLIT. */
  r->stack_pc = agc_alloc_atomic(agc_size_mul(2 * n + 2, sizeof *r->stack_pc));
  r->stack_slot = agc_alloc_atomic(agc_size_mul(n + 1, sizeof *r->stack_slot));
  r->stack_val = agc_alloc_atomic(agc_size_mul(n + 1, sizeof *r->stack_val));
  r->work = agc_alloc_atomic(agc_size_mul(r->ncap, sizeof *r->work));
  r->found = agc_alloc_atomic(agc_size_mul(r->ncap, sizeof *r->found));
  load_starts(r);
  r->prev_end = -1;
  agc_charge(vm, (n + r->class_start[agc_list_len(agc_as_list(vm, args[4]))] / 2) / RX_WORK_PER_COST);
  r->stepper.step = regex_step;
  /* The step reads the immutable text and writes only this run, which belongs to the calling task. */
  r->stepper.unlocked = true;
  r->stepper.no_block = true;
  agc_task_stepper(vm, &r->stepper);
  return agc_void();
}

const agc_builtin agc_regex_builtins[] = {
  {"RegexEngine.search", 7, builtin_search, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false},
};

const size_t agc_regex_builtin_count = sizeof agc_regex_builtins / sizeof agc_regex_builtins[0];

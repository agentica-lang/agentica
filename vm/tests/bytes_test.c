/*
 * The Bytes value: equality, the Map key hash, the text forms, the JSON
 * refusal, the shared empty value, every builtin with good and bad arguments,
 * bounds, the size overflow guard, values that live through a collection, and
 * the two keys of each crypto builtin (vm/crypto.c).
 */
#include "../core.h"
#include "../services.h"

#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>
#ifndef _WIN32
#include <sys/wait.h>
#include <unistd.h>
#endif

static agc_vm vm;

/* The row as the loader finds it, by key and arity. */
static const agc_builtin *row(const char *name, uint32_t arity) {
  const agc_builtin *b = agc_find_builtin((const uint8_t *)name, strlen(name), arity);
  if (!b) fprintf(stderr, "no builtin %s/%u\n", name, arity);
  assert(b);
  return b;
}

static agc_value call(const char *name, uint32_t arity, agc_value *args) { return row(name, arity)->fn(&vm, args, 0); }

static void fails(const char *name, uint32_t arity, agc_value *args, const char *code) {
  const agc_builtin *b = row(name, arity);
  const char *got = "nothing";
  if (setjmp(vm.fail) == 0)
    (void)b->fn(&vm, args, 0);
  else
    got = vm.outcome->code;
  if (strcmp(got, code) != 0) fprintf(stderr, "%s/%u: got %s, expected %s\n", name, arity, got, code);
  assert(strcmp(got, code) == 0);
}

static agc_value text(const char *s) { return agc_string_value(agc_make_string(s, strlen(s), strlen(s))); }

static agc_value raw(const char *data, size_t len) {
  return agc_bytes_value(agc_make_bytes((const uint8_t *)data, len));
}

static agc_value ints(const int64_t *items, size_t n) {
  agc_list_builder out;
  agc_list_builder_sized(&out, n);
  for (size_t k = 0; k < n; k++) agc_list_builder_push(&out, agc_int(items[k]));
  return agc_list_value(agc_list_builder_finish(&out));
}

static void bytes_are(agc_value v, const char *data, size_t len) {
  size_t got;
  const uint8_t *p = agc_bytes_data(&vm, v, &got);
  assert(got == len && (len == 0 || memcmp(p, data, len) == 0));
}

static void form_is(const agc_string *s, const char *expected) {
  if (s->bytes != strlen(expected) || memcmp(s->data, expected, s->bytes) != 0 || s->chars != s->bytes) {
    fprintf(stderr, "got \"%.*s\", expected \"%s\"\n", (int)s->bytes, s->data, expected);
    assert(0);
  }
}

static bool shared_empty(agc_value v) { return agc_as_bytes(&vm, v) == agc_empty_bytes(); }

static bool equal(agc_value a, agc_value b) {
  agc_value args[2] = {a, b};
  return agc_as_bool(&vm, call("Bytes.equal", 2, args));
}

/* Same length and same bytes; never the pointer. Bytes.equal (==) and agc_equal (Test.eq) agree. The EQ instruction
   refuses a Bytes (hand-made bytecode: the checker lowers == on Bytes to the builtin), and a Bytes is never equal to a
   String of the same bytes. */
static void test_equality(void) {
  agc_value a = raw("abc", 3), b = raw("abc", 3), c = raw("abd", 3), d = raw("ab", 2), s = text("abc");
  assert(equal(a, b) && !equal(a, c) && !equal(a, d) && !equal(d, a));
  agc_value empty = agc_bytes_value(agc_empty_bytes()), fresh = agc_bytes_value(agc_new_bytes(0));
  assert(equal(empty, fresh) && !equal(empty, d));
  agc_value out;
  assert(agc_op_eq(&vm, &out, &a, &b) == AGC_STATUS_WRONG_TAG);
  assert(agc_op_eq(&vm, &out, &a, &s) == AGC_STATUS_WRONG_TAG);
  assert(agc_equal(&vm, a, b, 0) && !agc_equal(&vm, a, c, 0) && !agc_equal(&vm, a, s, 0));
  agc_value pair[2] = {a, d}, other[2] = {b, raw("ab", 2)};
  assert(agc_equal(&vm, agc_list_value(agc_list_from_array(pair, 2)), agc_list_value(agc_list_from_array(other, 2)), 0));
}

/* A Map key and a Set item: equal Bytes are one key, and a Bytes and a String of the same bytes are two (the tag is
   the hash's domain). */
static void test_keys(void) {
  agc_map *m = agc_map_put(&vm, agc_new_map(), raw("key", 3), agc_int(1));
  m = agc_map_put(&vm, m, text("key"), agc_int(2));
  m = agc_map_put(&vm, m, raw("key", 3), agc_int(3));
  m = agc_map_put(&vm, m, raw("", 0), agc_int(4));
  assert(m->size == 3);
  agc_value v;
  assert(agc_map_get(&vm, m, raw("key", 3), &v) && agc_as_int(&vm, v) == 3);
  assert(agc_map_get(&vm, m, text("key"), &v) && agc_as_int(&vm, v) == 2);
  assert(agc_map_get(&vm, m, agc_bytes_value(agc_new_bytes(0)), &v) && agc_as_int(&vm, v) == 4);
  assert(!agc_map_get(&vm, m, raw("kez", 3), &v));
  assert(agc_key_hash(&vm, raw("key", 3)) == agc_key_hash(&vm, raw("key", 3)));
  assert(agc_key_hash(&vm, raw("key", 3)) != agc_key_hash(&vm, text("key")));
  m = agc_map_delete(&vm, m, raw("key", 3));
  assert(m->size == 2 && !agc_map_get(&vm, m, raw("key", 3), &v));

  agc_value items[4] = {raw("a", 1), raw("b", 1), raw("a", 1), text("a")};
  agc_value list = agc_list_value(agc_list_from_array(items, 4));
  agc_value set = call("Set.new", 1, &list);
  assert(agc_as_set(&vm, set)->size == 3);
  agc_value probe[2] = {set, raw("b", 1)};
  assert(agc_as_bool(&vm, call("Set.include?", 2, probe)));
  agc_value fewer[3] = {raw("b", 1), text("a"), raw("a", 1)};
  agc_value list2 = agc_list_value(agc_list_from_array(fewer, 3));
  assert(agc_equal(&vm, set, call("Set.new", 1, &list2), 0));
}

/* to_s is "<Bytes N>" (the bytes may not be text); inspect, and to_s inside another value, add the first 32 bytes in
   hex and "..." past them. */
static void test_text(void) {
  agc_value abc = raw("abc", 3), empty = agc_bytes_value(agc_empty_bytes());
  form_is(agc_text(&vm, abc), "<Bytes 3>");
  form_is(agc_text(&vm, empty), "<Bytes 0>");
  form_is(agc_debug(&vm, abc), "<Bytes 3 616263>");
  form_is(agc_debug(&vm, empty), "<Bytes 0>");
  form_is(agc_test_text(&vm, abc), "<Bytes 3 616263>");
  agc_string *checked;
  assert(agc_text_checked(&vm, abc, &checked));
  form_is(checked, "<Bytes 3>");
  char data[40];
  for (size_t k = 0; k < sizeof data; k++) data[k] = (char)(k * 7 + 250);
  agc_value long_one = raw(data, sizeof data), exact = raw(data, 32);
  form_is(agc_debug(&vm, long_one), "<Bytes 40 fa01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3...>");
  form_is(agc_debug(&vm, exact), "<Bytes 32 fa01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3>");
  agc_value two[2] = {empty, raw("\x00\xff", 2)};
  agc_value list = agc_list_value(agc_list_from_array(two, 2));
  form_is(agc_text(&vm, list), "[<Bytes 0>, <Bytes 2 00ff>]");
  agc_map *m = agc_map_put(&vm, agc_new_map(), raw("k", 1), abc);
  form_is(agc_debug(&vm, agc_map_value(m)), "{<Bytes 1 6b>: <Bytes 3 616263>}");
  agc_value out;
  assert(agc_op_to_text(&vm, &out, &abc) == AGC_STATUS_OK);
  form_is(agc_as_string(&vm, out), "<Bytes 3>");
}

/* JSON has no byte type: the checker refuses it, and the VM fails hand-made bytecode that gets one through. */
static void json_refused(agc_value v, bool from) {
  if (setjmp(vm.fail) == 0) {
    if (from)
      (void)agc_json_from(&vm, v, 0);
    else
      (void)agc_json_encode(&vm, v, 0);
    assert(!"a Bytes reached JSON");
  }
  assert(strcmp(vm.outcome->code, "RUNTIME-INTERNAL") == 0);
}

static void test_json(void) {
  agc_value b = raw("x", 1);
  agc_value list = agc_list_value(agc_list_from_array(&b, 1));
  agc_value keyed = agc_map_value(agc_map_put(&vm, agc_new_map(), b, agc_int(1)));
  json_refused(b, false);
  json_refused(list, false);
  json_refused(keyed, false);
  json_refused(b, true);
  json_refused(list, true);
  json_refused(keyed, true);
}

static void test_builtins(void) {
  const int64_t good[] = {0, 1, 127, 128, 255};
  agc_value list = ints(good, 5);
  const agc_result *r = agc_as_result(&vm, call("Bytes.from_list", 1, &list));
  assert(r->ok);
  agc_value b = r->value;
  bytes_are(b, "\x00\x01\x7f\x80\xff", 5);
  assert(agc_value_units(b) == 0);
  agc_value back = call("Bytes.to_a", 1, &b);
  assert(agc_equal(&vm, back, list, 0) && agc_list_kind(agc_as_list(&vm, back)) == AGC_T_INT);
  assert(agc_as_int(&vm, call("Bytes.length", 1, &b)) == 5);

  const int64_t bad[][3] = {{1, 256, 2}, {-1, 0, 0}, {0, 0, INT64_MIN}};
  for (size_t k = 0; k < 3; k++) {
    agc_value l = ints(bad[k], 3);
    assert(!agc_as_result(&vm, call("Bytes.from_list", 1, &l))->ok);
  }
  agc_value none = vm.rt->empty_list;
  r = agc_as_result(&vm, call("Bytes.from_list", 1, &none));
  assert(r->ok && shared_empty(r->value));
  agc_value empty = agc_bytes_value(agc_empty_bytes());
  assert(agc_as_list(&vm, call("Bytes.to_a", 1, &empty)) == agc_as_list(&vm, vm.rt->empty_list));

  agc_value at[2] = {b, agc_int(4)};
  assert(agc_as_int(&vm, call("Bytes.at", 2, at)) == 255);
  at[1] = agc_int(0);
  assert(agc_as_int(&vm, call("Bytes.at", 2, at)) == 0);
  const int64_t outside[] = {5, -1, INT64_MIN, INT64_MAX};
  for (size_t k = 0; k < 4; k++) {
    at[1] = agc_int(outside[k]);
    fails("Bytes.at", 2, at, "RUNTIME-INDEX-OUT-OF-RANGE");
  }

  agc_value slice[3] = {b, agc_int(1), agc_int(3)};
  bytes_are(call("Bytes.slice", 3, slice), "\x01\x7f\x80", 3);
  slice[1] = agc_int(5);
  slice[2] = agc_int(0);
  assert(shared_empty(call("Bytes.slice", 3, slice)));
  slice[1] = agc_int(0);
  slice[2] = agc_int(5);
  assert(agc_as_bytes(&vm, call("Bytes.slice", 3, slice)) == agc_as_bytes(&vm, b));
  const int64_t bounds[][2] = {{0, 6}, {6, 0}, {-1, 1}, {1, -1}, {2, INT64_MAX}, {INT64_MAX, 1}, {INT64_MIN, 0}};
  for (size_t k = 0; k < sizeof bounds / sizeof bounds[0]; k++) {
    slice[1] = agc_int(bounds[k][0]);
    slice[2] = agc_int(bounds[k][1]);
    fails("Bytes.slice", 3, slice, "RUNTIME-INDEX-OUT-OF-RANGE");
  }

  agc_value count[2] = {b, agc_int(2)};
  bytes_are(call("Bytes.take", 2, count), "\x00\x01", 2);
  bytes_are(call("Bytes.drop", 2, count), "\x7f\x80\xff", 3);
  count[1] = agc_int(INT64_MAX);
  assert(agc_as_bytes(&vm, call("Bytes.take", 2, count)) == agc_as_bytes(&vm, b));
  assert(shared_empty(call("Bytes.drop", 2, count)));
  count[1] = agc_int(0);
  assert(shared_empty(call("Bytes.take", 2, count)));
  assert(agc_as_bytes(&vm, call("Bytes.drop", 2, count)) == agc_as_bytes(&vm, b));
  count[1] = agc_int(-1);
  fails("Bytes.take", 2, count, "RUNTIME-INVALID-COUNT");
  fails("Bytes.drop", 2, count, "RUNTIME-INVALID-COUNT");

  agc_value plus[2] = {raw("ab", 2), raw("cde", 3)};
  bytes_are(call("Bytes.plus", 2, plus), "abcde", 5);
  plus[1] = empty;
  assert(agc_as_bytes(&vm, call("Bytes.plus", 2, plus)) == agc_as_bytes(&vm, plus[0]));
  plus[1] = plus[0];
  plus[0] = empty;
  assert(agc_as_bytes(&vm, call("Bytes.plus", 2, plus)) == agc_as_bytes(&vm, plus[1]));

  agc_value parts[4] = {raw("ab", 2), empty, raw("c", 1), raw("def", 3)};
  agc_value joined = agc_list_value(agc_list_from_array(parts, 4));
  bytes_are(call("Bytes.concat", 1, &joined), "abcdef", 6);
  agc_value one[2] = {empty, parts[3]};
  agc_value single = agc_list_value(agc_list_from_array(one, 2));
  assert(agc_as_bytes(&vm, call("Bytes.concat", 1, &single)) == agc_as_bytes(&vm, parts[3]));
  assert(shared_empty(call("Bytes.concat", 1, &none)));

  agc_value s = text("h\xc3\xa9");
  bytes_are(call("String.bytes", 1, &s), "h\xc3\xa9", 3);
  agc_value blank = agc_string_value(vm.rt->empty_string);
  assert(shared_empty(call("String.bytes", 1, &blank)));
  char big[640];
  memset(big, 'x', sizeof big);
  assert(agc_value_units(raw(big, sizeof big)) == 10);
}

/* The turn cost each path charges (the call sites add nothing for these rows, which are AGC_COST_NONE): a cut charges
   the bytes it copies, not the parent's size, and nothing when it returns the whole input; a compare and a key hash
   charge len / 64, and a compare of two lengths charges nothing. */
static int64_t cost_of(const char *name, uint32_t arity, agc_value *args) {
  vm.task->turn_cost = 0;
  (void)call(name, arity, args);
  return vm.task->turn_cost;
}

static void test_costs(void) {
  char data[1000];
  memset(data, 7, sizeof data);
  agc_value big = raw(data, sizeof data), same = raw(data, sizeof data), part = raw(data, 640);
  agc_value slice[3] = {big, agc_int(10), agc_int(640)};
  assert(cost_of("Bytes.slice", 3, slice) == 10);
  slice[1] = agc_int(0);
  slice[2] = agc_int(1000);
  assert(cost_of("Bytes.slice", 3, slice) == 0);
  agc_value count[2] = {big, agc_int(128)};
  assert(cost_of("Bytes.take", 2, count) == 2);
  assert(cost_of("Bytes.drop", 2, count) == (1000 - 128) / 64);
  count[1] = agc_int(INT64_MAX);
  assert(cost_of("Bytes.take", 2, count) == 0);
  count[1] = agc_int(0);
  assert(cost_of("Bytes.drop", 2, count) == 0);
  agc_value pair[2] = {big, same};
  assert(cost_of("Bytes.equal", 2, pair) == 1000 / 64);
  pair[1] = part;
  assert(cost_of("Bytes.equal", 2, pair) == 0);
  vm.task->turn_cost = 0;
  assert(agc_same_bytes(&vm, agc_as_bytes(&vm, part), agc_as_bytes(&vm, raw(data, 640))) && vm.task->turn_cost == 10);
  vm.task->turn_cost = 0;
  (void)agc_key_hash(&vm, part);
  assert(vm.task->turn_cost == 10);
  vm.task->turn_cost = 0;
}

/* Hand-made bytecode can pass any value to any builtin: a wrong tag, or a list with an item that is not of its type,
   fails with RUNTIME-INTERNAL. */
static void test_wrong_tags(void) {
  agc_value b = raw("ab", 2), s = text("ab"), i = agc_int(1);
  agc_value one[1] = {s};
  fails("Bytes.to_a", 1, one, "RUNTIME-INTERNAL");
  fails("Bytes.length", 1, one, "RUNTIME-INTERNAL");
  one[0] = b;
  fails("Bytes.from_list", 1, one, "RUNTIME-INTERNAL");
  fails("Bytes.concat", 1, one, "RUNTIME-INTERNAL");
  fails("String.bytes", 1, one, "RUNTIME-INTERNAL");
  agc_value items[2] = {b, s};
  one[0] = agc_list_value(agc_list_from_array(items, 2));
  fails("Bytes.concat", 1, one, "RUNTIME-INTERNAL");
  fails("Bytes.from_list", 1, one, "RUNTIME-INTERNAL");
  agc_value two[2] = {s, i};
  fails("Bytes.at", 2, two, "RUNTIME-INTERNAL");
  fails("Bytes.take", 2, two, "RUNTIME-INTERNAL");
  fails("Bytes.drop", 2, two, "RUNTIME-INTERNAL");
  two[0] = b;
  two[1] = s;
  fails("Bytes.at", 2, two, "RUNTIME-INTERNAL");
  fails("Bytes.take", 2, two, "RUNTIME-INTERNAL");
  fails("Bytes.plus", 2, two, "RUNTIME-INTERNAL");
  two[0] = s;
  two[1] = b;
  fails("Bytes.plus", 2, two, "RUNTIME-INTERNAL");
  fails("Bytes.equal", 2, two, "RUNTIME-INTERNAL");
  agc_value three[3] = {b, i, s};
  fails("Bytes.slice", 3, three, "RUNTIME-INTERNAL");
  three[0] = s;
  three[2] = i;
  fails("Bytes.slice", 3, three, "RUNTIME-INTERNAL");
}

/* What an old List[Int] key answered against what its ".bytes" key answered: a byte list where the new key gives a
   Bytes (inside a Result too), the same value otherwise. */
static void same_answer(agc_value old, agc_value now) {
  if (now.tag == AGC_T_RESULT) {
    const agc_result *a = agc_as_result(&vm, old), *b = agc_as_result(&vm, now);
    assert(a->ok == b->ok);
    old = a->value;
    now = b->value;
  }
  if (now.tag == AGC_T_BYTES) now = call("Bytes.to_a", 1, &now);
  assert(agc_equal(&vm, old, now, 0));
}

/* Calls name with args and name + ".bytes" with the same args, each Bytes argument given to the old key as its list. */
static void both_keys(const char *name, uint32_t arity, const agc_value *args) {
  agc_value old[2], now[2];
  for (uint32_t k = 0; k < arity; k++) {
    now[k] = args[k];
    old[k] = args[k].tag == AGC_T_BYTES ? call("Bytes.to_a", 1, &now[k]) : args[k];
  }
  char key[64];
  snprintf(key, sizeof key, "%s.bytes", name);
  same_answer(call(name, arity, old), call(key, arity, now));
}

/* Each crypto builtin on bytes has the catalog's "<name>.bytes" key on Bytes and the old "<name>" key on byte lists,
   which the checked-in stage0 still imports: both give the same answer. The old key still halts on an item that is
   not a byte (RUNTIME-INVALID-NUMBER); the new key cannot see one, and a list there is a wrong tag. */
static void test_crypto_keys(void) {
  static const char *const one_data[] = {
    "Digest.md5",           "Digest.md5_hexdigest", "Digest.sha1",           "Digest.sha1_hexdigest",
    "Digest.sha256",        "Digest.sha256_hexdigest", "Digest.sha512",      "Digest.sha512_hexdigest",
    "Base64.encode64",      "Base64.strict_encode64", "Digest.hexencode",
  };
  static const char *const one_text[] = {"Base64.decode64", "Base64.strict_decode64", "Base64.urlsafe_decode64",
                                         "Digest.hexdecode"};
  static const char *const two_data[] = {"HMAC.sha256", "HMAC.sha256_hexdigest", "HMAC.sha512",
                                         "HMAC.sha512_hexdigest", "HMAC.secure_compare"};
  agc_value datas[] = {raw("", 0), raw("hello\xff\x00", 7), raw("abc", 3)};
  agc_value texts[] = {text(""), text("aGVsbG8="), text("aGVsbG8"), text("68656C6c6f"), text("not base64!")};
  for (size_t d = 0; d < 3; d++) {
    for (size_t k = 0; k < sizeof one_data / sizeof one_data[0]; k++) both_keys(one_data[k], 1, &datas[d]);
    for (size_t f = 0; f < 2; f++) {
      agc_value args[2] = {datas[d], agc_bool(f)};
      both_keys("Base64.urlsafe_encode64", 2, args);
    }
    for (size_t e = 0; e < 3; e++) {
      agc_value args[2] = {datas[d], datas[e]};
      for (size_t k = 0; k < sizeof two_data / sizeof two_data[0]; k++) both_keys(two_data[k], 2, args);
    }
  }
  for (size_t t = 0; t < sizeof texts / sizeof texts[0]; t++)
    for (size_t k = 0; k < sizeof one_text / sizeof one_text[0]; k++) both_keys(one_text[k], 1, &texts[t]);

  agc_value count = agc_int(33);
  assert(agc_list_len(agc_as_list(&vm, call("SecureRandom.random_bytes", 1, &count))) == 33);
  assert(agc_as_bytes(&vm, call("SecureRandom.random_bytes.bytes", 1, &count))->len == 33);
  count = agc_int(0);
  assert(shared_empty(call("SecureRandom.random_bytes.bytes", 1, &count)));

  const int64_t bad[] = {1, 256};
  agc_value list = ints(bad, 2), pair[2] = {raw("k", 1), list};
  fails("Digest.sha256", 1, &list, "RUNTIME-INVALID-NUMBER");
  fails("Base64.strict_encode64", 1, &list, "RUNTIME-INVALID-NUMBER");
  pair[0] = call("Bytes.to_a", 1, &pair[0]);
  fails("HMAC.sha256", 2, pair, "RUNTIME-INVALID-NUMBER");
  list = call("Bytes.to_a", 1, &datas[2]);
  fails("Digest.sha256.bytes", 1, &list, "RUNTIME-INTERNAL");
  fails("Digest.hexencode.bytes", 1, &list, "RUNTIME-INTERNAL");
  pair[0] = datas[2];
  pair[1] = list;
  fails("HMAC.secure_compare.bytes", 2, pair, "RUNTIME-INTERNAL");
}

/* No pointers inside, so the collector never scans the data: Bytes held only by a list keep their contents through
   collections. */
static void test_collection(void) {
  agc_value held[64];
  for (size_t k = 0; k < 64; k++) {
    char data[100];
    memset(data, (int)k, sizeof data);
    held[k] = raw(data, k + 1);
  }
  agc_list *list = agc_list_from_array(held, 64);
  memset(held, 0, sizeof held);
  for (int round = 0; round < 3; round++) {
    for (size_t k = 0; k < 1000; k++) (void)agc_new_bytes(4096);
    agc_gc_collect();
  }
  for (size_t k = 0; k < 64; k++) {
    size_t len;
    const uint8_t *p = agc_bytes_data(&vm, agc_list_get(list, k), &len);
    assert(len == k + 1);
    for (size_t j = 0; j < len; j++) assert(p[j] == (uint8_t)k);
  }
}

#ifndef _WIN32
/* A size that does not fit ends in the out-of-memory exit (70) in agc_size_add, never in a short block. The
   values are headers with a huge length and no data: the overflow is found before anything reads it. */
static void exits_70(void (*child)(void)) {
  fflush(NULL);
  pid_t pid = fork();
  assert(pid >= 0);
  if (pid == 0) {
    FILE *quiet = tmpfile();
    if (quiet) dup2(fileno(quiet), 2);
    child();
    _exit(0);
  }
  int status = 0;
  assert(waitpid(pid, &status, 0) == pid);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 70);
}

static agc_value huge(void) {
  agc_bytes *b = agc_new_bytes(0);
  b->len = SIZE_MAX / 2 + 1;
  return agc_bytes_value(b);
}

static void new_too_big(void) { (void)agc_new_bytes(SIZE_MAX - 4); }

static void plus_too_big(void) {
  agc_value args[2] = {huge(), huge()};
  (void)call("Bytes.plus", 2, args);
}

static void concat_too_big(void) {
  agc_value parts[2] = {huge(), huge()};
  agc_value list = agc_list_value(agc_list_from_array(parts, 2));
  (void)call("Bytes.concat", 1, &list);
}

static void test_overflow(void) {
  exits_70(new_too_big);
  exits_70(plus_too_big);
  exits_70(concat_too_big);
}
#endif

int main(void) {
  agc_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  assert(agc_empty_bytes()->len == 0);
  test_equality();
  test_keys();
  test_text();
  test_json();
  test_builtins();
  test_wrong_tags();
  test_crypto_keys();
  test_costs();
  test_collection();
#ifndef _WIN32
  test_overflow();
#endif
  return 0;
}

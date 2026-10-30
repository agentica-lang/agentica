/*
 * The Bytes value: equality, the Map key hash, the text forms, the JSON refusal,
 * the shared empty value, every builtin with good and bad arguments, bounds, the
 * size overflow guard, values that live through a collection, the crypto builtins
 * (vm/crypto.c) and GCM's wipe, String.from_bytes and FrontEnd.hand_off on Bytes.
 */
#include "../core.h"
#include "../digest.h"
#include "../services.h"
#include "builtin_test.h"

#include <assert.h>
#include <setjmp.h>
#include <stdio.h>
#include <string.h>
#ifndef _WIN32
#include <sys/wait.h>
#include <unistd.h>
#endif

#ifndef AGC_NO_GC
#include <gc.h>
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
  agc_test_fails(&vm, name, row(name, arity), args, code);
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

/* Each crypto builtin on bytes runs on empty Bytes and on Bytes with a NUL and a 0xFF in them, and a List there is a
   wrong tag (the type cannot give one; only hand-made bytecode can). */
static void test_crypto_keys(void) {
  static const char *const one_data[] = {
    "Digest.md5.bytes",      "Digest.md5_hexdigest.bytes",    "Digest.sha1.bytes",
    "Digest.sha1_hexdigest.bytes", "Digest.sha256.bytes",     "Digest.sha256_hexdigest.bytes",
    "Digest.sha512.bytes",   "Digest.sha512_hexdigest.bytes", "Base64.encode64.bytes",
    "Base64.strict_encode64.bytes", "Digest.hexencode.bytes",
  };
  static const char *const two_data[] = {"HMAC.sha256.bytes", "HMAC.sha256_hexdigest.bytes", "HMAC.sha512.bytes",
                                         "HMAC.sha512_hexdigest.bytes", "HMAC.secure_compare.bytes",
                                         "CMAC.aes", "CMAC.des_ede3"};
  static const char *const three_data[] = {"Cipher.des_ede3_cbc_encrypt", "Cipher.des_ede3_cbc_decrypt"};
  agc_value datas[] = {raw("", 0), raw("hello\xff\x00", 7)};
  for (size_t d = 0; d < 2; d++) {
    for (size_t k = 0; k < sizeof one_data / sizeof one_data[0]; k++) (void)call(one_data[k], 1, &datas[d]);
    agc_value args[2] = {datas[d], datas[1 - d]};
    for (size_t k = 0; k < sizeof two_data / sizeof two_data[0]; k++) (void)call(two_data[k], 2, args);
    /* Neither size is a Triple DES key, IV or block: an error Result. */
    agc_value cipher_args[3] = {datas[d], datas[1 - d], datas[d]};
    for (size_t k = 0; k < sizeof three_data / sizeof three_data[0]; k++)
      assert(!agc_as_result(&vm, call(three_data[k], 3, cipher_args))->ok);
  }
  /* Sizes that fit give ok, and a 0xFF and a NUL in the key are bytes like any other. */
  agc_value key = raw("hello\xff\x00!0123456789abcdef", 24), iv = raw("\x00\xff\x00\xff\x00\xff\x00\xff", 8);
  agc_value cipher_args[3] = {key, iv, raw("\xff\x00\xff\x00\xff\x00\xff\x00", 8)};
  const agc_result *sealed = agc_as_result(&vm, call("Cipher.des_ede3_cbc_encrypt", 3, cipher_args));
  assert(sealed->ok && agc_as_bytes(&vm, sealed->value)->len == 8);
  agc_value cmac_args[2] = {key, datas[1]};
  const agc_result *tag = agc_as_result(&vm, call("CMAC.des_ede3", 2, cmac_args));
  assert(tag->ok && agc_as_bytes(&vm, tag->value)->len == 8);
  agc_value hello = text("aGVsbG8=");
  const agc_result *decoded = agc_as_result(&vm, call("Base64.strict_decode64.bytes", 1, &hello));
  assert(decoded->ok && agc_as_bytes(&vm, decoded->value)->len == 5);

  agc_value count = agc_int(33);
  assert(agc_as_bytes(&vm, call("SecureRandom.random_bytes.bytes", 1, &count))->len == 33);
  count = agc_int(0);
  assert(shared_empty(call("SecureRandom.random_bytes.bytes", 1, &count)));

  agc_value list = call("Bytes.to_a", 1, &datas[1]), pair[2] = {datas[1], list};
  fails("Digest.sha256.bytes", 1, &list, "RUNTIME-INTERNAL");
  fails("Digest.hexencode.bytes", 1, &list, "RUNTIME-INTERNAL");
  fails("HMAC.secure_compare.bytes", 2, pair, "RUNTIME-INTERNAL");
  fails("CMAC.aes", 2, pair, "RUNTIME-INTERNAL");
  agc_value triple[3] = {key, list, datas[1]};
  fails("Cipher.des_ede3_cbc_decrypt", 3, triple, "RUNTIME-INTERNAL");
  agc_value gcm_list[4] = {key, list, datas[1], datas[0]};
  fails("Cipher.aes_256_gcm_encrypt", 4, gcm_list, "RUNTIME-INTERNAL");
  agc_value kdf_list[4] = {list, datas[1], agc_int(1), agc_int(16)};
  fails("KDF.pbkdf2_hmac_sha256", 4, kdf_list, "RUNTIME-INTERNAL");
}

/* AES-256-GCM and the KDFs on empty Bytes and on Bytes with a NUL and a 0xFF: empty data and auth_data are valid,
   a key, IV or decrypt input of a wrong size and a bad iteration count or length are error Results. */
static void test_gcm_and_kdf_keys(void) {
  char key_text[32], iv_text[12];
  memset(key_text, 0xff, sizeof key_text);
  memset(iv_text, 0, sizeof iv_text);
  agc_value key = raw(key_text, 32), iv = raw(iv_text, 12), empty = raw("", 0), odd = raw("hello\xff\x00", 7);
  agc_value args[4] = {key, iv, empty, empty};
  const agc_result *sealed = agc_as_result(&vm, call("Cipher.aes_256_gcm_encrypt", 4, args));
  assert(sealed->ok && agc_as_bytes(&vm, sealed->value)->len == AGC_GCM_TAG_BYTES);
  args[2] = sealed->value;
  const agc_result *opened = agc_as_result(&vm, call("Cipher.aes_256_gcm_decrypt", 4, args));
  assert(opened->ok && shared_empty(opened->value));
  args[3] = odd;
  assert(!agc_as_result(&vm, call("Cipher.aes_256_gcm_decrypt", 4, args))->ok);
  args[2] = odd;
  sealed = agc_as_result(&vm, call("Cipher.aes_256_gcm_encrypt", 4, args));
  assert(sealed->ok && agc_as_bytes(&vm, sealed->value)->len == 7 + AGC_GCM_TAG_BYTES);
  args[2] = sealed->value;
  opened = agc_as_result(&vm, call("Cipher.aes_256_gcm_decrypt", 4, args));
  assert(opened->ok);
  bytes_are(opened->value, "hello\xff\x00", 7);
  /* 15 bytes cannot hold the tag; a key or IV of another size fails before any work. */
  args[2] = raw(key_text, 15);
  assert(!agc_as_result(&vm, call("Cipher.aes_256_gcm_decrypt", 4, args))->ok);
  agc_value bad[4] = {raw(key_text, 31), iv, empty, empty};
  assert(!agc_as_result(&vm, call("Cipher.aes_256_gcm_encrypt", 4, bad))->ok);
  bad[0] = key;
  bad[1] = raw(iv_text, 11);
  assert(!agc_as_result(&vm, call("Cipher.aes_256_gcm_encrypt", 4, bad))->ok);

  agc_value kdf[4] = {empty, empty, agc_int(1), agc_int(1)};
  const agc_result *derived = agc_as_result(&vm, call("KDF.pbkdf2_hmac_sha256", 4, kdf));
  assert(derived->ok && agc_as_bytes(&vm, derived->value)->len == 1);
  kdf[0] = odd;
  kdf[1] = odd;
  kdf[2] = agc_int(0);
  assert(!agc_as_result(&vm, call("KDF.pbkdf2_hmac_sha256", 4, kdf))->ok);
  kdf[2] = agc_int(2);
  kdf[3] = agc_int(0);
  assert(!agc_as_result(&vm, call("KDF.pbkdf2_hmac_sha256", 4, kdf))->ok);
  kdf[3] = agc_int(AGC_MAX_LIST_COUNT + 1);
  assert(!agc_as_result(&vm, call("KDF.pbkdf2_hmac_sha256", 4, kdf))->ok);
  /* Two iterations over two 32-byte blocks hash 2 * 2 * 128 bytes, charged in units of 64 bytes, besides the
     AGC_COST_SIZE that the interpreter adds for the arguments. */
  kdf[3] = agc_int(64);
  assert(cost_of("KDF.pbkdf2_hmac_sha256", 4, kdf) == 8);
  agc_value scrypt[6] = {empty, empty, agc_int(16), agc_int(1), agc_int(1), agc_int(64)};
  derived = agc_as_result(&vm, call("KDF.scrypt", 6, scrypt));
  assert(derived->ok && agc_as_bytes(&vm, derived->value)->len == 64);
  scrypt[2] = agc_int(15);
  assert(!agc_as_result(&vm, call("KDF.scrypt", 6, scrypt))->ok);
  /* r = 1 needs n below 2^16, and r * p must stay below 2^30 (checked before the memory). */
  scrypt[2] = agc_int(65536);
  assert(!agc_as_result(&vm, call("KDF.scrypt", 6, scrypt))->ok);
  scrypt[2] = agc_int(2);
  scrypt[3] = agc_int((int64_t)1 << 20);
  scrypt[4] = agc_int(1024);
  assert(!agc_as_result(&vm, call("KDF.scrypt", 6, scrypt))->ok);
}

/* A GCM decrypt writes the plaintext before it checks the tag: on a wrong tag the adapter wipes it, so no part of it
   is left in the output buffer. */
static void test_gcm_wipes_a_wrong_tag(void) {
  unsigned char key[AGC_GCM_KEY_BYTES], iv[AGC_GCM_IV_BYTES], plain[40], sealed[40], out[40];
  unsigned char tag[AGC_GCM_TAG_BYTES];
  memset(key, 0x42, sizeof key);
  memset(iv, 0x24, sizeof iv);
  memset(plain, 0x5a, sizeof plain);
  assert(agc_aes_256_gcm(true, key, iv, NULL, 0, plain, sizeof plain, sealed, tag) == AGC_AEAD_DONE);
  assert(agc_aes_256_gcm(false, key, iv, NULL, 0, sealed, sizeof sealed, out, tag) == AGC_AEAD_DONE);
  assert(memcmp(out, plain, sizeof plain) == 0);
  tag[0] ^= 1;
  memset(out, 0x5a, sizeof out);
  assert(agc_aes_256_gcm(false, key, iv, NULL, 0, sealed, sizeof sealed, out, tag) == AGC_AEAD_BAD_TAG);
  for (size_t k = 0; k < sizeof out; k++) assert(out[k] == 0);
  /* The tag alone, with no data, is still checked. */
  assert(agc_aes_256_gcm(false, key, iv, NULL, 0, NULL, 0, NULL, tag) == AGC_AEAD_BAD_TAG);
}

/* A key longer than the digest's block is hashed first (vm/digest_openssl.c): RFC 4231 test cases 6 and 7 use a
   131-byte key. A key exactly at the block size (64 for SHA-256, 128 for SHA-512) is used as it is; those answers come
   from Python's hmac. */
static void test_hmac_long_keys(void) {
  static const char case6[] = "Test Using Larger Than Block-Size Key - Hash Key First";
  static const char case7[] = "This is a test using a larger than block-size key and a larger than block-size data. "
                              "The key needs to be hashed before being used by the HMAC algorithm.";
  static const char hi[] = "Hi There";
  static const struct {
    size_t key_n;
    const char *data;
    const char *name;
    const char *mac;
  } cases[] = {
    {131, case6, "HMAC.sha256_hexdigest.bytes", "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"},
    {131, case6, "HMAC.sha512_hexdigest.bytes",
     "80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f352"
     "6b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598"},
    {131, case7, "HMAC.sha256_hexdigest.bytes", "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"},
    {131, case7, "HMAC.sha512_hexdigest.bytes",
     "e37b6a775dc87dbaa4dfa9f96e5e3ffddebd71f8867289865df5a32d20cdc944"
     "b6022cac3c4982b10d5eeb55c3e4de15134676fb6de0446065c97440fa8c6a58"},
    {64, hi, "HMAC.sha256_hexdigest.bytes", "ebef34e13d0a0fe04593d043bc7a865106db0604211d404c18206d862e5d7852"},
    {128, hi, "HMAC.sha512_hexdigest.bytes",
     "17eb09b3d3c0f3ac497c608347e1d5b5df5e4b062bfd56c191c8499f24a3a9d1"
     "c3dfb449d01f4c9ca316b6b8d6a6299bad883d0bffe11c88c60d7daed6feeb48"},
  };
  char key[131];
  memset(key, 0xaa, sizeof key);
  for (size_t k = 0; k < sizeof cases / sizeof cases[0]; k++) {
    agc_value args[2] = {raw(key, cases[k].key_n), raw(cases[k].data, strlen(cases[k].data))};
    form_is(agc_as_string(&vm, call(cases[k].name, 2, args)), cases[k].mac);
  }
}

/* String.from_bytes decodes strictly: valid UTF-8 (a NUL included) gives the String, a cut or a surrogate is an
   error, and a List there is a wrong tag. */
static void test_string_keys(void) {
  struct {
    agc_value data;
    bool ok;
  } samples[] = {{raw("", 0), true},      {raw("h", 1), true},           {raw("caf\xc3\xa9", 5), true},
                 {raw("\xc3", 1), false}, {raw("\xed\xa0\x80", 3), false}, {raw("a\x00b", 3), true}};
  for (size_t k = 0; k < sizeof samples / sizeof samples[0]; k++) {
    const agc_result *r = agc_as_result(&vm, call("String.from_bytes.bytes", 1, &samples[k].data));
    assert(r->ok == samples[k].ok);
    if (r->ok) {
      agc_value decoded = r->value;
      assert(agc_equal(&vm, call("String.bytes", 1, &decoded), samples[k].data, 0));
    }
  }
  agc_value list = call("Bytes.to_a", 1, &samples[2].data);
  fails("String.from_bytes.bytes", 1, &list, "RUNTIME-INTERNAL");
}

/* FrontEnd.hand_off gives the driver the program's bytes. The hand-off ends the run, which comes back here through
   vm.fail. */
static void handed(agc_value program, agc_front_end *fe) {
  agc_value args[3] = {program, vm.rt->empty_list, vm.rt->empty_list};
  memset(fe, 0, sizeof *fe);
  if (setjmp(vm.fail) == 0) {
    (void)row("FrontEnd.hand_off.bytes", 3)->fn(&vm, args, 0);
    assert(0);
  }
  assert(fe->handed && fe->option_count == 0 && fe->argument_count == 0);
}

static void test_hand_off_keys(void) {
  agc_front_end fe;
  vm.rt->front_end = &fe;
  agc_value program = raw("AGCB\x06\x00\xff", 7);
  handed(program, &fe);
  assert(fe.program_len == 7 && memcmp(fe.program, "AGCB\x06\x00\xff", 7) == 0);
  agc_value args[3] = {call("Bytes.to_a", 1, &program), vm.rt->empty_list, vm.rt->empty_list};
  fails("FrontEnd.hand_off.bytes", 3, args, "RUNTIME-INTERNAL");
  vm.rt->front_end = NULL;
}

#ifndef AGC_NO_GC
/* A hidden pointer to the handed Bytes block, registered as a disappearing link: the collector sets it to 0 when the
   block is unreachable, so a test can see that the block was kept, not only that its memory was not reused yet. */
static GC_word handed_block;
#endif

/* Hands off 1 MiB of patterned Bytes and drops every other reference to them, so after it returns only the interior
   pointer fe->program can keep the block alive. */
static void hand_off_large(agc_front_end *fe) {
  agc_bytes *b = agc_new_bytes((size_t)1 << 20);
  for (size_t k = 0; k < b->len; k++) b->data[k] = (uint8_t)(k * 13);
#ifndef AGC_NO_GC
  /* GC_base: under GC_DEBUG (the GC-stress build) an allocation starts after a debug header. */
  void *base = GC_base(b);
  handed_block = GC_HIDE_POINTER(base);
  int registered = GC_general_register_disappearing_link((void **)&handed_block, base);
  assert(registered == GC_SUCCESS);
#endif
  handed(agc_bytes_value(b), fe);
}

/* Overwrites the stack below the caller, so stale copies of the Bytes value left by hand_off_large do not hold it. */
static void scrub_stack(void) {
  volatile char big[65536];
  for (size_t k = 0; k < sizeof big; k++) big[k] = 0;
}

/* Called through volatile pointers so the compiler cannot inline them and leave the value in this frame. */
static void (*volatile hand_off_large_fn)(agc_front_end *) = hand_off_large;
static void (*volatile scrub_stack_fn)(void) = scrub_stack;

/* The driver's agc_front_end on a scanned stack is all that keeps the handed program alive (interior pointers are
   on): the block stays reachable and intact through collections that reclaim other blocks of the same size. With
   fe.program hidden, the same run clears handed_block. */
static void test_hand_off_survives_collection(void) {
  agc_front_end fe;
  vm.rt->front_end = &fe;
  hand_off_large_fn(&fe);
  scrub_stack_fn();
  /* The jmp_buf of the hand-off's setjmp lives in the static vm and may still hold the value in a saved register. */
  memset(&vm.fail, 0, sizeof vm.fail);
  for (int round = 0; round < 5; round++) {
    for (int k = 0; k < 200; k++) memset(agc_new_bytes((size_t)1 << 20)->data, 0xAA, (size_t)1 << 20);
    agc_gc_collect();
  }
#ifndef AGC_NO_GC
  assert(handed_block != 0);
#endif
  assert(fe.program_len == (size_t)1 << 20);
  for (size_t k = 0; k < fe.program_len; k++) assert(fe.program[k] == (uint8_t)(k * 13));
  vm.rt->front_end = NULL;
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
  test_gcm_and_kdf_keys();
  test_gcm_wipes_a_wrong_tag();
  test_hmac_long_keys();
  test_string_keys();
  test_hand_off_keys();
  test_hand_off_survives_collection();
  test_costs();
  test_collection();
#ifndef _WIN32
  test_overflow();
#endif
  return 0;
}

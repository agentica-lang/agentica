/*
 * Enum.name and Enum.parse (vm/builtins.c), which the front end writes for `value.name` and `Type.parse(text)`: the
 * name of a variant, a variant read from its name, the error that lists the names, and forged arguments. A checked
 * program never forges them, but a .agcb can.
 */
#include "../core.h"
#include "../services.h"
#include "builtin_test.h"
#include "test_support.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

enum { WIDE_COUNT = 25 };

static agc_vm vm;
static agc_program program;
static agc_enum_def enums[2];
static agc_variant_def variants[4 + WIDE_COUNT];

static agc_value text(const char *s) { return agc_string_value(agc_make_string(s, strlen(s), strlen(s))); }

static void define(uint32_t at, const char *name, uint32_t owner, uint32_t arity) {
  variants[at].name = agc_make_string(name, strlen(name), strlen(name));
  variants[at].owner = owner;
  variants[at].arity = arity;
  variants[at].shared = arity ? NULL : agc_new_enum(at, 0);
}

/* Color is Red, Green, Blue(Int) and Shade is 25 variants without a payload. */
static void build(void) {
  define(0, "Red", 0, 0);
  define(1, "Green", 0, 0);
  define(2, "Blue", 0, 1);
  enums[0].name = agc_make_string("Color", 5, 5);
  enums[0].first = 0;
  enums[0].count = 3;
  for (uint32_t k = 0; k < WIDE_COUNT; k++) {
    char name[8];
    snprintf(name, sizeof name, "S%u", k);
    define(3 + k, name, 1, 0);
  }
  enums[1].name = agc_make_string("Shade", 5, 5);
  enums[1].first = 3;
  enums[1].count = WIDE_COUNT;
  program.enums = enums;
  program.enum_count = 2;
  program.variants = variants;
  program.variant_count = 3 + WIDE_COUNT;
}

static const char *parsed(uint32_t first, const char *shown, const char *name, bool *ok) {
  agc_value args[3] = {agc_int(first), text(shown), text(name)};
  const agc_result *r = agc_as_result(&vm, agc_test_call_row(&vm, "Enum.parse", 3, args));
  *ok = r->ok;
  if (r->ok) return agc_as_enum(&vm, r->value)->variant == 0 ? "Red" : "other";
  const agc_string *message = agc_error_message(&vm, r->value);
  char *copy = agc_alloc_atomic(message->bytes + 1);
  memcpy(copy, message->data, message->bytes);
  copy[message->bytes] = '\0';
  return copy;
}

static void test_name_is_the_name_of_the_variant(void) {
  agc_enum *blue = agc_new_enum(2, 1);
  blue->payload[0] = agc_int(7);
  agc_value values[3] = {agc_enum_value(variants[0].shared), agc_enum_value(variants[1].shared), agc_enum_value(blue)};
  const char *names[3] = {"Red", "Green", "Blue"};
  for (int k = 0; k < 3; k++) {
    const agc_string *name = agc_as_string(&vm, agc_test_call_row(&vm, "Enum.name", 1, &values[k]));
    assert(name->bytes == strlen(names[k]) && memcmp(name->data, names[k], name->bytes) == 0);
  }
}

static void test_parse_reads_a_variant_or_lists_the_names(void) {
  bool ok;
  assert(strcmp(parsed(0, "Color", "Red", &ok), "Red") == 0 && ok);
  assert(strcmp(parsed(1, "Color", "Red", &ok), "Red") == 0 && ok);
  /* Blue has a payload, so it is no name. */
  assert(strcmp(parsed(0, "Color", "Blue", &ok), "unknown name \"Blue\" for Color; valid names: Red, Green") == 0 && !ok);
  assert(strcmp(parsed(0, "Color", "a\"b", &ok), "unknown name \"a\\\"b\" for Color; valid names: Red, Green") == 0);
  /* A wide enum lists the first 20 names and ends with "...". */
  const char *wide = parsed(3, "Shade", "x", &ok);
  assert(!ok && strstr(wide, "valid names: S0, S1,") && strstr(wide, ", S19, ...") && !strstr(wide, "S20"));
  assert(strcmp(parsed(3, "Shade", "S24", &ok), "other") == 0 && ok);
}

static void test_forged_arguments_fail(void) {
  agc_value name_args[1] = {agc_int(1)};
  agc_test_fails_row(&vm, "Enum.name", 1, name_args, "RUNTIME-INTERNAL");
  agc_enum *forged = agc_new_enum(program.variant_count, 0);
  name_args[0] = agc_enum_value(forged);
  agc_test_fails_row(&vm, "Enum.name", 1, name_args, "RUNTIME-INTERNAL");
  int64_t firsts[] = {-1, program.variant_count, INT64_C(4294967296), INT64_MAX};
  for (size_t k = 0; k < sizeof firsts / sizeof firsts[0]; k++) {
    agc_value args[3] = {agc_int(firsts[k]), text("Color"), text("Red")};
    agc_test_fails_row(&vm, "Enum.parse", 3, args, "RUNTIME-INTERNAL");
  }
  agc_value not_text[3] = {agc_int(0), text("Color"), agc_int(1)};
  agc_test_fails_row(&vm, "Enum.parse", 3, not_text, "RUNTIME-INTERNAL");
  agc_value not_shown[3] = {agc_int(0), agc_int(1), text("Red")};
  agc_test_fails_row(&vm, "Enum.parse", 3, not_shown, "RUNTIME-INTERNAL");
  agc_value not_first[3] = {text("0"), text("Color"), text("Red")};
  agc_test_fails_row(&vm, "Enum.parse", 3, not_first, "RUNTIME-INTERNAL");
}

int main(void) {
  agc_init();
  program.json_field = UINT32_MAX;
  program.json_node = UINT32_MAX;
  program.optional = UINT32_MAX;
  build();
  agc_vm_init(&vm, &program, stdout, stderr, INT64_MAX);
  test_name_is_the_name_of_the_variant();
  test_parse_reads_a_variant_or_lists_the_names();
  test_forged_arguments_fail();
  puts("enum tests passed");
  return 0;
}

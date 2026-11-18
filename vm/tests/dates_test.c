/*
 * The readers of the Time records (vm/dates.c) against forged values: a .agcb can build a Time record by hand with any
 * struct type, field count or field values, and a program can lack the struct of a record. Each must fail with
 * RUNTIME-INTERNAL "invalid bytecode", never reach the calendar arithmetic or the text. A real value still converts.
 */
#include "../core.h"
#include "../services.h"
#include "builtin_test.h"
#include "test_support.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

enum { OTHER = AGC_TIME_RECORDS };

static agc_vm vm;
static agc_program program;

static agc_value record(uint32_t type, uint32_t n, const int64_t *values) {
  agc_struct *s = agc_new_struct(type, n);
  for (uint32_t k = 0; k < n; k++) s->fields[k] = agc_int(values[k]);
  return agc_struct_value(s);
}

static void forged(const char *name, uint32_t arity, agc_value value) {
  agc_value args[2] = {value, agc_int(0)};
  agc_test_fails_row(&vm, name, arity, args, "RUNTIME-INTERNAL");
  assert(strncmp(vm.outcome->message, "invalid bytecode", 16) == 0);
}

/* A call of NAME with FIRST and SECOND that must fail as forged bytecode. */
static void forged_pair(const char *name, agc_value first, agc_value second) {
  agc_value args[2] = {first, second};
  agc_test_fails_row(&vm, name, 2, args, "RUNTIME-INTERNAL");
  assert(strncmp(vm.outcome->message, "invalid bytecode", 16) == 0);
}

/* A good value with field AT set to VALUE. */
static agc_value changed(uint32_t type, uint32_t n, const int64_t *good, uint32_t at, int64_t value) {
  int64_t values[8];
  memcpy(values, good, sizeof values);
  values[at] = value;
  return record(type, n, values);
}

static void test_a_real_value_converts(void) {
  static const int64_t epoch[8] = {1970, 1, 1, 0, 0, 1, 500000, 3600};
  agc_value t = record(AGC_TIME_DATETIME, 8, epoch);
  assert(agc_as_int(&vm, agc_test_call_row(&vm, "Time.DateTime.to_us", 1, &t)) == INT64_C(-3598500000));
  assert(agc_as_int(&vm, agc_test_call_row(&vm, "Time.DateTime.to_i", 1, &t)) == -3599);
}

static void test_a_forged_datetime_fails(void) {
  static const int64_t good[8] = {2024, 2, 29, 23, 59, 59, 999999, -3600};
  static const struct {
    uint32_t at;
    int64_t value;
  } bad[] = {{0, 0},  {0, 10000}, {1, 0},  {1, 13},      {2, 0},  {2, 30},    {3, 24},   {3, -1},
             {4, 60}, {5, 60},    {6, -1}, {6, 1000000}, {7, 30}, {7, 86400}, {7, INT64_MIN}};
  for (size_t k = 0; k < sizeof bad / sizeof bad[0]; k++) {
    agc_value value = changed(AGC_TIME_DATETIME, 8, good, bad[k].at, bad[k].value);
    forged("Time.DateTime.to_us", 1, value);
    forged("Time.DateTime.getlocal", 2, value);
  }
  forged("Time.DateTime.to_i", 1, record(OTHER, 8, good));
  forged("Time.DateTime.to_i", 1, record(AGC_TIME_NAIVE, 7, good));
  forged("Time.DateTime.to_i", 1, record(AGC_TIME_DATETIME, 7, good));
  forged("Time.DateTime.to_date", 1, agc_int(1));
  agc_value text = record(AGC_TIME_DATETIME, 8, good);
  agc_as_struct(&vm, text)->fields[0] = agc_test_str("2024");
  forged("Time.DateTime.naive_of", 1, text);
}

static void test_a_forged_naive_fails(void) {
  static const int64_t good[8] = {1, 1, 1, 0, 0, 0, 0, 0};
  forged("Time.NaiveDateTime.assume_offset", 2, changed(AGC_TIME_NAIVE, 7, good, 1, 13));
  forged("Time.NaiveDateTime.assume_offset", 2, changed(AGC_TIME_NAIVE, 7, good, 2, 0));
  forged("Time.NaiveDateTime.to_date", 1, record(AGC_TIME_DATETIME, 7, good));
  forged("Time.NaiveDateTime.to_date", 1, record(AGC_TIME_NAIVE, 8, good));
  forged("Time.NaiveDateTime.format_iso8601", 1, changed(AGC_TIME_NAIVE, 7, good, 0, 10000));
  forged("Time.Date.format_iso8601", 1, record(AGC_TIME_NAIVE, 7, good));
  static const int64_t noon[8] = {12, 0, 0, 0};
  forged("Time.TimeOfDay.format_iso8601", 1, changed(AGC_TIME_OF_DAY, 4, noon, 0, 24));
}

/* The arithmetic, comparison and query readers check every value they take, the second one too, also when the count
   is refused anyway: a forged value never gets an argument error instead. */
static void test_a_forged_value_fails_in_arithmetic_and_comparison(void) {
  static const int64_t good[8] = {2024, 2, 29, 23, 59, 59, 999999, 0};
  static const int64_t noon[8] = {12, 0, 0, 0};
  agc_value date = record(AGC_TIME_DATE, 3, good), naive = record(AGC_TIME_NAIVE, 7, good);
  agc_value aware = record(AGC_TIME_DATETIME, 8, good), clock = record(AGC_TIME_OF_DAY, 4, noon);
  agc_value bad_date = changed(AGC_TIME_DATE, 3, good, 2, 30), bad_naive = changed(AGC_TIME_NAIVE, 7, good, 3, 24);
  agc_value bad_aware = changed(AGC_TIME_DATETIME, 8, good, 7, 1), bad_clock = changed(AGC_TIME_OF_DAY, 4, noon, 3, -1);
  agc_value huge = agc_int(INT64_MAX);
  forged_pair("Time.Date.add_days", bad_date, agc_int(1));
  forged_pair("Time.Date.add_days", bad_date, huge);
  forged_pair("Time.NaiveDateTime.add_days", bad_naive, huge);
  forged_pair("Time.DateTime.add_days", bad_aware, agc_int(INT64_MIN));
  forged_pair("Time.NaiveDateTime.add_us", bad_naive, huge);
  forged_pair("Time.DateTime.add_us", bad_aware, agc_int(0));
  forged_pair("Time.Date.days_between", date, bad_date);
  forged_pair("Time.DateTime.us_between", aware, bad_aware);
  forged_pair("Time.NaiveDateTime.us_between", bad_naive, naive);
  forged_pair("Time.compare", aware, naive);
  forged_pair("Time.compare_naive", naive, bad_naive);
  forged_pair("Time.compare_date", bad_date, date);
  forged_pair("Time.compare_time", clock, bad_clock);
  forged("Time.Date.cwday", 1, bad_date);
  forged("Time.Date.yday", 1, aware);
}

/* strftime checks the record before it reads the format, and takes only a String format. */
static void test_a_forged_value_fails_in_strftime(void) {
  static const int64_t good[8] = {2024, 2, 29, 23, 59, 59, 999999, 0};
  static const int64_t noon[8] = {12, 0, 0, 0};
  agc_value format = agc_test_str("%Y %H %z %:z");
  forged_pair("Time.Date.strftime", changed(AGC_TIME_DATE, 3, good, 1, 13), format);
  forged_pair("Time.TimeOfDay.strftime", changed(AGC_TIME_OF_DAY, 4, noon, 2, 60), format);
  forged_pair("Time.NaiveDateTime.strftime", record(AGC_TIME_DATETIME, 8, good), format);
  forged_pair("Time.DateTime.strftime", changed(AGC_TIME_DATETIME, 8, good, 7, 59), format);
  forged_pair("Time.DateTime.strftime", changed(AGC_TIME_DATETIME, 8, good, 7, 1), agc_int(0));
  forged_pair("Time.Date.strftime", record(AGC_TIME_DATE, 3, good), agc_int(0));
}

static void test_a_count_past_the_range_is_an_argument_error(void) {
  static const int64_t good[8] = {2024, 2, 29, 23, 59, 59, 999999, 3600};
  static const char *const adds[] = {"Time.Date.add_days", "Time.NaiveDateTime.add_days", "Time.DateTime.add_days",
                                     "Time.NaiveDateTime.add_us", "Time.DateTime.add_us"};
  static const uint32_t kinds[] = {AGC_TIME_DATE, AGC_TIME_NAIVE, AGC_TIME_DATETIME, AGC_TIME_NAIVE, AGC_TIME_DATETIME};
  static const uint32_t counts[] = {3, 7, 8, 7, 8};
  static const int64_t huge[] = {INT64_MIN, INT64_MIN + 1, -INT64_C(315537897600000001),
                                 INT64_C(315537897600000000), INT64_MAX};
  /* An Error struct and the Optional enum its none fields need, so the kind of the error can be read. */
  agc_variant_def variants[2] = {{NULL, 0, 0, agc_new_enum(0, 0)}, {NULL, 0, 1, NULL}};
  program.variants = variants;
  program.variant_count = 2;
  program.optional = 0;
  vm.rt->error_struct = AGC_TIME_RECORDS;
  const char *want = agc_error_kind_name(AGC_KIND_ARGUMENT);
  for (size_t k = 0; k < sizeof adds / sizeof adds[0]; k++) {
    for (size_t h = 0; h < sizeof huge / sizeof huge[0]; h++) {
      agc_value args[2] = {record(kinds[k], counts[k], good), agc_int(huge[h])};
      agc_value result = agc_test_call_row(&vm, adds[k], 2, args);
      const agc_result *r = agc_as_result(&vm, result);
      assert(!r->ok);
      const agc_string *kind = agc_as_string(&vm, agc_as_struct(&vm, r->value)->fields[AGC_ERROR_KIND]);
      assert(kind->bytes == strlen(want) && memcmp(kind->data, want, kind->bytes) == 0);
    }
  }
  vm.rt->error_struct = UINT32_MAX;
  program.optional = UINT32_MAX;
  program.variants = NULL;
  program.variant_count = 0;
}

static void test_a_program_without_the_struct_fails(void) {
  agc_value seconds = agc_int(0);
  program.time_structs[AGC_TIME_DATETIME] = UINT32_MAX;
  forged("Time.at", 1, seconds);
  program.time_structs[AGC_TIME_DATETIME] = AGC_TIME_DATETIME;
  static const int64_t good[8] = {2000, 1, 1, 0, 0, 0, 0, 0};
  program.time_structs[AGC_TIME_DATE] = UINT32_MAX;
  forged("Time.DateTime.to_date", 1, record(AGC_TIME_DATETIME, 8, good));
  program.time_structs[AGC_TIME_DATE] = AGC_TIME_DATE;
}

int main(void) {
  agc_init();
  program.json_field = UINT32_MAX;
  program.json_node = UINT32_MAX;
  program.optional = UINT32_MAX;
  for (uint32_t k = 0; k < AGC_TIME_RECORDS; k++) program.time_structs[k] = k;
  agc_vm_init(&vm, &program, stdout, stderr, INT64_MAX);
  test_a_real_value_converts();
  test_a_forged_datetime_fails();
  test_a_forged_naive_fails();
  test_a_forged_value_fails_in_arithmetic_and_comparison();
  test_a_forged_value_fails_in_strftime();
  test_a_count_past_the_range_is_an_argument_error();
  test_a_program_without_the_struct_fails();
  puts("dates tests passed");
  return 0;
}

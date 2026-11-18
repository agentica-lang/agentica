/*
 * The readers of the Time records (vm/dates.c) against forged values: a .agcb can build a Time record by hand with any
 * struct type, field count or field values, and a program can lack the struct of a record. Each must fail with
 * RUNTIME-INTERNAL "invalid bytecode", never reach the calendar arithmetic. A real value still converts.
 */
#include "../core.h"
#include "../services.h"
#include "builtin_test.h"
#include "test_support.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

enum { DATE, OF_DAY, NAIVE, DATETIME, OTHER };

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

/* A good value with field AT set to VALUE. */
static agc_value changed(uint32_t type, uint32_t n, const int64_t *good, uint32_t at, int64_t value) {
  int64_t values[8];
  memcpy(values, good, sizeof values);
  values[at] = value;
  return record(type, n, values);
}

static void test_a_real_value_converts(void) {
  static const int64_t epoch[8] = {1970, 1, 1, 0, 0, 1, 500000, 3600};
  agc_value t = record(DATETIME, 8, epoch);
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
    agc_value value = changed(DATETIME, 8, good, bad[k].at, bad[k].value);
    forged("Time.DateTime.to_us", 1, value);
    forged("Time.DateTime.getlocal", 2, value);
  }
  forged("Time.DateTime.to_i", 1, record(OTHER, 8, good));
  forged("Time.DateTime.to_i", 1, record(NAIVE, 7, good));
  forged("Time.DateTime.to_i", 1, record(DATETIME, 7, good));
  forged("Time.DateTime.to_date", 1, agc_int(1));
  agc_value text = record(DATETIME, 8, good);
  agc_as_struct(&vm, text)->fields[0] = agc_test_str("2024");
  forged("Time.DateTime.naive_of", 1, text);
}

static void test_a_forged_naive_fails(void) {
  static const int64_t good[8] = {1, 1, 1, 0, 0, 0, 0, 0};
  forged("Time.NaiveDateTime.assume_offset", 2, changed(NAIVE, 7, good, 1, 13));
  forged("Time.NaiveDateTime.assume_offset", 2, changed(NAIVE, 7, good, 2, 0));
  forged("Time.NaiveDateTime.to_date", 1, record(DATETIME, 7, good));
  forged("Time.NaiveDateTime.to_date", 1, record(NAIVE, 8, good));
}

static void test_a_program_without_the_struct_fails(void) {
  agc_value seconds = agc_int(0);
  program.time_structs[DATETIME] = UINT32_MAX;
  forged("Time.at", 1, seconds);
  program.time_structs[DATETIME] = DATETIME;
  static const int64_t good[8] = {2000, 1, 1, 0, 0, 0, 0, 0};
  program.time_structs[DATE] = UINT32_MAX;
  forged("Time.DateTime.to_date", 1, record(DATETIME, 8, good));
  program.time_structs[DATE] = DATE;
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
  test_a_program_without_the_struct_fails();
  puts("dates tests passed");
  return 0;
}

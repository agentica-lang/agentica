/*
 * The dates and times of the Time family (agc_date_builtins): the constructors of Time.Date, Time.TimeOfDay,
 * Time.NaiveDateTime and Time.DateTime, which check every field, and the calendar queries. Service layer.
 * The calendar is the proleptic Gregorian one, years 1 to 9999, with microseconds and no leap seconds.
 * Design: issue #985 (§41) and docs/vm/05-values-execution-builtins.md §7.
 */
#include "services.h"

#include <inttypes.h>
#include <stdio.h>

#define YEAR_MIN 1
#define YEAR_MAX 9999
#define USEC_MAX 999999
/* RFC 3339 writes an offset as +hh:mm with hh up to 23, so whole minutes of less than a day. */
#define OFFSET_MAX (23 * 3600 + 59 * 60)
#define MESSAGE_SIZE 128

typedef struct {
  int64_t year, month, day, hour, min, sec, usec, utc_offset;
} fields;

static const char *const record_names[AGC_TIME_RECORDS] = {"Time.Date", "Time.TimeOfDay", "Time.NaiveDateTime",
                                                           "Time.DateTime"};

static bool leap(int64_t year) { return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0; }

/* The days of a month that the caller checked is 1 to 12. */
static int64_t month_days(int64_t year, int64_t month) {
  static const int64_t days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  return month == 2 && leap(year) ? 29 : days[month - 1];
}

/* Each check writes the message of the first field out of range to MESSAGE (MESSAGE_SIZE bytes) and returns false, or
   returns true. */
static bool in_range(const char *name, int64_t value, int64_t low, int64_t high, char *message) {
  if (value >= low && value <= high) return true;
  snprintf(message, MESSAGE_SIZE, "%s %" PRId64 " is not in %" PRId64 "..%" PRId64, name, value, low, high);
  return false;
}

static bool check_date(const fields *f, char *message) {
  if (!in_range("year", f->year, YEAR_MIN, YEAR_MAX, message) || !in_range("month", f->month, 1, 12, message))
    return false;
  if (f->day >= 1 && f->day <= month_days(f->year, f->month)) return true;
  snprintf(message, MESSAGE_SIZE, "day %" PRId64 " is not valid for month %" PRId64 " of year %" PRId64, f->day,
           f->month, f->year);
  return false;
}

/* Unix time has no leap seconds, so sec 60 has a message of its own. */
static bool check_clock(const fields *f, char *message) {
  if (!in_range("hour", f->hour, 0, 23, message) || !in_range("min", f->min, 0, 59, message)) return false;
  if (f->sec == 60) {
    snprintf(message, MESSAGE_SIZE, "sec 60 is a leap second, which is not supported");
    return false;
  }
  return in_range("sec", f->sec, 0, 59, message) && in_range("usec", f->usec, 0, USEC_MAX, message);
}

static bool check_offset(int64_t offset, char *message) {
  if (!in_range("utc_offset", offset, -OFFSET_MAX, OFFSET_MAX, message)) return false;
  if (offset % 60 == 0) return true;
  snprintf(message, MESSAGE_SIZE, "utc_offset %" PRId64 " is not a whole number of minutes", offset);
  return false;
}

static void read_fields(agc_vm *vm, const agc_value *args, uint32_t first, uint32_t count, fields *f) {
  int64_t *slots[] = {&f->year, &f->month, &f->day, &f->hour, &f->min, &f->sec, &f->usec, &f->utc_offset};
  for (uint32_t k = 0; k < count; k++) *slots[first + k] = agc_as_int(vm, args[k]);
}

/* The ok Result of the Time record KIND (AGC_TIME_*) with COUNT of the fields from FIRST, in the order of `fields` (a
   time of day starts at hour, 3). The struct was found once for the run (agc_time_structs); a program without it is
   forged bytecode. */
static agc_value build(agc_vm *vm, uint32_t kind, uint32_t first, uint32_t count, const fields *f, uint32_t span) {
  uint32_t type = vm->rt->time_structs[kind];
  if (type == UINT32_MAX) {
    char message[MESSAGE_SIZE];
    snprintf(message, sizeof message, "invalid bytecode: the %s struct is missing", record_names[kind]);
    agc_fail(vm, "RUNTIME-INTERNAL", message, span);
  }
  const int64_t values[] = {f->year, f->month, f->day, f->hour, f->min, f->sec, f->usec, f->utc_offset};
  agc_struct *s = agc_new_struct(type, count);
  for (uint32_t k = 0; k < count; k++) s->fields[k] = agc_int(values[first + k]);
  return agc_result_value(true, agc_struct_value(s));
}

static agc_value builtin_date_new(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  char message[MESSAGE_SIZE];
  read_fields(vm, args, 0, 3, &f);
  if (!check_date(&f, message)) return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return build(vm, AGC_TIME_DATE, 0, 3, &f, span);
}

static agc_value builtin_time_of_day_new(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  char message[MESSAGE_SIZE];
  read_fields(vm, args, 3, 4, &f);
  if (!check_clock(&f, message)) return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return build(vm, AGC_TIME_OF_DAY, 3, 4, &f, span);
}

static agc_value builtin_naive_new(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  char message[MESSAGE_SIZE];
  read_fields(vm, args, 0, 7, &f);
  if (!check_date(&f, message) || !check_clock(&f, message)) return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return build(vm, AGC_TIME_NAIVE, 0, 7, &f, span);
}

static agc_value builtin_datetime_new(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  char message[MESSAGE_SIZE];
  read_fields(vm, args, 0, 8, &f);
  if (!check_date(&f, message) || !check_clock(&f, message) || !check_offset(f.utc_offset, message))
    return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return build(vm, AGC_TIME_DATETIME, 0, 8, &f, span);
}

static agc_value builtin_leap(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_bool(leap(agc_as_int(vm, args[0])));
}

static agc_value builtin_days_in_month(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  fields f = {.year = agc_as_int(vm, args[0]), .month = agc_as_int(vm, args[1])};
  char message[MESSAGE_SIZE];
  if (!in_range("year", f.year, YEAR_MIN, YEAR_MAX, message) || !in_range("month", f.month, 1, 12, message))
    return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return agc_result_value(true, agc_int(month_days(f.year, f.month)));
}

const agc_builtin agc_date_builtins[] = {
  {"Time.Date.new", 3, builtin_date_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.TimeOfDay.new", 4, builtin_time_of_day_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.NaiveDateTime.new", 7, builtin_naive_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.DateTime.new", 8, builtin_datetime_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.Date.leap?", 1, builtin_leap, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.Date.days_in_month", 2, builtin_days_in_month, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
};

const size_t agc_date_builtin_count = sizeof agc_date_builtins / sizeof agc_date_builtins[0];

/*
 * The dates and times of the Time family (agc_date_builtins): the constructors of Time.Date, Time.TimeOfDay,
 * Time.NaiveDateTime and Time.DateTime, which check every field, the calendar queries, Unix time, the wall clock and
 * fixed offsets, arithmetic and comparison, and their ISO 8601 text (RFC 3339 for an aware value). Service layer. The
 * calendar is the proleptic Gregorian one, years 1 to 9999, with microseconds and no leap seconds: every day has 86400
 * seconds, as in POSIX time.
 * Design: issue #985 (§41) and docs/vm/05-values-execution-builtins.md §7.
 */
#include "services.h"

#include <inttypes.h>
#include <stddef.h>
#include <stdio.h>
#include <time.h>

#define YEAR_MIN 1
#define YEAR_MAX 9999
#define USEC_MAX 999999
/* RFC 3339 writes an offset as +hh:mm with hh up to 23, so whole minutes of less than a day. */
#define OFFSET_MAX (23 * 3600 + 59 * 60)
#define MESSAGE_SIZE 128
#define SECOND_US INT64_C(1000000)
#define DAY_US (86400 * SECOND_US)
/* The first and the last microsecond of the years 1 to 9999 in UTC, as microseconds since the Unix epoch. */
#define FIRST_US INT64_C(-62135596800000000)
#define LAST_US INT64_C(253402300799999999)

typedef struct {
  int64_t year, month, day, hour, min, sec, usec, utc_offset;
} fields;

/* A strict reader of the text of one kind: every read checks AT against the length first, digits are ASCII only, and
   nothing depends on the locale. A failure writes MESSAGE (MESSAGE_SIZE bytes) and returns false; positions in it
   count characters from 1, and every character before a failure is ASCII, so they are byte positions too. */
typedef struct {
  const uint8_t *text;
  size_t length, at;
  const char *pattern;
  char *message;
} reader;

/* agc_fail keeps the pointer to its message, so these are static. */
static const char *const missing_struct[AGC_TIME_RECORDS] = {
    "invalid bytecode: the Time.Date struct is missing",
    "invalid bytecode: the Time.TimeOfDay struct is missing",
    "invalid bytecode: the Time.NaiveDateTime struct is missing",
    "invalid bytecode: the Time.DateTime struct is missing",
};
static const char *const forged_value[AGC_TIME_RECORDS] = {
    "invalid bytecode: not a valid Time.Date",
    "invalid bytecode: not a valid Time.TimeOfDay",
    "invalid bytecode: not a valid Time.NaiveDateTime",
    "invalid bytecode: not a valid Time.DateTime",
};
/* The first field and the number of fields of each record, in the order of `fields`: a time of day starts at hour. */
static const uint32_t record_first[AGC_TIME_RECORDS] = {0, 3, 0, 0};
static const uint32_t record_count[AGC_TIME_RECORDS] = {3, 4, 7, 8};

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

static uint32_t record_type(agc_vm *vm, uint32_t kind, uint32_t span) {
  uint32_t type = vm->rt->program->time_structs[kind];
  if (type == UINT32_MAX) agc_fail(vm, "RUNTIME-INTERNAL", missing_struct[kind], span);
  return type;
}

/* The Time record KIND (AGC_TIME_*) with its fields from F. The loader found the struct (agc_time_structs); a program
   without it is forged bytecode. */
static agc_value record(agc_vm *vm, uint32_t kind, const fields *f, uint32_t span) {
  const int64_t values[] = {f->year, f->month, f->day, f->hour, f->min, f->sec, f->usec, f->utc_offset};
  uint32_t first = record_first[kind], count = record_count[kind];
  agc_struct *s = agc_new_struct(record_type(vm, kind, span), count);
  for (uint32_t k = 0; k < count; k++) s->fields[k] = agc_int(values[first + k]);
  return agc_struct_value(s);
}

static agc_value build(agc_vm *vm, uint32_t kind, const fields *f, uint32_t span) {
  return agc_result_value(true, record(vm, kind, f, span));
}

/* The fields of VALUE, a Time record of KIND, checked again: a .agcb may hold a struct of that name with any values
   (a hand-made CONSTRUCT or JSON table), and the arithmetic below relies on every range. Every reader of a Time record
   in C goes through here. */
static void read_record(agc_vm *vm, agc_value value, uint32_t kind, fields *f, uint32_t span) {
  const agc_struct *s = agc_as_struct(vm, value);
  uint32_t first = record_first[kind], count = record_count[kind];
  if (s->type != record_type(vm, kind, span) || s->n != count)
    agc_fail(vm, "RUNTIME-INTERNAL", forged_value[kind], span);
  read_fields(vm, s->fields, first, count, f);
  char message[MESSAGE_SIZE];
  bool valid = (kind == AGC_TIME_OF_DAY || check_date(f, message)) &&
               (kind == AGC_TIME_DATE || check_clock(f, message)) &&
               (kind != AGC_TIME_DATETIME || check_offset(f->utc_offset, message));
  if (!valid) agc_fail(vm, "RUNTIME-INTERNAL", forged_value[kind], span);
}

/* Days since 1970-01-01 of a date, and the date of a day count: Howard Hinnant's days_from_civil and civil_from_days,
   by eras of 400 years from 0000-03-01 so the leap day ends the year. The callers keep the years in 1 to 9999, so no
   step overflows. */
static int64_t days_from_civil(int64_t year, int64_t month, int64_t day) {
  year -= month <= 2;
  int64_t era = (year >= 0 ? year : year - 399) / 400;
  int64_t yoe = year - era * 400;
  int64_t doy = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1;
  int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

static void civil_from_days(int64_t days, fields *f) {
  int64_t z = days + 719468;
  int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  int64_t doe = z - era * 146097;
  int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  int64_t mp = (5 * doy + 2) / 153;
  f->day = doy - (153 * mp + 2) / 5 + 1;
  f->month = mp < 10 ? mp + 3 : mp - 9;
  f->year = yoe + era * 400 + (f->month <= 2);
}

/* The reading of F (date and clock) as microseconds since the epoch, as if it were UTC. */
static int64_t reading_us(const fields *f) {
  int64_t clock = ((f->hour * 60 + f->min) * 60 + f->sec) * SECOND_US + f->usec;
  return days_from_civil(f->year, f->month, f->day) * DAY_US + clock;
}

/* Sets the date and clock of F to the reading US (microseconds since the epoch, as if UTC), in FIRST_US..LAST_US. */
static void set_reading(int64_t us, fields *f) {
  int64_t days = us / DAY_US, rest = us % DAY_US;
  if (rest < 0) {
    days -= 1;
    rest += DAY_US;
  }
  civil_from_days(days, f);
  f->usec = rest % SECOND_US;
  rest /= SECOND_US;
  f->sec = rest % 60;
  f->min = rest / 60 % 60;
  f->hour = rest / 3600;
}

/* The instant of a valid aware value in microseconds since the epoch. Its reading is in the years 1 to 9999 and the
   offset under a day, so the result is within a day of FIRST_US..LAST_US and cannot overflow. */
static int64_t instant_us(const fields *f) { return reading_us(f) - f->utc_offset * SECOND_US; }

/* The aware value of the instant US at OFFSET (seconds, checked), or an error when its reading leaves the years 1 to
   9999. US is within a day of FIRST_US..LAST_US, so the sum cannot overflow. */
static agc_value at_offset(agc_vm *vm, int64_t us, int64_t offset, uint32_t span) {
  int64_t local = us + offset * SECOND_US;
  if (local < FIRST_US || local > LAST_US) {
    char message[MESSAGE_SIZE];
    snprintf(message, sizeof message, "the reading at utc_offset %" PRId64 " is outside the years 1 to 9999", offset);
    return agc_error(vm, AGC_KIND_ARGUMENT, message);
  }
  fields f = {.utc_offset = offset};
  set_reading(local, &f);
  return build(vm, AGC_TIME_DATETIME, &f, span);
}

static agc_value builtin_date_new(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  char message[MESSAGE_SIZE];
  read_fields(vm, args, 0, 3, &f);
  if (!check_date(&f, message)) return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return build(vm, AGC_TIME_DATE, &f, span);
}

static agc_value builtin_time_of_day_new(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  char message[MESSAGE_SIZE];
  read_fields(vm, args, 3, 4, &f);
  if (!check_clock(&f, message)) return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return build(vm, AGC_TIME_OF_DAY, &f, span);
}

static agc_value builtin_naive_new(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  char message[MESSAGE_SIZE];
  read_fields(vm, args, 0, 7, &f);
  if (!check_date(&f, message) || !check_clock(&f, message)) return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return build(vm, AGC_TIME_NAIVE, &f, span);
}

static agc_value builtin_datetime_new(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  char message[MESSAGE_SIZE];
  read_fields(vm, args, 0, 8, &f);
  if (!check_date(&f, message) || !check_clock(&f, message) || !check_offset(f.utc_offset, message))
    return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return build(vm, AGC_TIME_DATETIME, &f, span);
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

static agc_value builtin_at(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t seconds = agc_as_int(vm, args[0]);
  char message[MESSAGE_SIZE];
  /* Checked in seconds before the multiplication, which then cannot overflow. */
  if (!in_range("seconds", seconds, FIRST_US / SECOND_US, LAST_US / SECOND_US, message))
    return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return at_offset(vm, seconds * SECOND_US, 0, span);
}

static agc_value builtin_at_us(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t us = agc_as_int(vm, args[0]);
  char message[MESSAGE_SIZE];
  if (!in_range("us", us, FIRST_US, LAST_US, message)) return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return at_offset(vm, us, 0, span);
}

/* The wall clock in UTC, truncated to microseconds, as Time.now_ms reads it. */
static agc_value builtin_now(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  struct timespec ts;
  if (timespec_get(&ts, TIME_UTC) != TIME_UTC || (int64_t)ts.tv_sec < FIRST_US / SECOND_US ||
      (int64_t)ts.tv_sec > LAST_US / SECOND_US)
    agc_fail(vm, "RUNTIME-INTERNAL", "cannot read the clock", span);
  fields f = {0};
  set_reading((int64_t)ts.tv_sec * SECOND_US + ts.tv_nsec / 1000, &f);
  return record(vm, AGC_TIME_DATETIME, &f, span);
}

static agc_value builtin_to_i(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  read_record(vm, args[0], AGC_TIME_DATETIME, &f, span);
  /* Floor division, as Ruby's Time#to_i: the second that holds the instant, also before 1970. */
  int64_t us = instant_us(&f), seconds = us / SECOND_US;
  return agc_int(us % SECOND_US < 0 ? seconds - 1 : seconds);
}

static agc_value builtin_to_us(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  read_record(vm, args[0], AGC_TIME_DATETIME, &f, span);
  return agc_int(instant_us(&f));
}

static agc_value builtin_getlocal(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  read_record(vm, args[0], AGC_TIME_DATETIME, &f, span);
  int64_t offset = agc_as_int(vm, args[1]);
  char message[MESSAGE_SIZE];
  if (!check_offset(offset, message)) return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return at_offset(vm, instant_us(&f), offset, span);
}

static agc_value builtin_getutc(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  read_record(vm, args[0], AGC_TIME_DATETIME, &f, span);
  return at_offset(vm, instant_us(&f), 0, span);
}

/* The reading of a naive value at an offset: the fields stay, so only the offset is checked. */
static agc_value builtin_assume_offset(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  read_record(vm, args[0], AGC_TIME_NAIVE, &f, span);
  f.utc_offset = agc_as_int(vm, args[1]);
  char message[MESSAGE_SIZE];
  if (!check_offset(f.utc_offset, message)) return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return build(vm, AGC_TIME_DATETIME, &f, span);
}

static agc_value builtin_naive_of(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  read_record(vm, args[0], AGC_TIME_DATETIME, &f, span);
  return record(vm, AGC_TIME_NAIVE, &f, span);
}

static agc_value builtin_to_date(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  read_record(vm, args[0], AGC_TIME_DATETIME, &f, span);
  return record(vm, AGC_TIME_DATE, &f, span);
}

static agc_value builtin_naive_to_date(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  read_record(vm, args[0], AGC_TIME_NAIVE, &f, span);
  return record(vm, AGC_TIME_DATE, &f, span);
}

/* Arithmetic and comparison. The span of the range bounds every count before it is added: SPAN_DAYS days from the first
   to the last date, SPAN_US microseconds from the first to the last reading. A larger count leaves the range from any
   value, so it is refused before the sum can overflow. */
#define SPAN_DAYS INT64_C(3652058)
#define SPAN_US (LAST_US - FIRST_US)

static int64_t date_days(const fields *f) { return days_from_civil(f->year, f->month, f->day); }

static int64_t clock_us(const fields *f) { return ((f->hour * 60 + f->min) * 60 + f->sec) * SECOND_US + f->usec; }

static int compare_ints(int64_t a, int64_t b) { return (a > b) - (a < b); }

static agc_value out_of_range(agc_vm *vm, const char *what) {
  char message[MESSAGE_SIZE];
  snprintf(message, sizeof message, "the %s is outside the years 1 to 9999", what);
  return agc_error(vm, AGC_KIND_ARGUMENT, message);
}

static agc_value builtin_date_add_days(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  read_record(vm, args[0], AGC_TIME_DATE, &f, span);
  int64_t days = agc_as_int(vm, args[1]);
  if (days < -SPAN_DAYS || days > SPAN_DAYS) return out_of_range(vm, "date");
  int64_t moved = date_days(&f) + days;
  if (moved < FIRST_US / DAY_US || moved > LAST_US / DAY_US) return out_of_range(vm, "date");
  civil_from_days(moved, &f);
  return build(vm, AGC_TIME_DATE, &f, span);
}

/* The value of KIND (naive or aware) whose reading is US microseconds later; an aware value keeps its offset, so its
   instant moves as much as its reading. */
static agc_value add_reading_us(agc_vm *vm, uint32_t kind, int64_t us, uint32_t span, agc_value value) {
  fields f = {0};
  read_record(vm, value, kind, &f, span);
  if (us < -SPAN_US || us > SPAN_US) return out_of_range(vm, "reading");
  int64_t moved = reading_us(&f) + us;
  if (moved < FIRST_US || moved > LAST_US) return out_of_range(vm, "reading");
  set_reading(moved, &f);
  return build(vm, kind, &f, span);
}

/* Days as microseconds; a count past the span stays past it, refused before the multiplication can overflow. */
static agc_value add_days_to_reading(agc_vm *vm, uint32_t kind, agc_value *args, uint32_t span) {
  int64_t days = agc_as_int(vm, args[1]);
  int64_t us = days < -SPAN_DAYS - 1 ? -SPAN_US - 1 : days > SPAN_DAYS + 1 ? SPAN_US + 1 : days * DAY_US;
  return add_reading_us(vm, kind, us, span, args[0]);
}

static agc_value builtin_naive_add_days(agc_vm *vm, agc_value *args, uint32_t span) {
  return add_days_to_reading(vm, AGC_TIME_NAIVE, args, span);
}

static agc_value builtin_datetime_add_days(agc_vm *vm, agc_value *args, uint32_t span) {
  return add_days_to_reading(vm, AGC_TIME_DATETIME, args, span);
}

static agc_value builtin_naive_add_us(agc_vm *vm, agc_value *args, uint32_t span) {
  return add_reading_us(vm, AGC_TIME_NAIVE, agc_as_int(vm, args[1]), span, args[0]);
}

static agc_value builtin_datetime_add_us(agc_vm *vm, agc_value *args, uint32_t span) {
  return add_reading_us(vm, AGC_TIME_DATETIME, agc_as_int(vm, args[1]), span, args[0]);
}

/* The two values of KIND that a builtin takes, each read and checked. */
static void read_pair(agc_vm *vm, agc_value *args, uint32_t kind, fields *a, fields *b, uint32_t span) {
  read_record(vm, args[0], kind, a, span);
  read_record(vm, args[1], kind, b, span);
}

static agc_value builtin_days_between(agc_vm *vm, agc_value *args, uint32_t span) {
  fields from = {0}, to = {0};
  read_pair(vm, args, AGC_TIME_DATE, &from, &to, span);
  return agc_int(date_days(&to) - date_days(&from));
}

static agc_value builtin_us_between(agc_vm *vm, agc_value *args, uint32_t span) {
  fields from = {0}, to = {0};
  read_pair(vm, args, AGC_TIME_DATETIME, &from, &to, span);
  return agc_int(instant_us(&to) - instant_us(&from));
}

static agc_value builtin_naive_us_between(agc_vm *vm, agc_value *args, uint32_t span) {
  fields from = {0}, to = {0};
  read_pair(vm, args, AGC_TIME_NAIVE, &from, &to, span);
  return agc_int(reading_us(&to) - reading_us(&from));
}

static agc_value builtin_compare(agc_vm *vm, agc_value *args, uint32_t span) {
  fields a = {0}, b = {0};
  read_pair(vm, args, AGC_TIME_DATETIME, &a, &b, span);
  return agc_int(compare_ints(instant_us(&a), instant_us(&b)));
}

static agc_value builtin_compare_naive(agc_vm *vm, agc_value *args, uint32_t span) {
  fields a = {0}, b = {0};
  read_pair(vm, args, AGC_TIME_NAIVE, &a, &b, span);
  return agc_int(compare_ints(reading_us(&a), reading_us(&b)));
}

static agc_value builtin_compare_date(agc_vm *vm, agc_value *args, uint32_t span) {
  fields a = {0}, b = {0};
  read_pair(vm, args, AGC_TIME_DATE, &a, &b, span);
  return agc_int(compare_ints(date_days(&a), date_days(&b)));
}

static agc_value builtin_compare_time(agc_vm *vm, agc_value *args, uint32_t span) {
  fields a = {0}, b = {0};
  read_pair(vm, args, AGC_TIME_OF_DAY, &a, &b, span);
  return agc_int(compare_ints(clock_us(&a), clock_us(&b)));
}

/* ISO weekday, 1 for Monday to 7 for Sunday: 1970-01-01, day 0, was a Thursday. */
static agc_value builtin_cwday(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  read_record(vm, args[0], AGC_TIME_DATE, &f, span);
  int64_t days = date_days(&f);
  return agc_int(((days % 7 + 7) % 7 + 3) % 7 + 1);
}

static agc_value builtin_yday(agc_vm *vm, agc_value *args, uint32_t span) {
  fields f = {0};
  read_record(vm, args[0], AGC_TIME_DATE, &f, span);
  return agc_int(date_days(&f) - days_from_civil(f.year, 1, 1) + 1);
}

/* The ISO 8601 text of a value: YYYY-MM-DD, HH:MM:SS.ffffff (always six digits), the two joined by T, and for an
   aware value Z at offset 0 or +HH:MM / -HH:MM. TEXT holds at least TEXT_SIZE bytes. */
#define TEXT_SIZE 64

static size_t write_text(uint32_t kind, const fields *f, char *text) {
  int n = 0;
  if (kind != AGC_TIME_OF_DAY)
    n += snprintf(text + n, TEXT_SIZE - (size_t)n, "%04d-%02d-%02d", (int)f->year, (int)f->month, (int)f->day);
  if (kind == AGC_TIME_DATE) return (size_t)n;
  if (kind != AGC_TIME_OF_DAY) text[n++] = 'T';
  n += snprintf(text + n, TEXT_SIZE - (size_t)n, "%02d:%02d:%02d.%06d", (int)f->hour, (int)f->min, (int)f->sec,
                (int)f->usec);
  if (kind != AGC_TIME_DATETIME) return (size_t)n;
  if (f->utc_offset == 0) {
    text[n++] = 'Z';
    return (size_t)n;
  }
  int64_t minutes = f->utc_offset < 0 ? -f->utc_offset / 60 : f->utc_offset / 60;
  n += snprintf(text + n, TEXT_SIZE - (size_t)n, "%c%02d:%02d", f->utc_offset < 0 ? '-' : '+', (int)(minutes / 60),
                (int)(minutes % 60));
  return (size_t)n;
}

static agc_value format_record(agc_vm *vm, agc_value value, uint32_t kind, uint32_t span) {
  fields f = {0};
  read_record(vm, value, kind, &f, span);
  char text[TEXT_SIZE];
  size_t n = write_text(kind, &f, text);
  return agc_string_value(agc_make_string(text, n, n));
}

static agc_value builtin_format_date(agc_vm *vm, agc_value *args, uint32_t span) {
  return format_record(vm, args[0], AGC_TIME_DATE, span);
}

static agc_value builtin_format_time_of_day(agc_vm *vm, agc_value *args, uint32_t span) {
  return format_record(vm, args[0], AGC_TIME_OF_DAY, span);
}

static agc_value builtin_format_naive(agc_vm *vm, agc_value *args, uint32_t span) {
  return format_record(vm, args[0], AGC_TIME_NAIVE, span);
}

static agc_value builtin_format_datetime(agc_vm *vm, agc_value *args, uint32_t span) {
  return format_record(vm, args[0], AGC_TIME_DATETIME, span);
}

static bool expected(reader *r) {
  snprintf(r->message, MESSAGE_SIZE, "expected %s at character %zu", r->pattern, r->at + 1);
  return false;
}

static bool next_is(const reader *r, char c) { return r->at < r->length && r->text[r->at] == (uint8_t)c; }

static bool next_digit(const reader *r) { return r->at < r->length && r->text[r->at] >= '0' && r->text[r->at] <= '9'; }

/* A separator: exactly C, or for T either case, as RFC 3339 allows. */
static bool separator(reader *r, char c) {
  uint8_t got = r->at < r->length ? r->text[r->at] : 0;
  if (r->at >= r->length || !(got == (uint8_t)c || (c == 'T' && got == 't'))) return expected(r);
  r->at++;
  return true;
}

static bool number(reader *r, int count, int64_t *out) {
  int64_t value = 0;
  for (int k = 0; k < count; k++) {
    if (!next_digit(r)) return expected(r);
    value = value * 10 + (r->text[r->at++] - '0');
  }
  *out = value;
  return true;
}

static bool read_date(reader *r, fields *f) {
  return number(r, 4, &f->year) && separator(r, '-') && number(r, 2, &f->month) && separator(r, '-') &&
         number(r, 2, &f->day);
}

/* HH:MM:SS, then a . and one or more digits, of which the first six are kept: the rest is cut off, as rounding could
   carry into the next second. */
static bool read_clock(reader *r, fields *f) {
  if (!number(r, 2, &f->hour) || !separator(r, ':') || !number(r, 2, &f->min) || !separator(r, ':') ||
      !number(r, 2, &f->sec))
    return false;
  f->usec = 0;
  if (!next_is(r, '.')) return true;
  r->at++;
  if (!next_digit(r)) {
    snprintf(r->message, MESSAGE_SIZE, "expected a digit after . at character %zu", r->at + 1);
    return false;
  }
  int64_t scale = 100000;
  for (; next_digit(r); r->at++, scale /= 10) f->usec += (r->text[r->at] - '0') * scale;
  return true;
}

static bool offset_next(const reader *r) {
  return r->at < r->length && (r->text[r->at] == '+' || r->text[r->at] == '-' || (r->text[r->at] | 0x20) == 'z');
}

/* Z, or +HH:MM / -HH:MM with HH to 23 and MM to 59; -00:00 is offset 0. */
static bool read_offset(reader *r, fields *f) {
  if ((r->text[r->at] | 0x20) == 'z') {
    r->at++;
    f->utc_offset = 0;
    return true;
  }
  int64_t sign = r->text[r->at++] == '-' ? -1 : 1, hours, minutes;
  r->pattern = "+HH:MM";
  if (!number(r, 2, &hours) || !separator(r, ':') || !number(r, 2, &minutes)) return false;
  if (!in_range("offset hour", hours, 0, 23, r->message) || !in_range("offset minute", minutes, 0, 59, r->message))
    return false;
  f->utc_offset = sign * (hours * 3600 + minutes * 60);
  return true;
}

static bool read_end(reader *r) {
  if (r->at == r->length) return true;
  snprintf(r->message, MESSAGE_SIZE, "unexpected text at character %zu", r->at + 1);
  return false;
}

static const char *const patterns[AGC_TIME_RECORDS] = {"YYYY-MM-DD", "HH:MM:SS", "YYYY-MM-DDTHH:MM:SS",
                                                       "YYYY-MM-DDTHH:MM:SS"};

/* The value of KIND that TEXT spells, with the checks of its constructor, or an argument error. */
static agc_value parse_record(agc_vm *vm, agc_value text, uint32_t kind, uint32_t span) {
  const agc_string *s = agc_as_string(vm, text);
  char message[MESSAGE_SIZE];
  reader r = {(const uint8_t *)s->data, s->bytes, 0, patterns[kind], message};
  fields f = {0};
  bool ok = true;
  if (kind != AGC_TIME_OF_DAY) ok = read_date(&r, &f);
  if (ok && kind != AGC_TIME_DATE && kind != AGC_TIME_OF_DAY) ok = separator(&r, 'T');
  if (ok && kind != AGC_TIME_DATE) ok = read_clock(&r, &f);
  if (ok && kind == AGC_TIME_DATETIME && r.at == r.length) {
    snprintf(message, MESSAGE_SIZE, "missing offset; use Time.NaiveDateTime.iso8601 for text without one");
    ok = false;
  } else if (ok && kind == AGC_TIME_DATETIME) {
    r.pattern = "Z or +HH:MM";
    ok = offset_next(&r) ? read_offset(&r, &f) : expected(&r);
  } else if (ok && offset_next(&r) && kind != AGC_TIME_NAIVE) {
    snprintf(message, MESSAGE_SIZE, "an offset is not allowed in a %s at character %zu",
             kind == AGC_TIME_DATE ? "Time.Date" : "Time.TimeOfDay", r.at + 1);
    ok = false;
  } else if (ok && offset_next(&r)) {
    /* The offset as written, up to its six characters and only while they are printable ASCII. */
    int shown = 0;
    while (shown < 6 && r.at + (size_t)shown < r.length && r.text[r.at + (size_t)shown] >= 0x20 &&
           r.text[r.at + (size_t)shown] < 0x7f && r.text[r.at + (size_t)shown] != '"')
      shown++;
    snprintf(message, MESSAGE_SIZE, "offset \"%.*s\" is not allowed here; use Time.DateTime.iso8601", shown,
             (const char *)r.text + r.at);
    ok = false;
  }
  ok = ok && read_end(&r);
  if (ok && kind != AGC_TIME_OF_DAY) ok = check_date(&f, message);
  if (ok && kind != AGC_TIME_DATE) ok = check_clock(&f, message);
  if (!ok) return agc_error(vm, AGC_KIND_ARGUMENT, message);
  return build(vm, kind, &f, span);
}

static agc_value builtin_parse_date(agc_vm *vm, agc_value *args, uint32_t span) {
  return parse_record(vm, args[0], AGC_TIME_DATE, span);
}

static agc_value builtin_parse_time_of_day(agc_vm *vm, agc_value *args, uint32_t span) {
  return parse_record(vm, args[0], AGC_TIME_OF_DAY, span);
}

static agc_value builtin_parse_naive(agc_vm *vm, agc_value *args, uint32_t span) {
  return parse_record(vm, args[0], AGC_TIME_NAIVE, span);
}

static agc_value builtin_parse_datetime(agc_vm *vm, agc_value *args, uint32_t span) {
  return parse_record(vm, args[0], AGC_TIME_DATETIME, span);
}

const agc_builtin agc_date_builtins[] = {
  {"Time.Date.new", 3, builtin_date_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.TimeOfDay.new", 4, builtin_time_of_day_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.NaiveDateTime.new", 7, builtin_naive_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.DateTime.new", 8, builtin_datetime_new, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.Date.leap?", 1, builtin_leap, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.Date.days_in_month", 2, builtin_days_in_month, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.at", 1, builtin_at, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.at_us", 1, builtin_at_us, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.now", 0, builtin_now, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.DateTime.to_i", 1, builtin_to_i, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.DateTime.to_us", 1, builtin_to_us, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.DateTime.getlocal", 2, builtin_getlocal, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.DateTime.getutc", 1, builtin_getutc, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.NaiveDateTime.assume_offset", 2, builtin_assume_offset, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false,
   false},
  {"Time.DateTime.naive_of", 1, builtin_naive_of, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.DateTime.to_date", 1, builtin_to_date, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.NaiveDateTime.to_date", 1, builtin_naive_to_date, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.Date.add_days", 2, builtin_date_add_days, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.NaiveDateTime.add_days", 2, builtin_naive_add_days, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.DateTime.add_days", 2, builtin_datetime_add_days, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.NaiveDateTime.add_us", 2, builtin_naive_add_us, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.DateTime.add_us", 2, builtin_datetime_add_us, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.Date.days_between", 2, builtin_days_between, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.DateTime.us_between", 2, builtin_us_between, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.NaiveDateTime.us_between", 2, builtin_naive_us_between, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false,
   false},
  {"Time.compare", 2, builtin_compare, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.compare_naive", 2, builtin_compare_naive, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.compare_date", 2, builtin_compare_date, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.compare_time", 2, builtin_compare_time, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.Date.cwday", 1, builtin_cwday, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.Date.yday", 1, builtin_yday, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  /* The text builtins allocate a String or read one of any length, so they are direct rows, not leaves. */
  {"Time.Date.format_iso8601", 1, builtin_format_date, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true, false},
  {"Time.TimeOfDay.format_iso8601", 1, builtin_format_time_of_day, AGC_NATIVE_NONE, AGC_COST_NONE, false, false,
   true, false},
  {"Time.NaiveDateTime.format_iso8601", 1, builtin_format_naive, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true,
   false},
  {"Time.DateTime.format_iso8601", 1, builtin_format_datetime, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, true,
   false},
  {"Time.Date.iso8601", 1, builtin_parse_date, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true, false},
  {"Time.TimeOfDay.iso8601", 1, builtin_parse_time_of_day, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true, false},
  {"Time.NaiveDateTime.iso8601", 1, builtin_parse_naive, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true, false},
  {"Time.DateTime.iso8601", 1, builtin_parse_datetime, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, true, false},
};

const size_t agc_date_builtin_count = sizeof agc_date_builtins / sizeof agc_date_builtins[0];

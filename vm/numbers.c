/*
 * The Float, Time and Random builtins (agc_number_builtins). Service layer.
 * Design: docs/vm/02-reference-behavior.md §2.2 and
 * docs/vm/05-values-execution-builtins.md §7.4.
 */
#include "services.h"

#include <math.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#endif

#define AGC_CANONICAL_NAN64 UINT64_C(0x7FF8000000000000)
#define AGC_CANONICAL_NAN32 UINT32_C(0x7FC00000)
#define AGC_FLOAT32_OVERFLOW 0x1.ffffffp127

static agc_value builtin_random_int(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t value;
  if (!agc_random_int(&vm->task->random, agc_as_int(vm, args[0]), agc_as_int(vm, args[1]), &value))
    agc_fail(vm, "RUNTIME-INVALID-RANGE", "Random.int needs min <= max", span);
  return agc_int(value);
}

static agc_value builtin_random_float(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_float(agc_random_float(&vm->task->random));
}

static agc_value builtin_float_from_int(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_float((double)agc_as_int(vm, args[0]));
}

static agc_value float_to_int(agc_vm *vm, agc_value *args, uint32_t span, bool bang) {
  double x = agc_as_float(vm, args[0]);
  const char *code = "RUNTIME-INTEGER-OVERFLOW";
  const char *message = "Int result is outside the 64-bit range";
  if (isnan(x) || isinf(x)) {
    code = "RUNTIME-INVALID-NUMBER";
    message = isnan(x) ? "cannot convert +nan.0 to Int" : x > 0 ? "cannot convert +inf.0 to Int" : "cannot convert -inf.0 to Int";
  } else {
    if (x >= -9223372036854775808.0 && x < 9223372036854775808.0) {
      int64_t n = (int64_t)x;
      return bang ? agc_int(n) : agc_result_value(true, agc_int(n));
    }
  }
  if (bang) agc_fail(vm, code, message, span);
  size_t n = strlen(message);
  return agc_result_value(false, agc_string_value(agc_make_string(message, n, n)));
}

static agc_value builtin_float_to_int(agc_vm *vm, agc_value *args, uint32_t span) {
  return float_to_int(vm, args, span, false);
}

static agc_value builtin_float_to_int_bang(agc_vm *vm, agc_value *args, uint32_t span) {
  return float_to_int(vm, args, span, true);
}

static int64_t int_from_bits(uint64_t bits) {
  return bits <= (uint64_t)INT64_MAX ? (int64_t)bits : -(int64_t)(~bits) - 1;
}

static agc_value builtin_int_bit_and(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(int_from_bits((uint64_t)agc_as_int(vm, args[0]) & (uint64_t)agc_as_int(vm, args[1])));
}

static agc_value builtin_int_bit_or(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(int_from_bits((uint64_t)agc_as_int(vm, args[0]) | (uint64_t)agc_as_int(vm, args[1])));
}

static agc_value builtin_int_bit_xor(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(int_from_bits((uint64_t)agc_as_int(vm, args[0]) ^ (uint64_t)agc_as_int(vm, args[1])));
}

static agc_value builtin_int_bit_not(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(int_from_bits(~(uint64_t)agc_as_int(vm, args[0])));
}

static uint64_t shift_count(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t count = agc_as_int(vm, args[1]);
  if (count < 0) agc_fail(vm, "RUNTIME-INVALID-COUNT", "shift count must be nonnegative", span + 2);
  return (uint64_t)count;
}

static agc_value builtin_int_shift_left(agc_vm *vm, agc_value *args, uint32_t span) {
  uint64_t count = shift_count(vm, args, span);
  uint64_t bits = (uint64_t)agc_as_int(vm, args[0]);
  return agc_int(int_from_bits(count >= 64 ? 0 : bits << count));
}

static agc_value builtin_int_shift_right(agc_vm *vm, agc_value *args, uint32_t span) {
  uint64_t count = shift_count(vm, args, span);
  uint64_t bits = (uint64_t)agc_as_int(vm, args[0]);
  bool negative = (bits >> 63) != 0;
  if (count >= 64) return agc_int(negative ? -1 : 0);
  return agc_int(int_from_bits(negative ? ~(~bits >> count) : bits >> count));
}

static agc_value builtin_int_shift_right_unsigned(agc_vm *vm, agc_value *args, uint32_t span) {
  uint64_t count = shift_count(vm, args, span);
  uint64_t bits = (uint64_t)agc_as_int(vm, args[0]);
  return agc_int(int_from_bits(count >= 64 ? 0 : bits >> count));
}

static double float64_from_bits(uint64_t bits) {
  double x;
  memcpy(&x, &bits, sizeof x);
  return x;
}

static uint64_t float64_to_bits(double x) {
  uint64_t bits;
  memcpy(&bits, &x, sizeof bits);
  return bits;
}

static agc_value builtin_float_to_bits(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  double x = agc_as_float(vm, args[0]);
  return agc_int(int_from_bits(isnan(x) ? AGC_CANONICAL_NAN64 : float64_to_bits(x)));
}

static agc_value builtin_float_from_bits(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  double x = float64_from_bits((uint64_t)agc_as_int(vm, args[0]));
  return agc_float(isnan(x) ? float64_from_bits(AGC_CANONICAL_NAN64) : x);
}

static agc_value builtin_float_to_bits32(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  double x = agc_as_float(vm, args[0]);
  if (isnan(x)) return agc_int(AGC_CANONICAL_NAN32);
  uint32_t sign = signbit(x) ? UINT32_C(0x80000000) : 0;
  if (fabs(x) >= AGC_FLOAT32_OVERFLOW) return agc_int(sign | UINT32_C(0x7F800000));
  float narrow = (float)x;
  uint32_t bits;
  memcpy(&bits, &narrow, sizeof bits);
  return agc_int(bits);
}

static agc_value builtin_float_from_bits32(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t value = agc_as_int(vm, args[0]);
  if (value < 0 || value > UINT32_MAX)
    agc_fail(vm, "RUNTIME-INVALID-NUMBER", "bits must be between 0 and 4294967295", span + 1);
  uint32_t bits = (uint32_t)value;
  float narrow;
  memcpy(&narrow, &bits, sizeof narrow);
  return agc_float(isnan(narrow) ? float64_from_bits(AGC_CANONICAL_NAN64) : (double)narrow);
}

static int64_t floor_ms(int64_t seconds, int64_t nanoseconds) { return seconds * 1000 + nanoseconds / 1000000; }

static agc_value builtin_now_ms(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  struct timespec ts;
  if (timespec_get(&ts, TIME_UTC) != TIME_UTC) agc_fail(vm, "RUNTIME-INTERNAL", "cannot read the clock", span);
  return agc_int(floor_ms((int64_t)ts.tv_sec, ts.tv_nsec));
}

/*
 * One read of the monotonic clock, shared by monotonic_ms and monotonic_ns so
 * they cannot disagree. It gives whole seconds and a remainder under 10^9 ns.
 * Windows splits the counter before it scales: count * 10^9 overflows an Int
 * after about 15 minutes of uptime at the usual 10 MHz frequency, while
 * (count % frequency) * 10^9 stays small.
 */
static void read_monotonic(agc_vm *vm, uint32_t span, int64_t *seconds, int64_t *nanoseconds) {
#ifdef _WIN32
  LARGE_INTEGER count, frequency;
  if (!QueryPerformanceCounter(&count) || !QueryPerformanceFrequency(&frequency))
    agc_fail(vm, "RUNTIME-INTERNAL", "cannot read the clock", span);
  *seconds = count.QuadPart / frequency.QuadPart;
  *nanoseconds = (count.QuadPart % frequency.QuadPart) * 1000000000 / frequency.QuadPart;
#else
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) agc_fail(vm, "RUNTIME-INTERNAL", "cannot read the clock", span);
  *seconds = (int64_t)ts.tv_sec;
  *nanoseconds = ts.tv_nsec;
#endif
}

static agc_value builtin_monotonic_ms(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  int64_t seconds, nanoseconds;
  read_monotonic(vm, span, &seconds, &nanoseconds);
  return agc_int(floor_ms(seconds, nanoseconds));
}

static agc_value builtin_monotonic_ns(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  int64_t seconds, nanoseconds, total;
  read_monotonic(vm, span, &seconds, &nanoseconds);
  /* An Int holds about 292 years of nanoseconds from the clock's origin; the checks keep a wrong clock from being UB. */
  if (__builtin_mul_overflow(seconds, INT64_C(1000000000), &total) || __builtin_add_overflow(total, nanoseconds, &total))
    agc_fail(vm, "RUNTIME-INTERNAL", "the clock is out of range", span);
  return agc_int(total);
}

const agc_builtin agc_number_builtins[] = {
  {"Float.from_int", 1, builtin_float_from_int, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Float.to_int", 1, builtin_float_to_int, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Float.to_int!", 1, builtin_float_to_int_bang, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Int.bit_and", 2, builtin_int_bit_and, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Int.bit_or", 2, builtin_int_bit_or, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Int.bit_xor", 2, builtin_int_bit_xor, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Int.bit_not", 1, builtin_int_bit_not, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Int.shift_left", 2, builtin_int_shift_left, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Int.shift_right", 2, builtin_int_shift_right, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Int.shift_right_unsigned", 2, builtin_int_shift_right_unsigned, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Float.to_bits", 1, builtin_float_to_bits, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Float.from_bits", 1, builtin_float_from_bits, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Float.to_bits32", 1, builtin_float_to_bits32, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Float.from_bits32", 1, builtin_float_from_bits32, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Time.now_ms", 0, builtin_now_ms, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Time.monotonic_ms", 0, builtin_monotonic_ms, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Time.monotonic_ns", 0, builtin_monotonic_ns, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Random.int", 2, builtin_random_int, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"Random.float", 0, builtin_random_float, AGC_NATIVE_NONE, AGC_COST_NONE, false},
};

const size_t agc_number_builtin_count = sizeof agc_number_builtins / sizeof agc_number_builtins[0];

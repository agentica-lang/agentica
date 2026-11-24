/*
 * The Int, Float, Math, Time and Random builtins (agc_number_builtins). Service layer.
 * Design: docs/vm/02-reference-behavior.md §2.2 and
 * docs/vm/05-values-execution-builtins.md §7.4.
 */
#include "services.h"

#include <inttypes.h>
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

/* Random.seed: the seed of the run (rt->seed, set once before the run starts and never written after), not of the
   task: every task gives the same number, which --seed takes back to get the same random numbers. */
static agc_value builtin_random_seed(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_int((int64_t)vm->rt->seed);
}

/* BddScenario.srand (std/bdd only): this task's generator starts again from seed, as main's does under --seed
   (vm/launch.c). */
static agc_value builtin_random_srand(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  agc_random_seed(&vm->task->random, (uint64_t)agc_as_int(vm, args[0]));
  return agc_void();
}

static agc_value builtin_float_from_int(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_float((double)agc_as_int(vm, args[0]));
}

/* x as an Int: an ok Result, or with bang the Int itself. NaN and the infinities are RUNTIME-INVALID-NUMBER and a value
   outside Int is RUNTIME-INTEGER-OVERFLOW: an error Result, or with bang a halt at span. */
static agc_value float_value_to_int(agc_vm *vm, double x, uint32_t span, bool bang) {
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
  return agc_error_string(vm, AGC_KIND_NUMBER_RANGE, agc_make_string(message, n, n));
}

static agc_value builtin_float_to_int(agc_vm *vm, agc_value *args, uint32_t span) {
  return float_value_to_int(vm, agc_as_float(vm, args[0]), span, false);
}

static agc_value builtin_float_to_int_bang(agc_vm *vm, agc_value *args, uint32_t span) {
  return float_value_to_int(vm, agc_as_float(vm, args[0]), span, true);
}

/* Int.to_<type> for a narrow integer type (Int8 to UInt32), which the VM holds as an Int: the value when the type holds
   it, else an error Result, or with bang RUNTIME-INTEGER-OVERFLOW at span. */
static agc_value int_to_narrow(agc_vm *vm, agc_value value, const char *name, int64_t min, int64_t max, uint32_t span,
                               bool bang) {
  int64_t n = agc_as_int(vm, value);
  if (n >= min && n <= max) return bang ? value : agc_result_value(true, value);
  char text[96];
  int len = snprintf(text, sizeof text, "%" PRId64 " is outside %s, %" PRId64 " to %" PRId64, n, name, min, max);
  agc_string *message = agc_make_string(text, (size_t)len, (size_t)len);
  if (bang) agc_fail_text(vm, "RUNTIME-INTEGER-OVERFLOW", message, span);
  return agc_error_string(vm, AGC_KIND_NUMBER_RANGE, message);
}

#define INT_TO_NARROW(word, name, min, max)                                                    \
  static agc_value builtin_int_to_##word(agc_vm *vm, agc_value *args, uint32_t span) {        \
    return int_to_narrow(vm, args[0], name, min, max, span, false);                           \
  }                                                                                           \
  static agc_value builtin_int_to_##word##_bang(agc_vm *vm, agc_value *args, uint32_t span) { \
    return int_to_narrow(vm, args[0], name, min, max, span, true);                            \
  }

INT_TO_NARROW(int8, "Int8", INT8_MIN, INT8_MAX)
INT_TO_NARROW(int16, "Int16", INT16_MIN, INT16_MAX)
INT_TO_NARROW(int32, "Int32", INT32_MIN, INT32_MAX)
INT_TO_NARROW(uint8, "UInt8", 0, UINT8_MAX)
INT_TO_NARROW(uint16, "UInt16", 0, UINT16_MAX)
INT_TO_NARROW(uint32, "UInt32", 0, UINT32_MAX)

/* to_i on a narrow integer type: its value is an Int already. */
static agc_value builtin_int_from_narrow(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(agc_as_int(vm, args[0]));
}

/* floor, ceil and round give an Int, as Ruby's Float#floor gives an Integer; with no bignums a result outside Int
   halts, like to_i!. C round() takes halves away from zero, as Ruby's Float#round does. */
static agc_value builtin_float_floor(agc_vm *vm, agc_value *args, uint32_t span) {
  return float_value_to_int(vm, floor(agc_as_float(vm, args[0])), span, true);
}

static agc_value builtin_float_ceil(agc_vm *vm, agc_value *args, uint32_t span) {
  return float_value_to_int(vm, ceil(agc_as_float(vm, args[0])), span, true);
}

static agc_value builtin_float_round(agc_vm *vm, agc_value *args, uint32_t span) {
  return float_value_to_int(vm, round(agc_as_float(vm, args[0])), span, true);
}

static agc_value builtin_float_abs(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_float(fabs(agc_as_float(vm, args[0])));
}

/* Ruby's Comparable#clamp: min > max is an ArgumentError there and RUNTIME-INVALID-RANGE here, as for Random.int. A
   NaN bound fails the same way, since it orders with nothing; a NaN x is returned as it is, as other Float operations
   carry NaN. */
static agc_value builtin_float_clamp(agc_vm *vm, agc_value *args, uint32_t span) {
  double x = agc_as_float(vm, args[0]), low = agc_as_float(vm, args[1]), high = agc_as_float(vm, args[2]);
  if (!(low <= high)) agc_fail(vm, "RUNTIME-INVALID-RANGE", "clamp needs min <= max, and no NaN bound", span);
  if (x < low) return agc_float(low);
  if (x > high) return agc_float(high);
  return agc_float(x);
}

/* Ruby's Math.sqrt raises Math::DomainError below zero; here that is RUNTIME-INVALID-NUMBER at the argument, as a
   Float division by zero halts too. -0.0 is not below zero and gives the IEEE 754 result -0.0 (CRuby gives 0.0); NaN
   gives NaN. */
static agc_value builtin_math_sqrt(agc_vm *vm, agc_value *args, uint32_t span) {
  double x = agc_as_float(vm, args[0]);
  if (x < 0) agc_fail(vm, "RUNTIME-INVALID-NUMBER", "Math.sqrt of a negative number", span + 1);
  return agc_float(sqrt(x));
}

/* Ruby's Math.log and Math.log10 raise Math::DomainError below zero, as Math.sqrt does; 0.0 and -0.0 give -Infinity.
   exp, sin and cos have no domain error: NaN and infinity follow libm (sin and cos of infinity are NaN). */
static double math_log_arg(agc_vm *vm, agc_value *args, uint32_t span, const char *message) {
  double x = agc_as_float(vm, args[0]);
  if (x < 0) agc_fail(vm, "RUNTIME-INVALID-NUMBER", message, span + 1);
  return x;
}

static agc_value builtin_math_log(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_float(log(math_log_arg(vm, args, span, "Math.log of a negative number")));
}

static agc_value builtin_math_log10(agc_vm *vm, agc_value *args, uint32_t span) {
  return agc_float(log10(math_log_arg(vm, args, span, "Math.log10 of a negative number")));
}

static agc_value builtin_math_exp(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_float(exp(agc_as_float(vm, args[0])));
}

static agc_value builtin_math_sin(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_float(sin(agc_as_float(vm, args[0])));
}

static agc_value builtin_math_cos(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_float(cos(agc_as_float(vm, args[0])));
}

static _Noreturn void int_overflow(agc_vm *vm, uint32_t span) {
  agc_fail(vm, "RUNTIME-INTEGER-OVERFLOW", "Int result is outside the 64-bit range", span);
}

static agc_value builtin_int_abs(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t n = agc_as_int(vm, args[0]);
  if (n == INT64_MIN) int_overflow(vm, span);
  return agc_int(n < 0 ? -n : n);
}

/* Square and multiply. The base is squared only while bits of the exponent are left, and those bits multiply it into
   the result, so a base that overflows means the result would too (|n| >= 2); 0, 1 and -1 never overflow. */
static agc_value builtin_int_pow(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t base = agc_as_int(vm, args[0]), exponent = agc_as_int(vm, args[1]), result = 1;
  if (exponent < 0) agc_fail(vm, "RUNTIME-INVALID-COUNT", "pow needs an exponent >= 0", span + 2);
  while (exponent > 0) {
    if ((exponent & 1) && __builtin_mul_overflow(result, base, &result)) int_overflow(vm, span);
    exponent >>= 1;
    if (exponent > 0 && __builtin_mul_overflow(base, base, &base)) int_overflow(vm, span);
  }
  return agc_int(result);
}

/* Euclid on the magnitudes as uint64_t, so the least Int has one. Only gcd(least, 0) and gcd(least, least) give 2^63,
   which is no Int. */
static agc_value builtin_int_gcd(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t a = agc_as_int(vm, args[0]), b = agc_as_int(vm, args[1]);
  uint64_t x = a < 0 ? (uint64_t)0 - (uint64_t)a : (uint64_t)a;
  uint64_t y = b < 0 ? (uint64_t)0 - (uint64_t)b : (uint64_t)b;
  while (y != 0) {
    uint64_t rest = x % y;
    x = y;
    y = rest;
  }
  if (x > (uint64_t)INT64_MAX) int_overflow(vm, span);
  return agc_int((int64_t)x);
}

static agc_value builtin_int_clamp(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t n = agc_as_int(vm, args[0]), low = agc_as_int(vm, args[1]), high = agc_as_int(vm, args[2]);
  if (low > high) agc_fail(vm, "RUNTIME-INVALID-RANGE", "clamp needs min <= max", span);
  return agc_int(n < low ? low : n > high ? high : n);
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

/* wrapping_add, wrapping_sub and wrapping_mul keep the low 64 bits of the two's complement result. */
static agc_value builtin_int_wrapping_add(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(int_from_bits((uint64_t)agc_as_int(vm, args[0]) + (uint64_t)agc_as_int(vm, args[1])));
}

static agc_value builtin_int_wrapping_sub(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(int_from_bits((uint64_t)agc_as_int(vm, args[0]) - (uint64_t)agc_as_int(vm, args[1])));
}

static agc_value builtin_int_wrapping_mul(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_int(int_from_bits((uint64_t)agc_as_int(vm, args[0]) * (uint64_t)agc_as_int(vm, args[1])));
}

/* The low width bits of bits, read as a narrow integer type: a signed type takes the top of the width as its sign. */
static int64_t narrow_from_bits(uint64_t bits, unsigned width, bool is_signed) {
  uint64_t low = bits & (((uint64_t)1 << width) - 1);
  if (is_signed && (low >> (width - 1)) != 0) return (int64_t)low - ((int64_t)1 << width);
  return (int64_t)low;
}

/* The wrapping and shifting builtins of a narrow integer type (a value of the VM Int that the type holds): the Int
   operation on the 64-bit forms, then the low bits again. A shift count of the width or more drops every bit. */
#define NARROW_WRAP(word, width, is_signed)                                                           \
  static agc_value builtin_int_wrap_##word(agc_vm *vm, agc_value *args, uint32_t span) {                   \
    (void)span;                                                                                            \
    return agc_int(narrow_from_bits((uint64_t)agc_as_int(vm, args[0]), width, is_signed));                 \
  }                                                                                                        \
  static agc_value builtin_##word##_wrapping_add(agc_vm *vm, agc_value *args, uint32_t span) {             \
    (void)span;                                                                                            \
    uint64_t sum = (uint64_t)agc_as_int(vm, args[0]) + (uint64_t)agc_as_int(vm, args[1]);                  \
    return agc_int(narrow_from_bits(sum, width, is_signed));                                               \
  }                                                                                                        \
  static agc_value builtin_##word##_wrapping_sub(agc_vm *vm, agc_value *args, uint32_t span) {             \
    (void)span;                                                                                            \
    uint64_t difference = (uint64_t)agc_as_int(vm, args[0]) - (uint64_t)agc_as_int(vm, args[1]);           \
    return agc_int(narrow_from_bits(difference, width, is_signed));                                        \
  }                                                                                                        \
  static agc_value builtin_##word##_wrapping_mul(agc_vm *vm, agc_value *args, uint32_t span) {             \
    (void)span;                                                                                            \
    uint64_t product = (uint64_t)agc_as_int(vm, args[0]) * (uint64_t)agc_as_int(vm, args[1]);              \
    return agc_int(narrow_from_bits(product, width, is_signed));                                           \
  }                                                                                                        \
  static agc_value builtin_##word##_shift_left(agc_vm *vm, agc_value *args, uint32_t span) {               \
    uint64_t count = shift_count(vm, args, span);                                                          \
    uint64_t bits = (uint64_t)agc_as_int(vm, args[0]);                                                     \
    return agc_int(narrow_from_bits(count >= width ? 0 : bits << count, width, is_signed));                \
  }

NARROW_WRAP(int8, 8, true)
NARROW_WRAP(int16, 16, true)
NARROW_WRAP(int32, 32, true)
NARROW_WRAP(uint8, 8, false)
NARROW_WRAP(uint16, 16, false)
NARROW_WRAP(uint32, 32, false)

/* shift_right_unsigned on a signed type shifts its width bits as an unsigned number. On an unsigned type it is
   Int.shift_right_unsigned, and bit_not on a signed type is Int.bit_not. */
#define SIGNED_SHIFT_RIGHT_UNSIGNED(word, width)                                                           \
  static agc_value builtin_##word##_shift_right_unsigned(agc_vm *vm, agc_value *args, uint32_t span) {    \
    uint64_t count = shift_count(vm, args, span);                                                         \
    uint64_t low = (uint64_t)narrow_from_bits((uint64_t)agc_as_int(vm, args[0]), width, false);           \
    return agc_int(narrow_from_bits(count >= width ? 0 : low >> count, width, true));                     \
  }

SIGNED_SHIFT_RIGHT_UNSIGNED(int8, 8)
SIGNED_SHIFT_RIGHT_UNSIGNED(int16, 16)
SIGNED_SHIFT_RIGHT_UNSIGNED(int32, 32)

/* bit_not on an unsigned type flips the bits within its width. */
#define UNSIGNED_BIT_NOT(word, width)                                                             \
  static agc_value builtin_##word##_bit_not(agc_vm *vm, agc_value *args, uint32_t span) {         \
    (void)span;                                                                                   \
    return agc_int(narrow_from_bits(~(uint64_t)agc_as_int(vm, args[0]), width, false));           \
  }

UNSIGNED_BIT_NOT(uint8, 8)
UNSIGNED_BIT_NOT(uint16, 16)
UNSIGNED_BIT_NOT(uint32, 32)

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

/* The binary32 whose bits are the Int argument, which must be between 0 and 2^32 - 1. */
static float float_of_bits32(agc_vm *vm, agc_value arg, uint32_t span) {
  int64_t value = agc_as_int(vm, arg);
  if (value < 0 || value > UINT32_MAX)
    agc_fail(vm, "RUNTIME-INVALID-NUMBER", "bits must be between 0 and 4294967295", span + 1);
  uint32_t bits = (uint32_t)value;
  float narrow;
  memcpy(&narrow, &bits, sizeof narrow);
  return narrow;
}

static agc_value builtin_float_from_bits32(agc_vm *vm, agc_value *args, uint32_t span) {
  float narrow = float_of_bits32(vm, args[0], span);
  return agc_float(isnan(narrow) ? float64_from_bits(AGC_CANONICAL_NAN64) : (double)narrow);
}

static agc_value builtin_float_to_float32(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_float32(agc_round_f32(agc_as_float(vm, args[0])));
}

/* Rounded once, from the 64-bit integer: through a double, 2^53 + 2^29 + 1 would round twice, to 2^53. */
static agc_value builtin_int_to_float32(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_float32((double)(float)agc_as_int(vm, args[0]));
}

static agc_value builtin_float32_to_f(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  return agc_float(agc_as_float32(vm, args[0]));
}

static agc_value builtin_float32_to_bits(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  float narrow = (float)agc_as_float32(vm, args[0]);
  if (isnan(narrow)) return agc_int(AGC_CANONICAL_NAN32);
  uint32_t bits;
  memcpy(&bits, &narrow, sizeof bits);
  return agc_int(bits);
}

static agc_value builtin_float32_from_bits(agc_vm *vm, agc_value *args, uint32_t span) {
  float narrow = float_of_bits32(vm, args[0], span);
  return agc_float32(isnan(narrow) ? NAN : (double)narrow);
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

/* The coarse clock where the system has one and an exact read is a system call (agc_clock_coarse_ms: Linux with an
   HPET clock source, where that read takes about a microsecond); it lags by up to about two ticks (about 20 ms).
   Elsewhere the exact clock. */
static agc_value builtin_monotonic_ms(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  uint64_t coarse;
  if (agc_clock_coarse_ms(&coarse)) return agc_int((int64_t)coarse);
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
  /* A Time.monotonic_ms after it is never behind it. */
  agc_clock_note_ms((uint64_t)(total / 1000000));
  return agc_int(total);
}

const agc_builtin agc_number_builtins[] = {
  {"Float.from_int", 1, builtin_float_from_int, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float.to_int", 1, builtin_float_to_int, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float.to_int!", 1, builtin_float_to_int_bang, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.bit_and", 2, builtin_int_bit_and, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.bit_or", 2, builtin_int_bit_or, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.bit_xor", 2, builtin_int_bit_xor, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.bit_not", 1, builtin_int_bit_not, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.shift_left", 2, builtin_int_shift_left, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.shift_right", 2, builtin_int_shift_right, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.shift_right_unsigned", 2, builtin_int_shift_right_unsigned, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float.to_bits", 1, builtin_float_to_bits, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float.from_bits", 1, builtin_float_from_bits, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float.to_bits32", 1, builtin_float_to_bits32, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float.from_bits32", 1, builtin_float_from_bits32, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.from_narrow", 1, builtin_int_from_narrow, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float.to_float32", 1, builtin_float_to_float32, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_float32", 1, builtin_int_to_float32, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float32.to_f", 1, builtin_float32_to_f, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float32.to_bits", 1, builtin_float32_to_bits, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float32.from_bits", 1, builtin_float32_from_bits, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_int8", 1, builtin_int_to_int8, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_int8!", 1, builtin_int_to_int8_bang, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_int16", 1, builtin_int_to_int16, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_int16!", 1, builtin_int_to_int16_bang, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_int32", 1, builtin_int_to_int32, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_int32!", 1, builtin_int_to_int32_bang, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_uint8", 1, builtin_int_to_uint8, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_uint8!", 1, builtin_int_to_uint8_bang, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_uint16", 1, builtin_int_to_uint16, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_uint16!", 1, builtin_int_to_uint16_bang, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_uint32", 1, builtin_int_to_uint32, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.to_uint32!", 1, builtin_int_to_uint32_bang, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.wrapping_add", 2, builtin_int_wrapping_add, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.wrapping_sub", 2, builtin_int_wrapping_sub, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.wrapping_mul", 2, builtin_int_wrapping_mul, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.wrap_int8", 1, builtin_int_wrap_int8, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int8.wrapping_add", 2, builtin_int8_wrapping_add, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int8.wrapping_sub", 2, builtin_int8_wrapping_sub, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int8.wrapping_mul", 2, builtin_int8_wrapping_mul, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int8.shift_left", 2, builtin_int8_shift_left, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int8.shift_right_unsigned", 2, builtin_int8_shift_right_unsigned, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.wrap_int16", 1, builtin_int_wrap_int16, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int16.wrapping_add", 2, builtin_int16_wrapping_add, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int16.wrapping_sub", 2, builtin_int16_wrapping_sub, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int16.wrapping_mul", 2, builtin_int16_wrapping_mul, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int16.shift_left", 2, builtin_int16_shift_left, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int16.shift_right_unsigned", 2, builtin_int16_shift_right_unsigned, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.wrap_int32", 1, builtin_int_wrap_int32, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int32.wrapping_add", 2, builtin_int32_wrapping_add, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int32.wrapping_sub", 2, builtin_int32_wrapping_sub, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int32.wrapping_mul", 2, builtin_int32_wrapping_mul, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int32.shift_left", 2, builtin_int32_shift_left, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int32.shift_right_unsigned", 2, builtin_int32_shift_right_unsigned, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.wrap_uint8", 1, builtin_int_wrap_uint8, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt8.wrapping_add", 2, builtin_uint8_wrapping_add, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt8.wrapping_sub", 2, builtin_uint8_wrapping_sub, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt8.wrapping_mul", 2, builtin_uint8_wrapping_mul, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt8.shift_left", 2, builtin_uint8_shift_left, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt8.bit_not", 1, builtin_uint8_bit_not, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.wrap_uint16", 1, builtin_int_wrap_uint16, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt16.wrapping_add", 2, builtin_uint16_wrapping_add, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt16.wrapping_sub", 2, builtin_uint16_wrapping_sub, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt16.wrapping_mul", 2, builtin_uint16_wrapping_mul, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt16.shift_left", 2, builtin_uint16_shift_left, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt16.bit_not", 1, builtin_uint16_bit_not, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.wrap_uint32", 1, builtin_int_wrap_uint32, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt32.wrapping_add", 2, builtin_uint32_wrapping_add, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt32.wrapping_sub", 2, builtin_uint32_wrapping_sub, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt32.wrapping_mul", 2, builtin_uint32_wrapping_mul, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt32.shift_left", 2, builtin_uint32_shift_left, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"UInt32.bit_not", 1, builtin_uint32_bit_not, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.now_ms", 0, builtin_now_ms, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.monotonic_ms", 0, builtin_monotonic_ms, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Time.monotonic_ns", 0, builtin_monotonic_ns, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Random.int", 2, builtin_random_int, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Random.float", 0, builtin_random_float, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Random.seed", 0, builtin_random_seed, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"BddScenario.srand", 1, builtin_random_srand, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.abs", 1, builtin_int_abs, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.pow", 2, builtin_int_pow, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.gcd", 2, builtin_int_gcd, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Int.clamp", 3, builtin_int_clamp, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float.abs", 1, builtin_float_abs, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float.floor", 1, builtin_float_floor, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float.ceil", 1, builtin_float_ceil, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float.round", 1, builtin_float_round, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Float.clamp", 3, builtin_float_clamp, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Math.sqrt", 1, builtin_math_sqrt, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Math.exp", 1, builtin_math_exp, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Math.log", 1, builtin_math_log, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Math.log10", 1, builtin_math_log10, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Math.sin", 1, builtin_math_sin, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
  {"Math.cos", 1, builtin_math_cos, AGC_NATIVE_NONE, AGC_COST_NONE, false, true, false, false},
};

const size_t agc_number_builtin_count = sizeof agc_number_builtins / sizeof agc_number_builtins[0];

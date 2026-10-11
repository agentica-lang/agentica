#include "agc.h"

#include <math.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#endif

#define IM1 0xffffff2fu
#define IM2 0xffffa6bbu

static const double m1 = 4294967087.0;
static const double m2 = 4294944443.0;
static const double a12 = 1403580.0;
static const double a13n = 810728.0;
static const double a21 = 527612.0;
static const double a23n = 1370589.0;
static const double norm = 2.328306549295728e-10;

static uint32_t seed_word(uint32_t *x) {
  uint32_t y = *x & 0xFFFF;
  *x = 30903u * y + (*x >> 16);
  return y;
}

static uint32_t seed_draw(uint32_t *x, uint32_t n) {
  uint32_t high = seed_word(x);
  uint32_t low = seed_word(x);
  return ((high << 16) + low) % n;
}

static void seed_half(agc_random *r, uint32_t x) {
  r->x10 = (double)(1 + (((uint32_t)r->x10 + seed_draw(&x, IM1 - 1)) % (IM1 - 1)));
  r->x11 = (double)(((uint32_t)r->x11 + seed_draw(&x, IM1)) % IM1);
  r->x12 = (double)(((uint32_t)r->x12 + seed_draw(&x, IM1)) % IM1);
  r->x20 = (double)(1 + (((uint32_t)r->x20 + seed_draw(&x, IM2 - 1)) % (IM2 - 1)));
  r->x21 = (double)(((uint32_t)r->x21 + seed_draw(&x, IM2)) % IM2);
  r->x22 = (double)(((uint32_t)r->x22 + seed_draw(&x, IM2)) % IM2);
  if (r->x10 == 0.0 && r->x11 == 0.0 && r->x12 == 0.0) r->x10 = 1.0;
  if (r->x20 == 0.0 && r->x21 == 0.0 && r->x22 == 0.0) r->x20 = 1.0;
}

void agc_random_seed(agc_random *r, uint32_t seed) {
  r->x10 = 1062452522.0;
  r->x11 = 2961816100.0;
  r->x12 = 342112271.0;
  r->x20 = 2854655037.0;
  r->x21 = 3321940838.0;
  r->x22 = 3542344109.0;
  seed_half(r, seed & 0xFFFF);
  seed_half(r, (seed >> 16) & 0xFFFF);
}

static double mrg32k3a(agc_random *r) {
  double x10 = a12 * r->x11 - a13n * r->x12;
  double k10 = (double)(int64_t)(x10 / m1);
  x10 -= k10 * m1;
  if (x10 < 0.0) x10 += m1;
  r->x12 = r->x11;
  r->x11 = r->x10;
  r->x10 = x10;

  double x20 = a21 * r->x20 - a23n * r->x22;
  double k20 = (double)(int64_t)(x20 / m2);
  x20 -= k20 * m2;
  if (x20 < 0.0) x20 += m2;
  r->x22 = r->x21;
  r->x21 = r->x20;
  r->x20 = x20;

  double y = x10 - x20;
  if (y < 0.0) y += m1;
  return y;
}

double agc_random_float(agc_random *r) { return (mrg32k3a(r) + 1.0) * norm; }

uint64_t agc_random_below(agc_random *r, uint64_t n) {
  double q = (double)(uint64_t)(m1 / (double)n);
  double qn = q * (double)n;
  double x;
  do {
    x = mrg32k3a(r);
  } while (x >= qn);
  return (uint64_t)(x / q);
}

int64_t agc_random_int(agc_random *r, int64_t low, int64_t high) {
  unsigned __int128 size = (unsigned __int128)((__int128)high - low + 1);
  if (size <= 4294967087u) return (int64_t)((__int128)low + agc_random_below(r, (uint64_t)size));
  unsigned __int128 space = (unsigned __int128)1 << 64;
  unsigned __int128 limit = size * (space / size);
  for (;;) {
    unsigned __int128 bits = 0;
    for (int k = 0; k < 4; k++) bits = bits * 65536 + agc_random_below(r, 65536);
    if (bits < limit) return (int64_t)((__int128)low + (__int128)(bits % size));
  }
}

static agc_value builtin_random_int(agc_vm *vm, agc_value *args, uint32_t span) {
  int64_t low = agc_as_int(vm, args[0]);
  int64_t high = agc_as_int(vm, args[1]);
  if (low > high) agc_fail(vm, "RUNTIME-INVALID-RANGE", "Random.int needs min <= max", span);
  return agc_int(agc_random_int(&vm->random, low, high));
}

static agc_value builtin_random_float(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  return agc_float(agc_random_float(&vm->random));
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

static int64_t floor_ms(int64_t seconds, int64_t nanoseconds) { return seconds * 1000 + nanoseconds / 1000000; }

static agc_value builtin_now_ms(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  struct timespec ts;
  if (timespec_get(&ts, TIME_UTC) != TIME_UTC) agc_fail(vm, "RUNTIME-INTERNAL", "cannot read the clock", span);
  return agc_int(floor_ms((int64_t)ts.tv_sec, ts.tv_nsec));
}

static agc_value builtin_monotonic_ms(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
#ifdef _WIN32
  LARGE_INTEGER count, frequency;
  if (!QueryPerformanceCounter(&count) || !QueryPerformanceFrequency(&frequency))
    agc_fail(vm, "RUNTIME-INTERNAL", "cannot read the clock", span);
  return agc_int(floor_ms(count.QuadPart / frequency.QuadPart,
                          (count.QuadPart % frequency.QuadPart) * 1000000000 / frequency.QuadPart));
#else
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) agc_fail(vm, "RUNTIME-INTERNAL", "cannot read the clock", span);
  return agc_int(floor_ms((int64_t)ts.tv_sec, ts.tv_nsec));
#endif
}

const agc_builtin agc_number_builtins[] = {
  {"Float.from_int", 1, builtin_float_from_int, AGC_NATIVE_NONE},
  {"Float.to_int", 1, builtin_float_to_int, AGC_NATIVE_NONE},
  {"Float.to_int!", 1, builtin_float_to_int_bang, AGC_NATIVE_NONE},
  {"Time.now_ms", 0, builtin_now_ms, AGC_NATIVE_NONE},
  {"Time.monotonic_ms", 0, builtin_monotonic_ms, AGC_NATIVE_NONE},
  {"Random.int", 2, builtin_random_int, AGC_NATIVE_NONE},
  {"Random.float", 0, builtin_random_float, AGC_NATIVE_NONE},
};

const size_t agc_number_builtin_count = sizeof agc_number_builtins / sizeof agc_number_builtins[0];

#include "services.h"

#include <math.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <windows.h>
#endif

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
  {"Float.from_int", 1, builtin_float_from_int, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Float.to_int", 1, builtin_float_to_int, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Float.to_int!", 1, builtin_float_to_int_bang, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Time.now_ms", 0, builtin_now_ms, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Time.monotonic_ms", 0, builtin_monotonic_ms, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Random.int", 2, builtin_random_int, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Random.float", 0, builtin_random_float, AGC_NATIVE_NONE, AGC_COST_NONE},
};

const size_t agc_number_builtin_count = sizeof agc_number_builtins / sizeof agc_number_builtins[0];

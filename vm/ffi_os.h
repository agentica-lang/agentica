/*
 * The platform half of the native calls (docs/grammar/06d-io-and-network.md,
 * "Native code"): open a library, find a symbol and call it with C values.
 * ffi_libffi.c does it with dlopen and libffi where the build has libffi
 * (AGC_FFI: Linux x86_64 for now); ffi_none.c says no elsewhere. No VM values.
 */
#ifndef AGC_FFI_OS_H
#define AGC_FFI_OS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The C types of an extern signature: C.Int is int32_t, C.Int64 int64_t, C.Double double, C.Bool _Bool and C.String
   a NUL-terminated char *. Void is for results only. */
/* The most parameters an extern function may have. */
#define AGC_FFI_MAX_PARAMS 64

typedef enum { AGC_C_VOID, AGC_C_INT, AGC_C_INT64, AGC_C_DOUBLE, AGC_C_BOOL, AGC_C_STRING } agc_c_type;

typedef union {
  int32_t i;
  int64_t l;
  double d;
  bool b;
  const char *s;
} agc_c_value;

/* A prepared call: the function and its signature, in malloc memory that lives as long as the process. */
typedef struct agc_ffi_call agc_ffi_call;

/* True when this build can call native code. */
bool agc_ffi_supported(void);

/* Opens LIBRARY (a name the system loader searches, or a path with a "/"), finds SYMBOL in it and prepares the call
   of RESULT SYMBOL(PARAMS[0..COUNT)). NULL with a message in ERROR (SIZE bytes) when the library or the symbol is
   missing, COUNT is above AGC_FFI_MAX_PARAMS or the build cannot call native code. A library stays open until the process ends. */
agc_ffi_call *agc_ffi_prepare(const char *library, const char *symbol, agc_c_type result, const agc_c_type *params,
                              uint32_t count, char *error, size_t size);

/* Calls the prepared function with ARGS (one per parameter) and stores its result in RESULT (untouched for Void). */
void agc_ffi_invoke(agc_ffi_call *call, agc_c_value *args, agc_c_value *result);

#endif

/*
 * The platform half of the native calls (docs/grammar/06d-io-and-network.md,
 * "Native code"): open a library, find a symbol and call it with C values.
 * ffi_libffi.c does it with the system loader and libffi where the build has
 * libffi (AGC_FFI: Linux x86_64, Windows x64 and macOS); ffi_none.c says no
 * elsewhere. No VM values.
 */
#ifndef AGC_FFI_OS_H
#define AGC_FFI_OS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The most parameters an extern function may have. */
#define AGC_FFI_MAX_PARAMS 64

/* The C types of an extern signature: C.Int32 is int32_t, C.Int64 int64_t, C.Double double, C.Float float, C.Bool _Bool
   and C.String a NUL-terminated char *. C.Pointer, C.Bytes (a const uint8_t *) and a resource are each a pointer in C.
   Void is for results only, and C.Bytes for parameters only. */
typedef enum {
  AGC_C_VOID, AGC_C_INT, AGC_C_INT64, AGC_C_DOUBLE, AGC_C_FLOAT, AGC_C_BOOL, AGC_C_STRING, AGC_C_POINTER, AGC_C_BYTES,
  AGC_C_RESOURCE
} agc_c_type;

typedef union {
  int32_t i;
  int64_t l;
  double d;
  float f;
  bool b;
  const char *s;
  void *p;
} agc_c_value;

/* A prepared call: the function and its signature, in malloc memory that lives as long as the process. */
typedef struct agc_ffi_call agc_ffi_call;

/* True when this build can call native code. */
bool agc_ffi_supported(void);

/* The FIXED of agc_ffi_prepare for a function that is not variadic. */
#define AGC_FFI_NOT_VARIADIC UINT32_MAX

/* Opens LIBRARY (a name the system loader searches, or a path: with a "/", and on Windows also a "\" or a drive),
   finds SYMBOL in it and prepares the call of RESULT SYMBOL(PARAMS[0..COUNT)). A variadic function has FIXED
   parameters before its `...` (1 to COUNT), the others AGC_FFI_NOT_VARIADIC. NULL with a message in ERROR (SIZE
   bytes) when the library or the symbol is missing, COUNT is above AGC_FFI_MAX_PARAMS or the build cannot call native
   code. A library that holds SYMBOL stays open until the process ends. */
agc_ffi_call *agc_ffi_prepare(const char *library, const char *symbol, agc_c_type result, const agc_c_type *params,
                              uint32_t count, uint32_t fixed, char *error, size_t size);

/* Frees a prepared call that no run uses (the free function of a resource was not found), and gives back its hold on
   the library. */
void agc_ffi_discard(agc_ffi_call *call);

/* Calls the prepared function with ARGS (one per parameter) and stores its result in RESULT (untouched for Void). */
void agc_ffi_invoke(agc_ffi_call *call, agc_c_value *args, agc_c_value *result);

#endif

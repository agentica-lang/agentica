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
   Void is for results only, and C.Bytes for parameters only. A struct is passed and returned by value (agc_c_struct). */
typedef enum {
  AGC_C_VOID, AGC_C_INT, AGC_C_INT64, AGC_C_DOUBLE, AGC_C_FLOAT, AGC_C_BOOL, AGC_C_STRING, AGC_C_POINTER, AGC_C_BYTES,
  AGC_C_RESOURCE, AGC_C_STRUCT
} agc_c_type;

/* A C struct of a signature, in malloc memory: COUNT fields in order, each AGC_C_INT to AGC_C_BOOL, AGC_C_POINTER or
   AGC_C_STRUCT (its layout in nested[k], NULL for the others). agc_ffi_prepare fills size, align and offsets[k], as
   libffi lays the struct out by the C rules of the platform. INDEX is the program's struct that it is (ffi.c's; the
   adapter ignores it), and POINTERS counts its C.Pointer fields, nested ones included. */
typedef struct agc_c_struct {
  uint32_t count, index, pointers;
  size_t size, align;
  size_t *offsets;
  struct agc_c_struct **nested;
  agc_c_type *types;
} agc_c_struct;

typedef union {
  int32_t i;
  int64_t l;
  double d;
  float f;
  bool b;
  const char *s;
  void *p;
} agc_c_value;

/* The bytes the buffer of a struct result of SIZE bytes takes: libffi may store a whole register for a small one. */
#define AGC_FFI_RESULT_SIZE(size) ((size) < 16 ? (size_t)16 : (((size) + 15) & ~(size_t)15))

/* A prepared call: the function and its signature, in malloc memory that lives as long as the process. */
typedef struct agc_ffi_call agc_ffi_call;

/* True when this build can call native code. */
bool agc_ffi_supported(void);

/* The FIXED of agc_ffi_prepare for a function that is not variadic. */
#define AGC_FFI_NOT_VARIADIC UINT32_MAX

/* Opens LIBRARY (a name the system loader searches, or a path: with a "/", and on Windows also a "\" or a drive),
   finds SYMBOL in it and prepares the call of RESULT SYMBOL(PARAMS[0..COUNT)). A struct result has its layout in
   RESULT_STRUCT and a struct parameter in STRUCTS[k] (STRUCTS may be NULL when there is none); their sizes, alignments
   and offsets are filled here, and they must live as long as the call. A variadic function has FIXED
   parameters before its `...` (1 to COUNT), the others AGC_FFI_NOT_VARIADIC. NULL with a message in ERROR (SIZE
   bytes) when the library or the symbol is missing, COUNT is above AGC_FFI_MAX_PARAMS or the build cannot call native
   code. A library that holds SYMBOL stays open until the process ends. A NULL SYMBOL prepares only the signature, for
   a function whose address agc_ffi_invoke gets (a C function pointer): no library is opened then. */
agc_ffi_call *agc_ffi_prepare(const char *library, const char *symbol, agc_c_type result, const agc_c_type *params,
                              uint32_t count, uint32_t fixed, agc_c_struct *result_struct,
                              agc_c_struct *const *structs, char *error, size_t size);

/* Frees a prepared call that no run uses (the free function of a resource was not found), and gives back its hold on
   the library. */
void agc_ffi_discard(agc_ffi_call *call);

/* Calls the function at FN, or the prepared one when FN is NULL, with ARGS (one per parameter) and stores its result
   in RESULT (untouched for Void). A struct argument is a pointer (.p) to its bytes, laid out at the prepared offsets.
   A struct result is written to RESULT->p, which the caller points at AGC_FFI_RESULT_SIZE(size) bytes aligned to 16.
   A call prepared without a symbol always gets an FN, which must not be NULL. */
void agc_ffi_invoke(agc_ffi_call *call, void *fn, agc_c_value *args, agc_c_value *result);

#endif

/*
 * The platform half of the native calls (docs/grammar/06d-io-and-network.md,
 * "Native code"): open a library, find a symbol and call it with C values.
 * ffi_libffi.c does it with the system loader and libffi where the build has
 * libffi (AGC_FFI: Linux and macOS on x86_64 and arm64, Windows x64);
 * ffi_none.c says no elsewhere. No VM values.
 */
#ifndef AGC_FFI_OS_H
#define AGC_FFI_OS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The most parameters an extern function may have. */
#define AGC_FFI_MAX_PARAMS 64

/* The C types of an extern signature: C.Int32 is int32_t, C.Int64 int64_t, C.Int8 int8_t, C.Int16 int16_t, C.UInt8
   uint8_t, C.UInt16 uint16_t, C.UInt32 uint32_t, C.Long long (32 bits on Windows, 64 elsewhere), C.Double double,
   C.Float float, C.Bool _Bool and C.String a NUL-terminated char *. C.Pointer, C.Bytes (a const uint8_t *) and a
   resource are each a pointer in C. Void is for results only, and C.Bytes for parameters only. A struct is passed and
   returned by value (agc_c_struct). */
typedef enum {
  AGC_C_VOID, AGC_C_INT, AGC_C_INT64, AGC_C_DOUBLE, AGC_C_FLOAT, AGC_C_BOOL, AGC_C_STRING, AGC_C_POINTER, AGC_C_BYTES,
  AGC_C_RESOURCE, AGC_C_STRUCT, AGC_C_INT8, AGC_C_INT16, AGC_C_UINT8, AGC_C_UINT16, AGC_C_UINT32, AGC_C_LONG
} agc_c_type;

/* A C struct of a signature, in malloc memory: COUNT fields in order, each an integer type, AGC_C_DOUBLE,
   AGC_C_FLOAT, AGC_C_BOOL, AGC_C_POINTER or AGC_C_STRUCT (its layout in nested[k], NULL for the others).
   agc_ffi_prepare (or agc_ffi_layout) fills size, align and offsets[k], as libffi lays the struct out by the C rules
   of the platform.
   INDEX is the program's struct that it is (ffi.c's; the adapter ignores it), and POINTERS counts its C.Pointer
   fields, nested ones included. */
typedef struct agc_c_struct {
  uint32_t count, index, pointers;
  size_t size, align;
  size_t *offsets;
  struct agc_c_struct **nested;
  agc_c_type *types;
} agc_c_struct;

/* One C value; every member starts at the first byte, so a pointer to the union is a pointer to any member. */
typedef union {
  int32_t i;
  int64_t l;
  int8_t i8;
  int16_t i16;
  uint8_t u8;
  uint16_t u16;
  uint32_t u32;
  long n;
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

/* Fills the size, alignment and offsets of S and its nested structs as agc_ffi_prepare does for a struct argument,
   without a call: the layout of Native.size_of, get_struct and put_struct. False when the build cannot call native
   code or libffi refuses the struct. */
bool agc_ffi_layout(agc_c_struct *s);

/* Opens LIBRARY as agc_ffi_prepare does and keeps it open until the process ends, so the calls prepared later find it
   loaded (Native.load). False with the loader's message in ERROR (SIZE bytes) when it cannot be opened or the build
   cannot call native code. */
bool agc_ffi_open(const char *library, char *error, size_t size);

/* Frees a prepared call that no run uses (the free function of a resource was not found), and gives back its hold on
   the library. */
void agc_ffi_discard(agc_ffi_call *call);

/* Calls the function at FN, or the prepared one when FN is NULL, with ARGS (one per parameter) and stores its result
   in RESULT (untouched for Void). A struct argument is a pointer (.p) to its bytes, laid out at the prepared offsets.
   A struct result is written to RESULT->p, which the caller points at AGC_FFI_RESULT_SIZE(size) bytes aligned to 16.
   A call prepared without a symbol always gets an FN, which must not be NULL. */
void agc_ffi_invoke(agc_ffi_call *call, void *fn, agc_c_value *args, agc_c_value *result);

/* A C function made at run time that calls HANDLER (a libffi closure): C calls it at agc_ffi_closure_code with the
   signature RESULT (PARAMS[0..COUNT)), each an integer type, AGC_C_DOUBLE, AGC_C_FLOAT, AGC_C_BOOL, AGC_C_STRING
   or AGC_C_POINTER (and AGC_C_VOID for the result), and HANDLER gets DATA, the arguments as C values (a C.String is
   C's pointer, which may be NULL) and the result to fill, which starts zeroed. No page of its memory is ever
   writable and executable at once: the code is written on a page mapped read-write, which is then sealed
   read-execute (on Apple arm64, libffi's trampoline table, whose code pages are mapped from libffi's image). In
   malloc and mapped memory, never GC memory: DATA must be kept alive by the caller. */
typedef struct agc_ffi_closure agc_ffi_closure;
typedef void (*agc_ffi_handler)(void *data, const agc_c_value *args, agc_c_value *result);

/* A closure, or NULL with a message in ERROR (SIZE bytes) when COUNT is above AGC_FFI_MAX_PARAMS, the system gives
   no memory for its code or the build cannot call native code. */
agc_ffi_closure *agc_ffi_closure_new(agc_c_type result, const agc_c_type *params, uint32_t count,
                                     agc_ffi_handler handler, void *data, char *error, size_t size);

/* The address that C calls. */
void *agc_ffi_closure_code(const agc_ffi_closure *closure);

/* Frees the closure and the memory of its code: C must not call it any more. Any thread may call it. */
void agc_ffi_closure_free(agc_ffi_closure *closure);

#endif

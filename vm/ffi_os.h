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

/* The C types of an extern signature: C.Int is int32_t, C.Int64 int64_t, C.Double double, C.Bool _Bool and C.String
   a NUL-terminated char *. C.Pointer, C.Bytes (a const uint8_t *) and a resource are each a pointer in C. Void is for
   results only, and C.Bytes for parameters only. */
typedef enum {
  AGC_C_VOID, AGC_C_INT, AGC_C_INT64, AGC_C_DOUBLE, AGC_C_BOOL, AGC_C_STRING, AGC_C_POINTER, AGC_C_BYTES, AGC_C_RESOURCE
} agc_c_type;

typedef union {
  int32_t i;
  int64_t l;
  double d;
  bool b;
  const char *s;
  void *p;
} agc_c_value;

/* A prepared call: the function and its signature, in malloc memory that lives as long as the process. */
typedef struct agc_ffi_call agc_ffi_call;

/* True when this build can call native code. */
bool agc_ffi_supported(void);

/* Opens LIBRARY (a name the system loader searches, or a path: with a "/", and on Windows also a "\" or a drive),
   finds SYMBOL in it and prepares the call of RESULT SYMBOL(PARAMS[0..COUNT)). NULL with a message in ERROR (SIZE
   bytes) when the library or the symbol is missing, COUNT is above AGC_FFI_MAX_PARAMS or the build cannot call native
   code. A library that holds SYMBOL stays open until the process ends. */
agc_ffi_call *agc_ffi_prepare(const char *library, const char *symbol, agc_c_type result, const agc_c_type *params,
                              uint32_t count, char *error, size_t size);

/* Frees a prepared call that no run uses (the free function of a resource was not found), and gives back its hold on
   the library. */
void agc_ffi_discard(agc_ffi_call *call);

/* Calls the prepared function with ARGS (one per parameter) and stores its result in RESULT (untouched for Void). */
void agc_ffi_invoke(agc_ffi_call *call, agc_c_value *args, agc_c_value *result);

/* The descriptor that a Native.wait_* polls in place of FD, which stays as the native code left it: a new open of
   the same file with FD's access mode (non-blocking, close-on-exec), so FD's own flags do not change. A socket, a
   pipe on macOS, and a file that cannot be opened again (an eventfd, a FIFO with no reader), get a duplicate instead,
   which shares FD's flags: polling a socket puts both in non-blocking mode (the macOS loop polls a pipe with poll(2),
   which leaves its flags alone). -1 with errno when neither works (EBADF for a closed FD, ENOSYS in a
   build without native calls, and on Windows for now). wait_fd_close closes what wait_fd_open returned. */
int agc_ffi_wait_fd_open(int fd);
void agc_ffi_wait_fd_close(int fd);

#endif

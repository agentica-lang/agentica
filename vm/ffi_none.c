/*
 * The native calls of a build without libffi (every system but Linux x86_64,
 * Windows x64 and macOS): nothing can be prepared, so a program
 * with extern functions is refused at load (agc_ffi_refusal). Adapter layer;
 * the other half is ffi_libffi.c.
 */
#ifndef AGC_FFI
#include "ffi_os.h"

#include <stdio.h>

bool agc_ffi_supported(void) { return false; }

agc_ffi_call *agc_ffi_prepare(const char *library, const char *symbol, agc_c_type result, const agc_c_type *params,
                              uint32_t count, char *error, size_t size) {
  (void)library;
  (void)symbol;
  (void)result;
  (void)params;
  (void)count;
  snprintf(error, size, "native calls are not supported on this system yet");
  return NULL;
}

void agc_ffi_discard(agc_ffi_call *call) { (void)call; }

void agc_ffi_invoke(agc_ffi_call *call, agc_c_value *args, agc_c_value *result) {
  (void)call;
  (void)args;
  (void)result;
}
#endif

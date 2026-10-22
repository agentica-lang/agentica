/*
 * The native calls of a build with libffi (AGC_FFI, Linux x86_64 for now):
 * dlopen and dlsym find the function, ffi_prep_cif describes its signature
 * once and ffi_call calls it. Adapter layer; ffi.c converts the values and
 * ffi_none.c is the other half. Design: docs/grammar/06d-io-and-network.md.
 */
#ifdef AGC_FFI
#include "ffi_os.h"
#include "value.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <ffi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* The cif points at types, so both live in one block. */
struct agc_ffi_call {
  void *lib;
  void (*fn)(void);
  agc_c_type result;
  uint32_t count;
  ffi_cif cif;
  ffi_type *types[AGC_FFI_MAX_PARAMS];
};

static ffi_type *ffi_type_of(agc_c_type type) {
  switch (type) {
    case AGC_C_INT: return &ffi_type_sint32;
    case AGC_C_INT64: return &ffi_type_sint64;
    case AGC_C_DOUBLE: return &ffi_type_double;
    case AGC_C_BOOL: return &ffi_type_uint8;
    case AGC_C_STRING:
    case AGC_C_POINTER:
    case AGC_C_BYTES:
    case AGC_C_RESOURCE: return &ffi_type_pointer;
    case AGC_C_VOID: break;
  }
  return &ffi_type_void;
}

bool agc_ffi_supported(void) { return true; }

agc_ffi_call *agc_ffi_prepare(const char *library, const char *symbol, agc_c_type result, const agc_c_type *params,
                              uint32_t count, char *error, size_t size) {
  if (count > AGC_FFI_MAX_PARAMS) {
    snprintf(error, size, "%s has more than %d parameters", symbol, AGC_FFI_MAX_PARAMS);
    return NULL;
  }
  /* RTLD_NOW binds every symbol of the library at once, so a missing dependency is a load error here and not a
     crash at its first use. A library that holds the function is never closed: a prepared call keeps pointing into
     it until the process ends. */
  void *lib = dlopen(library, RTLD_NOW | RTLD_LOCAL);
  if (!lib) {
    const char *why = dlerror();
    snprintf(error, size, "cannot open %s: %s", library, why ? why : "unknown error");
    return NULL;
  }
  dlerror();
  void *found = dlsym(lib, symbol);
  if (!found) {
    const char *why = dlerror();
    snprintf(error, size, "%s has no function %s: %s", library, symbol, why ? why : "the symbol is NULL");
    /* dlopen counts references: closing drops only this one, so a failing call repeated in a loop leaks nothing. */
    dlclose(lib);
    return NULL;
  }
  agc_ffi_call *call = malloc(sizeof(agc_ffi_call));
  if (!call) agc_out_of_memory();
  /* ISO C cannot convert an object pointer to a function pointer; POSIX guarantees that dlsym's result can be. */
  memcpy(&call->fn, &found, sizeof call->fn);
  call->lib = lib;
  call->result = result;
  call->count = count;
  for (uint32_t k = 0; k < count; k++) call->types[k] = ffi_type_of(params[k]);
  if (ffi_prep_cif(&call->cif, FFI_DEFAULT_ABI, count, ffi_type_of(result), call->types) != FFI_OK) {
    free(call);
    dlclose(lib);
    snprintf(error, size, "cannot describe the signature of %s", symbol);
    return NULL;
  }
  return call;
}

void agc_ffi_discard(agc_ffi_call *call) {
  dlclose(call->lib);
  free(call);
}

void agc_ffi_invoke(agc_ffi_call *call, agc_c_value *args, agc_c_value *result) {
  /* ffi_call reads each argument through a pointer to it: every member of the union starts at its first byte, so a
     pointer to the union is a pointer to the member that ffi_type_of named. An integer result is widened to a whole
     ffi_arg, so it goes through a buffer of that size first. */
  void *slots[AGC_FFI_MAX_PARAMS];
  for (uint32_t k = 0; k < call->count; k++) slots[k] = &args[k];
  ffi_arg word = 0;
  double real = 0;
  void *pointer = NULL;
  void *out = &word;
  bool pointed = call->result == AGC_C_STRING || call->result == AGC_C_POINTER || call->result == AGC_C_RESOURCE;
  if (call->result == AGC_C_DOUBLE) out = &real;
  if (pointed) out = &pointer;
  ffi_call(&call->cif, call->fn, out, slots);
  switch (call->result) {
    case AGC_C_INT: result->i = (int32_t)word; break;
    case AGC_C_INT64: result->l = (int64_t)word; break;
    case AGC_C_DOUBLE: result->d = real; break;
    case AGC_C_BOOL: result->b = (word & 0xFF) != 0; break;
    case AGC_C_STRING: result->s = pointer; break;
    case AGC_C_POINTER:
    case AGC_C_RESOURCE: result->p = pointer; break;
    case AGC_C_BYTES:
    case AGC_C_VOID: break;
  }
}

/* /proc/self/fd/N opens the file again (a pipe, a terminal), with an open file description of its own; a socket
   cannot be opened that way. */
int agc_ffi_wait_fd_open(int fd) {
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0) return -1;
  struct stat info;
  if (fstat(fd, &info) == 0 && !S_ISSOCK(info.st_mode)) {
    char path[32];
    snprintf(path, sizeof path, "/proc/self/fd/%d", fd);
    int again = open(path, (flags & O_ACCMODE) | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
    if (again >= 0) return again;
  }
  return fcntl(fd, F_DUPFD_CLOEXEC, 3);
}

void agc_ffi_wait_fd_close(int fd) { (void)close(fd); }
#endif

/*
 * The native calls of a build with libffi (AGC_FFI: Linux x86_64, Windows x64 and macOS): the loader (dlopen and
 * dlsym, or LoadLibraryExW and GetProcAddress) finds the function, ffi_prep_cif (ffi_prep_cif_var for a variadic one)
 * describes its signature once and ffi_call calls it, or the function at the address of a C function pointer.
 * Adapter layer; ffi.c converts the values and ffi_none.c is the other half. Design:
 * docs/grammar/06d-io-and-network.md.
 */
#ifdef AGC_FFI
#include "ffi_os.h"
#include "value.h"

#include <errno.h>
#include <ffi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include "file_io.h"

#include <windows.h>
#else
#include <dlfcn.h>

/* The paths that the POSIX half builds: PATH_MAX on macOS. */
#define PATH_BUF 1024
#endif

/* The cif points at types, so both live in one block; the ffi_type of each struct and its elements are in one more
   malloc block (aggregates, NULL without structs), which lives as long as the call. */
struct agc_ffi_call {
  void *lib;
  void (*fn)(void);
  agc_c_type result;
  uint32_t count;
  ffi_cif cif;
  ffi_type *types[AGC_FFI_MAX_PARAMS];
  agc_c_type params[AGC_FFI_MAX_PARAMS];
  void *aggregates;
};

/* Where the ffi_types of the structs of a call are made: NODES, then the element lists, in one block. */
typedef struct {
  ffi_type *nodes;
  ffi_type **elements;
} aggregate_space;

static ffi_type *ffi_type_of(agc_c_type type) {
  switch (type) {
    case AGC_C_INT: return &ffi_type_sint32;
    case AGC_C_INT64: return &ffi_type_sint64;
    case AGC_C_DOUBLE: return &ffi_type_double;
    case AGC_C_FLOAT: return &ffi_type_float;
    case AGC_C_BOOL: return &ffi_type_uint8;
    case AGC_C_STRING:
    case AGC_C_POINTER:
    case AGC_C_BYTES:
    case AGC_C_RESOURCE: return &ffi_type_pointer;
    case AGC_C_STRUCT:
    case AGC_C_VOID: break;
  }
  return &ffi_type_void;
}

/* The ffi_type nodes and element slots (each list ends with NULL) that the struct S takes, nested ones included. */
static void aggregate_count(const agc_c_struct *s, size_t *nodes, size_t *elements) { // NOLINT(misc-no-recursion)
  *nodes += 1;
  *elements += s->count + 1;
  for (uint32_t k = 0; k < s->count; k++)
    if (s->types[k] == AGC_C_STRUCT) aggregate_count(s->nested[k], nodes, elements);
}

/* The FFI_TYPE_STRUCT of S, made in SPACE. Size and alignment are 0: ffi_prep_cif computes them. */
static ffi_type *aggregate_make(const agc_c_struct *s, aggregate_space *space) { // NOLINT(misc-no-recursion)
  ffi_type *t = space->nodes++;
  t->size = 0;
  t->alignment = 0;
  t->type = FFI_TYPE_STRUCT;
  t->elements = space->elements;
  space->elements += s->count + 1;
  for (uint32_t k = 0; k < s->count; k++)
    t->elements[k] = s->types[k] == AGC_C_STRUCT ? aggregate_make(s->nested[k], space) : ffi_type_of(s->types[k]);
  t->elements[s->count] = NULL;
  return t;
}

/* Copies libffi's layout of T, which ffi_prep_cif has computed, into S and its nested structs: the size, the
   alignment and each field's offset. */
static bool aggregate_layout(agc_c_struct *s, ffi_type *t) { // NOLINT(misc-no-recursion)
  if (ffi_get_struct_offsets(FFI_DEFAULT_ABI, t, s->offsets) != FFI_OK) return false;
  s->size = t->size;
  s->align = t->alignment;
  for (uint32_t k = 0; k < s->count; k++)
    if (s->types[k] == AGC_C_STRUCT && !aggregate_layout(s->nested[k], t->elements[k])) return false;
  return true;
}

/* Makes the ffi_type of every struct of the call (the result's, then each parameter's) in one malloc block, kept in
   CALL->aggregates. *RESULT_TYPE is the result's type. */
static void aggregates_make(agc_ffi_call *call, agc_c_type result, agc_c_struct *result_struct,
                            agc_c_struct *const *structs, const agc_c_type *params, ffi_type **result_type) {
  size_t nodes = 0, elements = 0;
  if (result == AGC_C_STRUCT) aggregate_count(result_struct, &nodes, &elements);
  for (uint32_t k = 0; k < call->count; k++)
    if (params[k] == AGC_C_STRUCT) aggregate_count(structs[k], &nodes, &elements);
  call->aggregates = NULL;
  if (!nodes) return;
  /* At most 65 top-level structs of 1024 fields each (ffi.c): the sizes cannot overflow. */
  call->aggregates = malloc(nodes * sizeof(ffi_type) + elements * sizeof(ffi_type *));
  if (!call->aggregates) agc_out_of_memory();
  aggregate_space space = {call->aggregates, (ffi_type **)(void *)((ffi_type *)call->aggregates + nodes)};
  if (result == AGC_C_STRUCT) *result_type = aggregate_make(result_struct, &space);
  for (uint32_t k = 0; k < call->count; k++)
    if (params[k] == AGC_C_STRUCT) call->types[k] = aggregate_make(structs[k], &space);
}

#ifdef _WIN32
/* The text of the Windows error CODE in UTF-8, without its line break, in BUF (SIZE bytes). */
static const char *windows_error(DWORD code, char *buf, size_t size) {
  wchar_t text[256];
  DWORD n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code, 0, text,
                           sizeof text / sizeof text[0], NULL);
  while (n && (text[n - 1] == L'\r' || text[n - 1] == L'\n' || text[n - 1] == L' ' || text[n - 1] == L'.')) n--;
  int len = n ? WideCharToMultiByte(CP_UTF8, 0, text, (int)n, buf, (int)size - 1, NULL, NULL) : 0;
  if (len <= 0) {
    snprintf(buf, size, "Windows error %lu", (unsigned long)code);
  } else {
    buf[len] = '\0';
  }
  return buf;
}

/* True for a path the front end lets through as absolute ("/x" there): a drive and a separator ("C:\x", "C:/x") or a
   leading separator ("\x", "\\server\share\x"). */
static bool absolute_path(const char *path) {
  if (path[0] == '/' || path[0] == '\\') return true;
  return ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) && path[1] == ':' &&
         (path[2] == '/' || path[2] == '\\');
}

/* A name with no folder in it ("ucrtbase.dll", "sqlite3") is searched like dlopen searches one on Linux: in the
   system's folders (the folder of agentica.exe, System32 and those added with AddDllDirectory), never in the current
   folder, which the plain LoadLibraryW would search. An absolute path has its own folder searched for the libraries it
   needs, as the loader does next to an executable. A relative path ("lib\x.dll", "C:x.dll") is refused like the front
   end refuses "lib/x.so": it would resolve against the working directory. Error dialogs are off for the call, so a
   missing dependency is an error code and not a box that waits for a click. */
static void *library_open(const char *library, char *error, size_t size) {
  bool path = strpbrk(library, "/\\:") != NULL;
  if (path && !absolute_path(library)) {
    snprintf(error, size, "cannot open %s: a library is a name or an absolute path", library);
    return NULL;
  }
  wchar_t *wide = agc_fs_wide(library);
  if (!wide) {
    snprintf(error, size, "cannot open %s: %s", library, errno == ENOMEM ? "out of memory" : "not a valid path");
    return NULL;
  }
  DWORD flags = LOAD_LIBRARY_SEARCH_DEFAULT_DIRS;
  if (path) {
    /* LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR takes only a full path: "/x" gets the current drive, and "/" becomes "\". */
    DWORD need = GetFullPathNameW(wide, 0, NULL, NULL);
    wchar_t *full = need ? malloc((size_t)need * sizeof(wchar_t)) : NULL;
    if (!full || GetFullPathNameW(wide, need, full, NULL) >= need) {
      free(full);
      free(wide);
      snprintf(error, size, "cannot open %s: not a valid path", library);
      return NULL;
    }
    free(wide);
    wide = full;
    flags |= LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR;
  }
  DWORD old_mode = 0;
  bool quiet = SetThreadErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX, &old_mode);
  HMODULE lib = LoadLibraryExW(wide, NULL, flags);
  DWORD code = lib ? 0 : GetLastError();
  if (quiet) SetThreadErrorMode(old_mode, NULL);
  free(wide);
  if (!lib) {
    char why[512];
    snprintf(error, size, "cannot open %s: %s", library, windows_error(code, why, sizeof why));
    return NULL;
  }
  return lib;
}

static void *library_symbol(void *lib, const char *library, const char *symbol, char *error, size_t size) {
  FARPROC found = GetProcAddress((HMODULE)lib, symbol);
  if (!found) {
    char why[512];
    snprintf(error, size, "%s has no function %s: %s", library, symbol, windows_error(GetLastError(), why, sizeof why));
    return NULL;
  }
  void *pointer;
  memcpy(&pointer, &found, sizeof pointer);
  return pointer;
}

/* LoadLibraryExW counts references like dlopen: freeing drops only this one. */
static void library_close(void *lib) { (void)FreeLibrary((HMODULE)lib); }
#else
#ifdef __APPLE__
/* dyld looks a bare name up in DYLD_LIBRARY_PATH, then in /usr/lib (on disk or in the dyld shared cache, where the
   system libraries live), then in the working directory, which Linux never searches. As /usr/lib/NAME it is looked up
   the same way without the working directory: DYLD_LIBRARY_PATH applies to the last component of any path. NULL with
   a message in ERROR when the path does not fit in BUF (PATH_BUF bytes). */
static const char *loader_path(const char *library, char *buf, char *error, size_t size) {
  if (strchr(library, '/')) return library;
  int n = snprintf(buf, PATH_BUF, "/usr/lib/%s", library);
  if (n > 0 && n < PATH_BUF) return buf;
  snprintf(error, size, "cannot open %s: the name is too long", library);
  return NULL;
}
#else
/* dlopen searches a bare name in LD_LIBRARY_PATH, the cache and the system folders, never in the working directory. */
static const char *loader_path(const char *library, char *buf, char *error, size_t size) {
  (void)buf;
  (void)error;
  (void)size;
  return library;
}
#endif

/* RTLD_NOW binds every symbol of the library at once, so a missing dependency is a load error here and not a crash at
   its first use. */
static void *library_open(const char *library, char *error, size_t size) {
  char buf[PATH_BUF];
  const char *path = loader_path(library, buf, error, size);
  if (!path) return NULL;
  void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!lib) {
    const char *why = dlerror();
    snprintf(error, size, "cannot open %s: %s", library, why ? why : "unknown error");
  }
  return lib;
}

static void *library_symbol(void *lib, const char *library, const char *symbol, char *error, size_t size) {
  dlerror();
  void *found = dlsym(lib, symbol);
  if (!found) {
    const char *why = dlerror();
    snprintf(error, size, "%s has no function %s: %s", library, symbol, why ? why : "the symbol is NULL");
  }
  return found;
}

/* dlopen counts references: closing drops only this one, so a failing call repeated in a loop leaks nothing. */
static void library_close(void *lib) { dlclose(lib); }
#endif

bool agc_ffi_supported(void) { return true; }

agc_ffi_call *agc_ffi_prepare(const char *library, const char *symbol, agc_c_type result, const agc_c_type *params,
                              uint32_t count, uint32_t fixed, agc_c_struct *result_struct,
                              agc_c_struct *const *structs, char *error, size_t size) {
  const char *name = symbol ? symbol : "a function pointer";
  if (count > AGC_FFI_MAX_PARAMS) {
    snprintf(error, size, "%s has more than %d parameters", name, AGC_FFI_MAX_PARAMS);
    return NULL;
  }
  bool variadic = fixed != AGC_FFI_NOT_VARIADIC;
  if (variadic && (fixed == 0 || fixed > count)) {
    snprintf(error, size, "%s has a bad fixed parameter count", name);
    return NULL;
  }
  /* A library that holds the function is never closed: a prepared call keeps pointing into it until the process
     ends. A call through a function pointer has no symbol and opens no library. */
  void *lib = NULL, *found = NULL;
  if (symbol) {
    lib = library_open(library, error, size);
    if (!lib) return NULL;
    found = library_symbol(lib, library, symbol, error, size);
    if (!found) {
      library_close(lib);
      return NULL;
    }
  }
  agc_ffi_call *call = malloc(sizeof(agc_ffi_call));
  if (!call) agc_out_of_memory();
  /* ISO C cannot convert an object pointer to a function pointer; POSIX and Windows guarantee that the address of a
     function found by the loader can be. */
  memcpy(&call->fn, &found, sizeof call->fn);
  call->lib = lib;
  call->result = result;
  call->count = count;
  for (uint32_t k = 0; k < count; k++) {
    call->types[k] = ffi_type_of(params[k]);
    call->params[k] = params[k];
  }
  ffi_type *result_type = ffi_type_of(result);
  aggregates_make(call, result, result_struct, structs, params, &result_type);
  /* A variadic call follows its own ABI rules, which ffi_prep_cif_var knows: on Apple arm64 the variadic arguments go
     on the stack, on Windows x64 a variadic double goes in the integer register too. It refuses a variadic argument
     that C would promote (FFI_BAD_ARGTYPE), such as a _Bool. ffi_prep_cif lays out each struct as C does, and also
     decides how it is passed (in registers, on the stack, or by a hidden pointer on Windows x64). */
  ffi_status status = variadic ? ffi_prep_cif_var(&call->cif, FFI_DEFAULT_ABI, fixed, count, result_type, call->types)
                               : ffi_prep_cif(&call->cif, FFI_DEFAULT_ABI, count, result_type, call->types);
  bool laid_out = status == FFI_OK && (result != AGC_C_STRUCT || aggregate_layout(result_struct, result_type));
  for (uint32_t k = 0; k < count && laid_out; k++)
    if (params[k] == AGC_C_STRUCT) laid_out = aggregate_layout(structs[k], call->types[k]);
  if (!laid_out) {
    free(call->aggregates);
    free(call);
    if (lib) library_close(lib);
    snprintf(error, size, "cannot describe the signature of %s", name);
    return NULL;
  }
  return call;
}

void agc_ffi_discard(agc_ffi_call *call) {
  if (call->lib) library_close(call->lib);
  free(call->aggregates);
  free(call);
}

void agc_ffi_invoke(agc_ffi_call *call, void *fn, agc_c_value *args, agc_c_value *result) {
  /* ffi_call reads each argument through a pointer to it: every member of the union starts at its first byte, so a
     pointer to the union is a pointer to the member that ffi_type_of named, and a struct argument already is a pointer
     to its bytes. An integer result is widened to a whole ffi_arg, so it goes through a buffer of that size first; a
     struct result goes to the caller's buffer, which has room for a whole register. */
  void *slots[AGC_FFI_MAX_PARAMS];
  for (uint32_t k = 0; k < call->count; k++) slots[k] = call->params[k] == AGC_C_STRUCT ? args[k].p : &args[k];
  ffi_arg word = 0;
  double real = 0;
  float single = 0;
  void *pointer = NULL;
  void *out = &word;
  bool pointed = call->result == AGC_C_STRING || call->result == AGC_C_POINTER || call->result == AGC_C_RESOURCE;
  if (call->result == AGC_C_DOUBLE) out = &real;
  if (call->result == AGC_C_FLOAT) out = &single;
  if (pointed) out = &pointer;
  if (call->result == AGC_C_STRUCT) out = result->p;
  /* The address of a C function pointer becomes a function pointer the same way as the loader's (memcpy). */
  void (*target)(void) = call->fn;
  if (fn) memcpy(&target, &fn, sizeof target);
  ffi_call(&call->cif, target, out, slots);
  switch (call->result) {
    case AGC_C_INT: result->i = (int32_t)word; break;
    case AGC_C_INT64: result->l = (int64_t)word; break;
    case AGC_C_DOUBLE: result->d = real; break;
    case AGC_C_FLOAT: result->f = single; break;
    case AGC_C_BOOL: result->b = (word & 0xFF) != 0; break;
    case AGC_C_STRING: result->s = pointer; break;
    case AGC_C_POINTER:
    case AGC_C_RESOURCE: result->p = pointer; break;
    case AGC_C_STRUCT:
    case AGC_C_BYTES:
    case AGC_C_VOID: break;
  }
}
#endif

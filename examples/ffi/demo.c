/* A tiny teaching library for examples/ffi (only the C library, no other
   dependencies). It shows the same FFI mechanisms that real numeric or
   inference runtimes use — plain calls, a struct by value, an owned resource
   with a destructor, caller-owned buffers, and a table of function pointers —
   with plain arithmetic instead of a model. The names say "demo" on purpose:
   this is a numeric transform and accumulator, not an inference engine.

   Build the library for your system first (from examples/ffi):

     Linux:   cc -shared -fPIC -O1 -o native/linux/libdemo.so demo.c
     macOS:   cc -dynamiclib -O1 -o native/macos/libdemo.dylib demo.c
     Windows: cc -shared -O1 -o native/windows/demo.dll demo.c

   Then run a demo, e.g. `dist/agentica examples/ffi/calls.agc`. */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#ifdef _WIN32
#define DEMO_API __declspec(dllexport)
#else
#define DEMO_API
#endif

/* Plain calls (calls.agc). */
DEMO_API int32_t demo_add(int32_t a, int32_t b) { return a + b; }

DEMO_API double demo_scale(double x, double k) { return x * k; }

/* A loop whose input bounds the work (calls.agc runs it as a compute def so
   other tasks keep running): the sum of 1..n, or -1 for a negative n. */
DEMO_API int64_t demo_total_upto(int64_t n) {
  int64_t total = 0;
  for (int64_t k = 1; k <= n; k++) total += k;
  return n < 0 ? -1 : total;
}

/* A small struct passed by value (records_and_buffers.agc). */
typedef struct {
  int32_t x, y;
} demo_pair;

DEMO_API demo_pair demo_pair_make(int32_t x, int32_t y) {
  demo_pair p = {x, y};
  return p;
}

DEMO_API demo_pair demo_pair_swap(demo_pair p) {
  demo_pair q = {p.y, p.x};
  return q;
}

DEMO_API int64_t demo_pair_sum(demo_pair p) { return (int64_t)p.x + p.y; }

/* An owned numeric accumulator (records_and_buffers.agc): opened once, read
   and updated through the handle, freed by demo_acc_close. A negative start
   is refused with NULL, which Agentica reports as an error. */
typedef struct {
  int64_t total;
} demo_acc;

DEMO_API void *demo_acc_open(int64_t start) {
  demo_acc *acc;
  if (start < 0) return NULL;
  acc = malloc(sizeof *acc);
  if (!acc) return NULL;
  acc->total = start;
  return acc;
}

DEMO_API void demo_acc_close(void *p) { free(p); }

DEMO_API void demo_acc_add(void *p, int32_t delta) {
  ((demo_acc *)p)->total += delta;
}

DEMO_API int64_t demo_acc_get(const void *p) {
  return ((const demo_acc *)p)->total;
}

/* Buffers the caller owns (records_and_buffers.agc): C fills and reads memory
   that Agentica allocated, as numeric kernels do. */
DEMO_API void demo_fill_floats(float *out, int32_t n) {
  for (int32_t k = 0; k < n; k++) out[k] = (float)k * 0.5f;
}

DEMO_API double demo_sum_floats(const float *xs, int32_t n) {
  double sum = 0;
  for (int32_t k = 0; k < n; k++) sum += xs[k];
  return sum;
}

/* A table of typed function pointers (function_table.agc), the dispatch shape
   of runtimes like onnxruntime's OrtApi: the version picks the table (NULL
   for anything but 1), slot 0 is add, slot 1 is scale. The struct holds real
   function pointers, never integers, and Agentica reads the slots. */
typedef struct {
  int32_t (*add)(int32_t, int32_t);
  double (*scale)(double, double);
} demo_api;

static const demo_api demo_table = {demo_add, demo_scale};

DEMO_API const void *demo_api_table(int32_t version) {
  return version == 1 ? &demo_table : NULL;
}

DEMO_API const char *demo_version(void) { return "demo-api-1"; }

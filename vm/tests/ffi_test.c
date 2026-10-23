/* Native.call against hand-made signatures (every bad shape fails with a code, never a crash), the argument checks,
   the cache, a resource freed once by Native.close, out parameters, compute calls cancelled with one, calls and frees
   through C function pointers, the memory reads, owned buffers with typed reads and writes (bounds, NULL, freed,
   no_files), and agc_ffi_refusal at load. Native calls run only in a build with libffi. */
#include "../core.h"
#include "../services.h"
#include "io_harness.h"

#include <assert.h>
#include <setjmp.h>
#include <stdlib.h>
#include <string.h>

/* The math library and the C library, found by name by the system loader; on Windows the UCRT holds both, and on macOS
   libSystem. USABLE_SIZE is the C library's function that gives the usable size of a malloc block. */
#ifdef _WIN32
#define LIBM "ucrtbase.dll"
#define LIBC "ucrtbase.dll"
#define USABLE_SIZE "_msize"
/* errno_t _dupenv_s(char **buffer, size_t *count, const char *name): a malloc'd copy of the variable, or NULL when
   it is not set. */
#define OUT_MEM "iRLs _dupenv_s free Mem " LIBC
#else
#ifdef __APPLE__
#define LIBM "libSystem.B.dylib"
#define LIBC "libSystem.B.dylib"
#define USABLE_SIZE "malloc_size"
#else
#define LIBM "libm.so.6"
#define LIBC "libc.so.6"
#define USABLE_SIZE "malloc_usable_size"
#endif
/* int posix_memalign(void **block, size_t alignment, size_t size): the block, or the slot left alone (so NULL, as the
   VM zeroes it) for an alignment that is not a power of two. */
#define OUT_MEM "iRll posix_memalign free Mem " LIBC
#endif

#ifdef AGC_FFI
#define AGC_FFI_BUILT true
#else
#define AGC_FFI_BUILT false
#endif

static agc_vm vm;

static agc_value text(const char *s) { return agc_string_value(agc_make_string(s, strlen(s), strlen(s))); }

static agc_value native_call(const char *signature, const agc_value *items, size_t n) {
  agc_value args[2] = {text(signature), agc_list_value(agc_list_from_array(items, n))};
  return agc_ffi_builtins[0].fn(&vm, args, 0);
}

static void fails(const char *signature, const agc_value *items, size_t n, const char *code) {
  if (setjmp(vm.fail) == 0) {
    (void)native_call(signature, items, n);
    assert(!"the call did not fail");
  }
  assert(strcmp(vm.outcome->code, code) == 0);
}

static void test_bad_signatures(void) {
  agc_value one = agc_float(0.0);
  const char *bad[] = {"", "d", "dd", "dd cos", "zd cos " LIBM, "dz cos " LIBM, "dv cos " LIBM,
                       "dd  " LIBM, " cos " LIBM, "yd cos " LIBM, "rd cos " LIBM,
                       "rd cos free " LIBM, "rd cos  Mem " LIBM, "rd cos free M\xc3\xa9m " LIBM,
                       "rd cos free 1Mem " LIBM, "rd cos free M.em " LIBM, ". cos " LIBM, "d.d cos " LIBM,
                       "dd..d cos " LIBM, "dd.d.d cos " LIBM, "dd.b cos " LIBM, "dd.D cos " LIBM, "dd.R cos " LIBM,
                       "dd.f cos " LIBM, "Fd cos " LIBM, "ddc cos " LIBM, "dcc cos " LIBM, "dC cos " LIBM,
                       "dde cos " LIBM, "rl malloc C.Function Mem " LIBM, "rlee malloc C.Function Mem " LIBM,
                       "rle malloc free Mem " LIBM, "dc.d cos " LIBM, "dd.e cos " LIBM, "ce cos " LIBM,
                       "rel malloc C.Function Mem " LIBM, "rcel malloc C.Function Mem " LIBM};
  for (size_t k = 0; k < sizeof bad / sizeof bad[0]; k++) fails(bad[k], &one, 1, "RUNTIME-INTERNAL");
  char wide[100];
  memset(wide, 'i', 66);
  memcpy(wide + 66, " f " LIBM, sizeof " f " LIBM);
  fails(wide, NULL, 0, "RUNTIME-INTERNAL");
  fails("dd cos ", &one, 1, "RUNTIME-NATIVE-LOAD");
}

static void test_calls(void) {
#ifdef AGC_FFI
  agc_value zero = agc_float(0.0);
  assert(agc_as_float(&vm, native_call("dd cos " LIBM, &zero, 1)) == 1.0);
  /* The second call finds the prepared one; a wrong count or type still fails. */
  assert(agc_as_float(&vm, native_call("dd cos " LIBM, &zero, 1)) == 1.0);
  fails("dd cos " LIBM, NULL, 0, "RUNTIME-INTERNAL");
  agc_value word = text("x");
  fails("dd cos " LIBM, &word, 1, "RUNTIME-INTERNAL");
  agc_value big = agc_int(INT64_C(1) << 31);
  fails("ii abs " LIBC, &big, 1, "RUNTIME-INTEGER-OVERFLOW");
  agc_value nul = agc_string_value(agc_make_string("a\0b", 3, 3));
  fails("ls strlen " LIBC, &nul, 1, "RUNTIME-INVALID-CHARACTER");
  agc_value small = agc_int(-(INT64_C(1) << 31));
  assert(agc_as_int(&vm, native_call("ii abs " LIBC, &small, 1)) == INT32_MIN);
#ifndef _WIN32
  /* C.Float: float fabsf(float), the argument narrowed and the result widened. The peer test covers Windows, whose
     UCRT need not export fabsf. */
  agc_value minus = agc_float(-0.1);
  assert(agc_as_float(&vm, native_call("ff fabsf " LIBM, &minus, 1)) == (double)0.1f);
#endif
  agc_value s = text("h\xc3\xa9llo");
  assert(agc_as_int(&vm, native_call("ls strlen " LIBC, &s, 1)) == 6);
  fails("v no_such_function_here " LIBC, NULL, 0, "RUNTIME-NATIVE-LOAD");
#ifndef _WIN32
  /* A variadic call: snprintf(NULL, 0, "%d-%s", 42, "ab") counts 5 characters; the UCRT has no snprintf to export. */
  agc_value printed[5] = {agc_c_pointer_value(NULL), agc_int(0), text("%d-%s"), agc_int(42), text("ab")};
  assert(agc_as_int(&vm, native_call("ipls.is snprintf " LIBC, printed, 5)) == 5);
  agc_value bare[3] = {agc_c_pointer_value(NULL), agc_int(0), text("abc")};
  assert(agc_as_int(&vm, native_call("ipls. snprintf " LIBC, bare, 3)) == 3);
#endif
  fails("v f libnot_there_at_all.so", NULL, 0, "RUNTIME-NATIVE-LOAD");
#else
  fails("dd cos " LIBM, NULL, 0, "RUNTIME-NATIVE-LOAD");
#endif
  vm.rt->no_files = true;
  fails("dd cos " LIBM, NULL, 0, "RUNTIME-NATIVE-DENIED");
  vm.rt->no_files = false;
}

#ifdef AGC_FFI
static agc_value native_close(agc_value resource) { return agc_ffi_builtins[1].fn(&vm, &resource, 0); }
#endif

static void test_resources(void) {
#ifdef AGC_FFI
  agc_value size = agc_int(16);
  agc_value made = native_call("rl malloc free Mem " LIBC, &size, 1);
  agc_c_resource *res = agc_as_c_resource(&vm, agc_as_result(&vm, made)->value);
  assert(res->pointer && strcmp(res->name, "Mem") == 0 && !res->closed);
  agc_value held = agc_as_result(&vm, made)->value;
  assert(agc_as_int(&vm, native_call("lr " USABLE_SIZE " " LIBC, &held, 1)) >= 16);
  native_close(held);
  assert(res->closed && res->freed);
  native_close(held);
  fails("lr " USABLE_SIZE " " LIBC, &held, 1, "RUNTIME-NATIVE-CLOSED");
  fails("rl malloc no_free_function_here Mem " LIBC, &size, 1, "RUNTIME-NATIVE-LOAD");
  /* C.Bytes: a copy of the bytes, here read by strlen up to the 0 item. */
  agc_value items[3] = {agc_int(97), agc_int(255), agc_int(0)};
  agc_value bytes = agc_list_value(agc_list_from_array(items, 3));
  assert(agc_as_int(&vm, native_call("ly strlen " LIBC, &bytes, 1)) == 2);
  items[1] = agc_int(256);
  bytes = agc_list_value(agc_list_from_array(items, 3));
  fails("ly strlen " LIBC, &bytes, 1, "RUNTIME-INVALID-NUMBER");
#endif
}

#ifdef AGC_FFI
/* The arguments of OUT_MEM: a block that C makes, or (FAIL) a NULL one. */
static size_t mem_arguments(agc_value *items, bool fail) {
#ifdef _WIN32
  items[0] = text(fail ? "AGENTICA_FFI_TEST_NOT_SET" : "PATH");
  return 1;
#else
  items[0] = agc_int(fail ? 3 : 16);
  items[1] = agc_int(64);
  return 2;
#endif
}

/* The fields of the List that a call with out parameters gives. */
static agc_value field(agc_value list, size_t k) { return agc_list_get(agc_as_list(&vm, list), k); }
#endif

static void test_outs(void) {
#ifdef AGC_FFI
  /* An out C.Int32 and an out C.Double, after the C result. */
  agc_value eight = agc_float(8.0);
  agc_value split = native_call("ddI frexp " LIBM, &eight, 1);
  assert(agc_list_len(agc_as_list(&vm, split)) == 2);
  assert(agc_as_float(&vm, field(split, 0)) == 0.5 && agc_as_int(&vm, field(split, 1)) == 4);
  agc_value real = agc_float(3.25);
  agc_value parts = native_call("ddD modf " LIBM, &real, 1);
  assert(agc_as_float(&vm, field(parts, 0)) == 0.25 && agc_as_float(&vm, field(parts, 1)) == 3.0);
  /* An out resource is live and owned; Native.close frees it once. */
  agc_value items[3];
  size_t n = mem_arguments(items, false);
  agc_value made = native_call(OUT_MEM, items, n);
  assert(agc_as_int(&vm, field(made, 0)) == 0);
  agc_c_resource *res = agc_as_c_resource(&vm, field(made, 1));
  assert(res->pointer && res->state && !res->closed && strcmp(res->name, "Mem") == 0);
  native_close(field(made, 1));
  assert(res->closed && res->freed);
  /* A NULL out is a closed resource that nothing frees: a close does nothing, and a call with it fails. */
  n = mem_arguments(items, true);
  agc_value missing = native_call(OUT_MEM, items, n);
  res = agc_as_c_resource(&vm, field(missing, 1));
  assert(!res->pointer && !res->state && res->closed && res->freed);
  native_close(field(missing, 1));
  agc_value null_res = field(missing, 1);
  fails("lr " USABLE_SIZE " " LIBC, &null_res, 1, "RUNTIME-NATIVE-CLOSED");
  /* The out parameters are not arguments; an out of a type that cannot be one, and a missing free word, are bad. */
  items[n] = agc_int(0);
  fails(OUT_MEM, items, n + 1, "RUNTIME-INTERNAL");
  fails("iSi strtol " LIBC, &eight, 1, "RUNTIME-INTERNAL");
  fails("Ii abs " LIBC, &eight, 1, "RUNTIME-INTERNAL");
  fails("iRll posix_memalign free " LIBC, items, 2, "RUNTIME-INTERNAL");
#endif
}

#ifdef AGC_FFI
/* The task parks on the compute call of OUT_MEM, as a builtin leaves it. */
static void park_mem(agc_task *task, bool fail) {
  agc_value items[2];
  size_t n = mem_arguments(items, fail);
  atomic_store(&task->state, AGC_TASK_RUNNING);
  (void)native_call("compute " OUT_MEM, items, n);
  assert(task->parked && task->parking);
  task->parking = false;
  assert(agc_task_commit_park(task));
}

/* The task takes the value of its compute call in its turn, as resume does. */
static agc_value take_in_turn(agc_task *task) {
  agc_test_wait_woken(&vm, task);
  atomic_store(&task->state, AGC_TASK_RUNNING);
  vm.in_turn = true;
  agc_value v = agc_io_finish(&vm, task);
  vm.in_turn = false;
  return v;
}
#endif

/* A compute call with an out resource: the task that waits gets it live (or closed for NULL). A cancelled one makes no
   resource: once its end runs, nothing new is registered, and the block C made is freed there, once (ASan and LSan in
   the sanitizer build catch a second free, a free of the zeroed slot's garbage or a leak). */
static void test_compute_outs(void) {
#ifdef AGC_FFI
  agc_task *task = vm.task;
  /* The first call makes the loop; the counts below are of calls made with it. */
  park_mem(task, true);
  agc_c_resource *res = agc_as_c_resource(&vm, field(take_in_turn(task), 1));
  assert(!res->pointer && res->closed);
  uint64_t before = agc_resource_id(&vm);
  park_mem(task, false);
  agc_value made = take_in_turn(task);
  uint64_t taken = agc_resource_id(&vm) - before;
  res = agc_as_c_resource(&vm, field(made, 1));
  assert(res->pointer && !res->closed);
  native_close(field(made, 1));
  assert(res->freed);
  /* Cancelled after C returned (the task is woken, and its cancel detaches the job): the end frees the block. Then
     cancelled before the call starts: the work is skipped, and the zeroed slot is never read. The job takes an id and
     the done call two more (the block's resource, then this read); a cancelled call takes one less. */
  for (int started = 1; started >= 0; started--) {
    before = agc_resource_id(&vm);
    park_mem(task, false);
    if (started) agc_test_wait_woken(&vm, task);
    agc_io_detach(&vm, task);
    agc_test_pump_until_idle(&vm);
    atomic_store(&task->state, AGC_TASK_RUNNING);
    assert(agc_resource_id(&vm) - before == taken - 1);
  }
  agc_test_settle_loop(&vm);
#endif
}

static void test_refusal(void) {
  agc_function functions[2];
  memset(functions, 0, sizeof functions);
  functions[1].span = 7;
  agc_program p;
  memset(&p, 0, sizeof p);
  p.functions = functions;
  p.function_count = 2;
  p.native_import = UINT32_MAX;
  p.native_function = UINT32_MAX;
  const char *message = NULL;
  uint32_t span = 0;
  assert(agc_ffi_refusal(&p, true, &message, &span) == NULL);
  p.native_import = 0;
  p.native_function = 1;
  const char *code = agc_ffi_refusal(&p, true, &message, &span);
  assert(strcmp(code, AGC_FFI_BUILT ? "RUNTIME-NATIVE-DENIED" : "RUNTIME-NATIVE-UNSUPPORTED") == 0 && span == 7);
  code = agc_ffi_refusal(&p, false, &message, &span);
  assert(AGC_FFI_BUILT ? code == NULL : strcmp(code, "RUNTIME-NATIVE-UNSUPPORTED") == 0);
}

/* The row of agc_ffi_builtins with this name and arity. */
static agc_builtin_fn row(const char *name, uint32_t arity) {
  for (size_t k = 0; k < agc_ffi_builtin_count; k++)
    if (strcmp(agc_ffi_builtins[k].name, name) == 0 && agc_ffi_builtins[k].arity == arity)
      return agc_ffi_builtins[k].fn;
  assert(!"no such row");
  return NULL;
}

static void read_fails(const char *name, uint32_t arity, agc_value *args, const char *code) {
  if (setjmp(vm.fail) == 0) {
    (void)row(name, arity)(&vm, args, 0);
    assert(!"the read did not fail");
  }
  assert(strcmp(vm.outcome->code, code) == 0);
}

static void test_reads(void) {
  static const char data[] = "ab\0c";
  /* (pointer, offset, length): at offset 0 the text ends at the NUL, and a length reads past it. */
  agc_value at[3] = {agc_c_pointer_value((void *)data), agc_int(0), agc_int(4)};
  assert(agc_as_string(&vm, row("Native.get_string", 2)(&vm, at, 0))->bytes == 2);
  assert(agc_as_string(&vm, row("Native.get_string", 3)(&vm, at, 0))->bytes == 4);
  assert(agc_list_len(agc_as_list(&vm, row("Native.get_bytes", 3)(&vm, at, 0))) == 4);
  /* From an offset: "c" after the NUL, and the bytes from there. */
  agc_value from[3] = {at[0], agc_int(3), agc_int(1)};
  assert(agc_as_string(&vm, row("Native.get_string", 2)(&vm, from, 0))->bytes == 1);
  assert(agc_as_string(&vm, row("Native.get_string", 3)(&vm, from, 0))->data[0] == 'c');
  assert(agc_as_int(&vm, agc_list_get(agc_as_list(&vm, row("Native.get_bytes", 3)(&vm, from, 0)), 0)) == 'c');
  /* The pointer first: NULL fails before a negative length, and only NULL with length 0 reads as empty. */
  agc_value null_at[3] = {agc_c_pointer_value(NULL), agc_int(0), agc_int(0)};
  assert(agc_as_string(&vm, row("Native.get_string", 3)(&vm, null_at, 0))->bytes == 0);
  assert(agc_list_len(agc_as_list(&vm, row("Native.get_bytes", 3)(&vm, null_at, 0))) == 0);
  read_fails("Native.get_string", 2, null_at, "RUNTIME-NATIVE-NULL");
  null_at[2] = agc_int(-1);
  read_fails("Native.get_bytes", 3, null_at, "RUNTIME-NATIVE-NULL");
  at[2] = agc_int(-1);
  read_fails("Native.get_string", 3, at, "RUNTIME-INVALID-COUNT");
  read_fails("Native.get_bytes", 3, at, "RUNTIME-INVALID-COUNT");
  vm.rt->no_files = true;
  at[2] = agc_int(1);
  read_fails("Native.get_string", 2, at, "RUNTIME-NATIVE-DENIED");
  read_fails("Native.get_string", 3, at, "RUNTIME-NATIVE-DENIED");
  read_fails("Native.get_bytes", 3, at, "RUNTIME-NATIVE-DENIED");
  vm.rt->no_files = false;
}

/* Calls the row NAME/ARITY with ARGS. */
static agc_value call_row(const char *name, uint32_t arity, agc_value *args) { return row(name, arity)(&vm, args, 0); }

/* An owned buffer: typed writes and reads at byte offsets, unaligned too, the bounds of its size, a free that runs
   once and leaves every later use RUNTIME-NATIVE-CLOSED; the same reads at a C pointer, which has no size but refuses
   NULL and a negative offset; and nothing at all under no_files. */
static void test_buffers(void) {
  agc_value size = agc_int(16);
  agc_value buf = call_row("Native.memory_pointer", 1, &size);
  agc_c_resource *res = agc_as_c_resource(&vm, buf);
  assert(res->buffer && res->size == 16 && res->state && !res->closed);
  agc_value put[3] = {buf, agc_int(5), agc_int(-2)};
  (void)call_row("Native.put_int32", 3, put);
  agc_value get[3] = {buf, agc_int(5), agc_int(2)};
  assert(agc_as_int(&vm, call_row("Native.get_int32", 2, get)) == -2);
  assert(agc_as_int(&vm, call_row("Native.get_uint8", 2, get)) == 254);
  put[1] = agc_int(12);
  put[2] = agc_float(1.5);
  (void)call_row("Native.put_float32", 3, put);
  get[1] = agc_int(12);
  assert(agc_as_float(&vm, call_row("Native.get_float32", 2, get)) == 1.5);
  get[1] = agc_int(13);
  read_fails("Native.get_int32", 2, get, "RUNTIME-NATIVE-BOUNDS");
  get[1] = agc_int(17);
  read_fails("Native.get_int8", 2, get, "RUNTIME-NATIVE-BOUNDS");
  get[1] = agc_int(-1);
  read_fails("Native.get_int8", 2, get, "RUNTIME-NATIVE-BOUNDS");
  get[1] = agc_int(0);
  get[2] = agc_int(5);
  read_fails("Native.get_array_of_int32", 3, get, "RUNTIME-NATIVE-BOUNDS");
  get[2] = agc_int(INT64_MAX);
  read_fails("Native.get_array_of_int64", 3, get, "RUNTIME-NATIVE-BOUNDS");
  get[2] = agc_int(-1);
  read_fails("Native.get_array_of_int64", 3, get, "RUNTIME-INVALID-COUNT");
  agc_value ints[2] = {agc_int(1), agc_int(INT64_C(1) << 32)};
  agc_value list[3] = {buf, agc_int(4), agc_list_value(agc_list_from_array(ints, 2))};
  read_fails("Native.put_array_of_int32", 3, list, "RUNTIME-INTEGER-OVERFLOW");
  /* A bad item leaves the memory as it was; a byte of put_bytes is 0 to 255 only. */
  get[1] = agc_int(5);
  assert(agc_as_int(&vm, call_row("Native.get_int32", 2, get)) == -2);
  agc_value bytes[2] = {agc_int(9), agc_int(-1)};
  agc_value put_bytes[3] = {buf, agc_int(5), agc_list_value(agc_list_from_array(bytes, 2))};
  read_fails("Native.put_bytes", 3, put_bytes, "RUNTIME-INTEGER-OVERFLOW");
  assert(agc_as_int(&vm, call_row("Native.get_int32", 2, get)) == -2);
  bytes[1] = agc_int(255);
  put_bytes[2] = agc_list_value(agc_list_from_array(bytes, 2));
  (void)call_row("Native.put_bytes", 3, put_bytes);
  assert(agc_as_int(&vm, call_row("Native.get_uint16", 2, get)) == 9 + 255 * 256);
  read_fails("Native.free", 1, (agc_value[]){agc_c_pointer_value(NULL)}, "RUNTIME-NATIVE-NOT-OWNED");
  (void)call_row("Native.free", 1, &buf);
  assert(res->closed && res->freed);
  (void)call_row("Native.free", 1, &buf);
  read_fails("Native.get_int8", 2, get, "RUNTIME-NATIVE-CLOSED");
  assert(!agc_as_bool(&vm, row("Native.null?", 1)(&vm, &buf, 0)));
  /* A C pointer: read as it is, but never NULL or before itself. */
  static const int32_t words[2] = {7, -9};
  agc_value raw[3] = {agc_c_pointer_value((void *)words), agc_int(4), agc_int(1)};
  assert(agc_as_int(&vm, call_row("Native.get_int32", 2, raw)) == -9);
  raw[1] = agc_int(-4);
  read_fails("Native.get_int32", 2, raw, "RUNTIME-NATIVE-BOUNDS");
  raw[0] = agc_c_pointer_value(NULL);
  raw[1] = agc_int(0);
  read_fails("Native.get_int32", 2, raw, "RUNTIME-NATIVE-NULL");
  raw[2] = agc_int(0);
  assert(agc_list_len(agc_as_list(&vm, call_row("Native.get_array_of_float32", 3, raw))) == 0);
  /* A size the system cannot give is the program's error, not the VM's out of memory. */
  agc_value huge = agc_int(INT64_MAX);
  read_fails("Native.memory_pointer", 1, &huge, "RUNTIME-INVALID-COUNT");
  vm.rt->no_files = true;
  read_fails("Native.memory_pointer", 1, &size, "RUNTIME-NATIVE-DENIED");
  read_fails("Native.get_int32", 2, raw, "RUNTIME-NATIVE-DENIED");
  vm.rt->no_files = false;
}

#ifdef AGC_FFI
/* The functions that the calls through a function pointer reach: the test's own, so their addresses are known. */
static int frees_seen;
static double twice(double x) { return 2 * x; }
/* The block and its free come from the test, not from the C library by name: under ASan the loader's malloc is libc's
   own, which ASan's free would refuse. */
static void *make_block(int64_t n) { return malloc((size_t)n); }
static void count_free(void *p) {
  frees_seen++;
  free(p);
}

/* The address of FN as a C.Pointer, as Native.get_pointer reads one from a table of function pointers. */
static agc_value address_of(void (*fn)(void)) {
  void *p;
  memcpy(&p, &fn, sizeof p);
  return agc_c_pointer_value(p);
}

/* The task parks on the compute call of SIGNATURE, as a builtin leaves it. */
static void park_call(agc_task *task, const char *signature, agc_value *items, size_t n) {
  atomic_store(&task->state, AGC_TASK_RUNNING);
  (void)native_call(signature, items, n);
  assert(task->parked && task->parking);
  task->parking = false;
  assert(agc_task_commit_park(task));
}
#endif

/* A call through a C function pointer (code c) calls the address of its first argument, which is not passed to C; a
   resource of a `free: C.Function` kind is freed through the address its call got (code e), at a close, and when the
   result of a cancelled compute call is dropped. A NULL address or an owned buffer is refused before C runs. */
static void test_pointers(void) {
#ifdef AGC_FFI
  agc_value args[2] = {address_of((void (*)(void))twice), agc_float(1.5)};
  assert(agc_as_float(&vm, native_call("dcd twice " LIBM, args, 2)) == 3.0);
  agc_value compute[2] = {args[0], agc_float(4.0)};
  agc_task *task = vm.task;
  park_call(task, "compute dcd twice " LIBM, compute, 2);
  assert(agc_as_float(&vm, take_in_turn(task)) == 8.0);
  args[0] = agc_c_pointer_value(NULL);
  fails("dcd twice " LIBM, args, 2, "RUNTIME-NATIVE-NULL");
  agc_value size = agc_int(8);
  args[0] = call_row("Native.memory_pointer", 1, &size);
  fails("dcd twice " LIBM, args, 2, "RUNTIME-NATIVE-BOUNDS");
  (void)call_row("Native.free", 1, &args[0]);
  /* A block of make_block, freed through count_free; a NULL free function makes nothing. */
  agc_value made_args[3] = {address_of((void (*)(void))make_block), agc_int(16),
                            address_of((void (*)(void))count_free)};
  agc_value made = native_call("rcle make_block C.Function Mem " LIBC, made_args, 3);
  agc_c_resource *res = agc_as_c_resource(&vm, agc_as_result(&vm, made)->value);
  assert(res->pointer && res->free_at && !res->closed);
  native_close(agc_as_result(&vm, made)->value);
  assert(res->freed && frees_seen == 1);
  made_args[2] = agc_c_pointer_value(NULL);
  fails("rcle make_block C.Function Mem " LIBC, made_args, 3, "RUNTIME-NATIVE-NULL");
  made_args[2] = address_of((void (*)(void))count_free);
  /* A compute call cancelled after C returned: its dropped result is freed through the pointer, once. */
  park_call(task, "compute rcle make_block C.Function Mem " LIBC, made_args, 3);
  agc_test_wait_woken(&vm, task);
  agc_io_detach(&vm, task);
  for (int k = 0; k < 100 && frees_seen < 2; k++) (void)agc_io_poll(&vm, true);
  atomic_store(&task->state, AGC_TASK_RUNNING);
  assert(frees_seen == 2);
  agc_test_settle_loop(&vm);
#endif
}

int main(void) {
  agc_test_io_vm(&vm);
  test_bad_signatures();
  test_calls();
  test_resources();
  test_outs();
  test_compute_outs();
  test_reads();
  test_buffers();
  test_pointers();
  test_refusal();
  return 0;
}

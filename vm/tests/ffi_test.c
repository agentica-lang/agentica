/* Native.call against hand-made signatures (every bad shape fails with a code, never a crash), the argument checks,
   the cache of prepared calls, a resource made by the C library's malloc and freed once by Native.close, out
   parameters (a value of each kind, an out resource, a NULL one, and a compute call cancelled with one), and
   agc_ffi_refusal at load. Calls into the math and C libraries run only in a build with libffi. */
#include "../core.h"
#include "../services.h"
#include "io_harness.h"

#include <assert.h>
#include <setjmp.h>
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
                       "rd cos free 1Mem " LIBM, "rd cos free M.em " LIBM};
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
  agc_value s = text("h\xc3\xa9llo");
  assert(agc_as_int(&vm, native_call("ls strlen " LIBC, &s, 1)) == 6);
  fails("v no_such_function_here " LIBC, NULL, 0, "RUNTIME-NATIVE-LOAD");
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
  /* An out C.Int and an out C.Double, after the C result. */
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

int main(void) {
  agc_test_io_vm(&vm);
  test_bad_signatures();
  test_calls();
  test_resources();
  test_outs();
  test_compute_outs();
  test_refusal();
  return 0;
}

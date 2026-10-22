/* Native.call against hand-made signatures (every bad shape fails with a code, never a crash), the argument checks,
   the cache of prepared calls, a resource made by libc's malloc and freed once by Native.close, and agc_ffi_refusal at
   load. Calls into libm and libc run only in a build with libffi. */
#include "../core.h"
#include "../services.h"

#include <assert.h>
#include <setjmp.h>
#include <string.h>

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
  const char *bad[] = {"", "d", "dd", "dd cos", "zd cos libm.so.6", "dz cos libm.so.6", "dv cos libm.so.6",
                       "dd  libm.so.6", " cos libm.so.6", "yd cos libm.so.6", "rd cos libm.so.6",
                       "rd cos free libm.so.6", "rd cos  Mem libm.so.6", "rd cos free M\xc3\xa9m libm.so.6",
                       "rd cos free 1Mem libm.so.6", "rd cos free M.em libm.so.6"};
  for (size_t k = 0; k < sizeof bad / sizeof bad[0]; k++) fails(bad[k], &one, 1, "RUNTIME-INTERNAL");
  char wide[100];
  memset(wide, 'i', 66);
  memcpy(wide + 66, " f libm.so.6", 13);
  fails(wide, NULL, 0, "RUNTIME-INTERNAL");
  fails("dd cos ", &one, 1, "RUNTIME-NATIVE-LOAD");
}

static void test_calls(void) {
#ifdef AGC_FFI
  agc_value zero = agc_float(0.0);
  assert(agc_as_float(&vm, native_call("dd cos libm.so.6", &zero, 1)) == 1.0);
  /* The second call finds the prepared one; a wrong count or type still fails. */
  assert(agc_as_float(&vm, native_call("dd cos libm.so.6", &zero, 1)) == 1.0);
  fails("dd cos libm.so.6", NULL, 0, "RUNTIME-INTERNAL");
  agc_value word = text("x");
  fails("dd cos libm.so.6", &word, 1, "RUNTIME-INTERNAL");
  agc_value big = agc_int(INT64_C(1) << 31);
  fails("ii abs libc.so.6", &big, 1, "RUNTIME-INTEGER-OVERFLOW");
  agc_value nul = agc_string_value(agc_make_string("a\0b", 3, 3));
  fails("ls strlen libc.so.6", &nul, 1, "RUNTIME-INVALID-CHARACTER");
  agc_value small = agc_int(-(INT64_C(1) << 31));
  assert(agc_as_int(&vm, native_call("ii abs libc.so.6", &small, 1)) == INT32_MIN);
  agc_value s = text("h\xc3\xa9llo");
  assert(agc_as_int(&vm, native_call("ls strlen libc.so.6", &s, 1)) == 6);
  fails("v no_such_function_here libc.so.6", NULL, 0, "RUNTIME-NATIVE-LOAD");
  fails("v f libnot_there_at_all.so", NULL, 0, "RUNTIME-NATIVE-LOAD");
#else
  fails("dd cos libm.so.6", NULL, 0, "RUNTIME-NATIVE-LOAD");
#endif
  vm.rt->no_files = true;
  fails("dd cos libm.so.6", NULL, 0, "RUNTIME-NATIVE-DENIED");
  vm.rt->no_files = false;
}

#ifdef AGC_FFI
static agc_value native_close(agc_value resource) { return agc_ffi_builtins[1].fn(&vm, &resource, 0); }
#endif

static void test_resources(void) {
#ifdef AGC_FFI
  agc_value size = agc_int(16);
  agc_value made = native_call("rl malloc free Mem libc.so.6", &size, 1);
  agc_c_resource *res = agc_as_c_resource(&vm, agc_as_result(&vm, made)->value);
  assert(res->pointer && strcmp(res->name, "Mem") == 0 && !res->closed);
  agc_value held = agc_as_result(&vm, made)->value;
  assert(agc_as_int(&vm, native_call("lr malloc_usable_size libc.so.6", &held, 1)) >= 16);
  native_close(held);
  assert(res->closed && res->freed);
  native_close(held);
  fails("lr malloc_usable_size libc.so.6", &held, 1, "RUNTIME-NATIVE-CLOSED");
  fails("rl malloc no_free_function_here Mem libc.so.6", &size, 1, "RUNTIME-NATIVE-LOAD");
  /* C.Bytes: a copy of the bytes, here read by strlen up to the 0 item. */
  agc_value items[3] = {agc_int(97), agc_int(255), agc_int(0)};
  agc_value bytes = agc_list_value(agc_list_from_array(items, 3));
  assert(agc_as_int(&vm, native_call("ly strlen libc.so.6", &bytes, 1)) == 2);
  items[1] = agc_int(256);
  bytes = agc_list_value(agc_list_from_array(items, 3));
  fails("ly strlen libc.so.6", &bytes, 1, "RUNTIME-INVALID-NUMBER");
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
  agc_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  test_bad_signatures();
  test_calls();
  test_resources();
  test_refusal();
  return 0;
}

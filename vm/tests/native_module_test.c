/* Native modules (vm/native_module.c) through Native.call: each kind of value both ways, the failures the env holds,
   binding (missing function, other signature or mode, bad bytecode), version and load refusals, a carried module under
   no_files, the same module opened as a shared library, and short calls and a first load on several threads. */
#include "../core.h"
#include "../services.h"
#include "io_harness.h"

#include "../../tests/fixtures/native/module_demo.c"

#include <assert.h>
#include <setjmp.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <unistd.h>
#endif

#define THREADS 4
#define ROUNDS 2000
#define PATH_BYTES 4096

#ifdef _WIN32
#define DEMO_FILE "module_demo.dll"
#define LIBM "ucrtbase.dll"
#elif defined(__APPLE__)
#define DEMO_FILE "libmodule_demo.dylib"
#define LIBM "libSystem.B.dylib"
#else
#define DEMO_FILE "libmodule_demo.so"
#define LIBM "libm.so.6"
#endif

typedef struct {
  agc_vm vm;
  int64_t total;
} worker;

static agc_vm vm;
static agc_variant_def variants[2];
static agc_program program;
static int inits, loads;
static atomic_int racy_inits, racy_loads, ready;

static agc_value text(const char *s) { return agc_string_value(agc_make_string(s, strlen(s), strlen(s))); }

static agc_value call_on(agc_vm *on, const char *signature, const agc_value *items, size_t n) {
  agc_value args[2] = {text(signature), agc_list_value(agc_list_from_array(items, n))};
  return agc_ffi_builtins[0].fn(on, args, 0);
}

static agc_value call(const char *signature, const agc_value *items, size_t n) {
  return call_on(&vm, signature, items, n);
}

static void fails(const char *signature, const agc_value *items, size_t n, const char *code) {
  if (setjmp(vm.fail) == 0) {
    (void)call(signature, items, n);
    assert(!"the call did not fail");
  }
  assert(strcmp(vm.outcome->code, code) == 0);
}

static bool same_text(agc_value v, const char *want) {
  const agc_string *s = agc_as_string(&vm, v);
  return s->bytes == strlen(want) && memcmp(s->data, want, s->bytes) == 0;
}

static agc_value ints(const int64_t *items, size_t n) {
  agc_value values[64];
  for (size_t k = 0; k < n; k++) values[k] = agc_int(items[k]);
  return agc_list_value(agc_list_from_array(values, n));
}

static agc_value pair_map(void) {
  agc_map *m = agc_map_put(&vm, agc_new_map(), text("b"), agc_int(2));
  return agc_map_value(agc_map_put(&vm, m, text("a"), agc_int(1)));
}

static void test_values(void) {
  agc_value two[2] = {agc_int(40), agc_int(2)};
  assert(agc_as_int(&vm, call("module (Int, Int) -> Int add demo", two, 2)) == 42);
  agc_value word = text("caf\xc3\xa9 ok");
  assert(same_text(call("module (String) -> String upcase demo", &word, 1), "CAF\xc3\xa9 OK"));
  const uint8_t raw[3] = {1, 2, 3};
  agc_value bytes = agc_bytes_value(agc_make_bytes(raw, 3));
  size_t len;
  const uint8_t *back = agc_bytes_data(&vm, call("module (Bytes) -> Bytes reverse demo", &bytes, 1), &len);
  assert(len == 3 && back[0] == 3 && back[2] == 1);
  const int64_t numbers[4] = {1, 2, 3, -10};
  agc_value list = ints(numbers, 4);
  assert(agc_as_int(&vm, call("module (List[Int]) -> Int sum demo", &list, 1)) == -4);
  /* 40 pushes with no hint: the builder grows past 8, 16 and 32. */
  agc_value forty = agc_int(40);
  const agc_list *range = agc_as_list(&vm, call("module (Int) -> List[Int] range demo", &forty, 1));
  assert(agc_list_len(range) == 40 && agc_as_int(&vm, agc_list_get(range, 39)) == 39);
  agc_value seven = agc_int(7), found;
  const agc_map *row = agc_as_map(&vm, call("module (Int) -> Map[String, Int] row demo", &seven, 1));
  assert(row->size == 3 && agc_map_get(&vm, row, text("square"), &found) && agc_as_int(&vm, found) == 49);
  /* The walk keeps the insertion order: b first. */
  agc_value map = pair_map();
  const agc_list *pairs = agc_as_list(&vm, call("module (Map[String, Int]) -> List[String] pairs demo", &map, 1));
  assert(agc_list_len(pairs) == 2 && same_text(agc_list_get(pairs, 0), "b=2") &&
         same_text(agc_list_get(pairs, 1), "a=1"));
  agc_value ask[3] = {map, text("a"), agc_int(5)};
  const char *lookup_demo = "module (Map[String, Int], String) -> Optional[Int] lookup demo";
  agc_value hit = call(lookup_demo, ask, 2);
  assert(agc_as_enum(&vm, hit)->variant == 1 && agc_as_int(&vm, agc_as_enum(&vm, hit)->payload[0]) == 1);
  ask[1] = text("z");
  assert(agc_as_enum(&vm, call(lookup_demo, ask, 2))->variant == 0);
  const char *put_demo = "module (Map[String, Int], String, Int) -> Map[String, Int] put demo";
  const agc_map *more = agc_as_map(&vm, call(put_demo, ask, 3));
  assert(more->size == 3 && agc_as_map(&vm, map)->size == 2);
  agc_value some = agc_optional_make(&program, true, agc_int(9)), none = agc_optional_make(&program, false, agc_void());
  assert(agc_as_int(&vm, call("module (Optional[Int]) -> Int or_zero demo", &some, 1)) == 9);
  assert(agc_as_int(&vm, call("module (Optional[Int]) -> Int or_zero demo", &none, 1)) == 0);
  agc_value digits = text("123"), letters = text("12x");
  agc_value parsed = call("module (String) -> Result[Int] parse demo", &digits, 1);
  assert(agc_as_result(&vm, parsed)->ok && agc_as_int(&vm, agc_as_result(&vm, parsed)->value) == 123);
  agc_value refused = call("module (String) -> Result[Int] parse demo", &letters, 1);
  assert(!agc_as_result(&vm, refused)->ok && same_text(agc_as_result(&vm, refused)->value, "not a number"));
  assert(agc_as_int(&vm, call("module (Result[Int]) -> Int unwrap demo", &parsed, 1)) == 123);
  fails("module (Result[Int]) -> Int unwrap demo", &refused, 1, "RUNTIME-NATIVE-ERROR");
  agc_value flags[2] = {agc_bool(true), agc_float(1.25)};
  assert(agc_as_float(&vm, call("module (Bool, Float) -> Float truthy? demo", flags, 2)) == 2.5);
  flags[0] = agc_bool(false);
  assert(agc_as_float(&vm, call("module (Bool, Float) -> Float truthy? demo", flags, 2)) == -1.25);
  const agc_list *head = agc_as_list(&vm, call("module (List[Int]) -> List[Int] head demo", &list, 1));
  assert(agc_list_len(head) == 4 && agc_as_int(&vm, agc_list_get(head, 3)) == -10);
  back = agc_bytes_data(&vm, call("module (Bytes) -> Bytes copy demo", &bytes, 1), &len);
  assert(len == 3 && back[0] == 1 && back[2] == 3);
  (void)agc_bytes_data(&vm, call("module () -> Bytes empty demo", NULL, 0), &len);
  assert(len == 0);
  assert(agc_is(call("module () -> Void nothing demo", NULL, 0), AGC_T_VOID));
}

/* What the env holds fails the call after C returns; what the bytecode gets wrong fails before C runs. */
static void test_failures(void) {
  agc_value mixed[2] = {agc_int(1), text("two")};
  agc_value list = agc_list_value(agc_list_from_array(mixed, 2));
  fails("module (List[Int]) -> Int sum demo", &list, 1, "RUNTIME-NATIVE-ERROR");
  fails("module () -> String bad_text demo", NULL, 0, "RUNTIME-NATIVE-ERROR");
  fails("module () -> Map[String, Int] bad_key demo", NULL, 0, "RUNTIME-NATIVE-ERROR");
  fails("module () -> Int lie demo", NULL, 0, "RUNTIME-NATIVE-ERROR");
  agc_value two[2] = {agc_int(1), text("2")};
  fails("module (Int, Int) -> Int add demo", two, 2, "RUNTIME-INTERNAL");
  fails("module (Int, Int) -> Int add demo", two, 1, "RUNTIME-INTERNAL");
  agc_value not_optional = agc_enum_value(agc_new_enum(5, 0));
  fails("module (Optional[Int]) -> Int or_zero demo", &not_optional, 1, "RUNTIME-INTERNAL");
}

static void test_binding(void) {
  agc_value two[2] = {agc_int(1), agc_int(2)};
  fails("module (Int, Int) -> Int nothing demo", two, 2, "RUNTIME-NATIVE-SIGNATURE");
  fails("module (Int, Float) -> Int add demo", two, 2, "RUNTIME-NATIVE-SIGNATURE");
  fails("module (Int, Int) -> Int crunch demo", two, 2, "RUNTIME-NATIVE-SIGNATURE");
  fails("compute module (Int, Int) -> Int add demo", two, 2, "RUNTIME-NATIVE-SIGNATURE");
  fails("compute module (Int, Int) -> Int crunch demo", two, 2, "RUNTIME-NATIVE-SIGNATURE");
  const char *bad[] = {"module ", "module (Int, Int) -> Int add", "module (Int, Int) -> Int  demo",
                       "module (Int,Int) -> Int add demo", "module (Int, Int)->Int add demo",
                       "module (Void) -> Int add demo", "module (List[Int) -> Int add demo",
                       "module (Map[Int]) -> Int add demo", "module (Row) -> Int add demo",
                       "module (Int, Int) -> Int[Int] add demo", "module (Int, ) -> Int add demo",
                       "module (Int) -> Integer add demo"};
  for (size_t k = 0; k < sizeof bad / sizeof bad[0]; k++) fails(bad[k], two, 2, "RUNTIME-INTERNAL");
  /* 32 levels of List nest, 33 do not; 64 parameters fit, 65 do not. */
  char deep[512] = "module (", wide[1024] = "module (";
  for (int k = 0; k < 33; k++) strcat(deep, "List[");
  strcat(deep, "Int");
  for (int k = 0; k < 33; k++) strcat(deep, "]");
  strcat(deep, ") -> Int sum demo");
  fails(deep, two, 1, "RUNTIME-INTERNAL");
  for (int k = 0; k < 65; k++) strcat(wide, k ? ", Int" : "Int");
  strcat(wide, ") -> Int add demo");
  fails(wide, two, 2, "RUNTIME-INTERNAL");
  agc_value nul_args[2] = {agc_string_value(agc_make_string("module (Int, Int) -> Int add de\0mo", 34, 34)),
                           agc_list_value(agc_list_from_array(two, 2))};
  if (setjmp(vm.fail) == 0) {
    (void)agc_ffi_builtins[0].fn(&vm, nul_args, 0);
    assert(!"a NUL library was opened");
  }
  assert(strcmp(vm.outcome->code, "RUNTIME-NATIVE-LOAD") == 0);
}

static const char *refuse_load(void) {
  loads++;
  return "no database";
}

static const char *count_load(void) {
  loads++;
  return NULL;
}

static const an_function bad_rows[] = {{"add", "(Int, Int) -> Int", NULL, AN_SHORT}};
static const an_module v_major = {2, 0, sizeof(an_module), "v", NULL, functions, 1};
static const an_module v_minor = {1, AN_API_MINOR + 1, sizeof(an_module), "v", NULL, functions, 1};
static const an_module v_size = {1, 0, 8, "v", NULL, functions, 1};
static const an_module v_rows = {1, 0, sizeof(an_module), "v", NULL, bad_rows, 1};
static const an_module v_refuses = {1, 0, sizeof(an_module), "v", refuse_load, functions, 1};
static const an_module v_counts = {1, 0, sizeof(an_module), "v", count_load, functions,
                                   sizeof functions / sizeof functions[0]};

static const an_module *init_none(const an_api *api) {
  (void)api;
  inits++;
  return NULL;
}
static const an_module *init_major(const an_api *api) {
  (void)api;
  return &v_major;
}
static const an_module *init_minor(const an_api *api) {
  (void)api;
  return &v_minor;
}
static const an_module *init_size(const an_api *api) {
  (void)api;
  return &v_size;
}
static const an_module *init_rows(const an_api *api) {
  (void)api;
  return &v_rows;
}
static const an_module *init_refuses(const an_api *api) {
  (void)api;
  return &v_refuses;
}
static const an_module *init_counts(const an_api *api) {
  assert(api->major == AN_API_MAJOR && api->minor == AN_API_MINOR && api->size == sizeof(an_api));
  inits++;
  return &v_counts;
}

/* Each refusal is RUNTIME-NATIVE-LOAD, and a module that failed is not asked again; init and load run once per run. */
static void test_versions(void) {
  const struct {
    const char *name;
    agc_native_init init;
  } refused[] = {{"v_none", init_none},   {"v_major", init_major}, {"v_minor", init_minor},
                 {"v_size", init_size},   {"v_rows", init_rows},   {"v_refuses", init_refuses}};
  agc_value two[2] = {agc_int(1), agc_int(2)};
  char signature[96];
  for (size_t k = 0; k < sizeof refused / sizeof refused[0]; k++) {
    agc_native_register(&vm, refused[k].name, refused[k].init);
    snprintf(signature, sizeof signature, "module (Int, Int) -> Int add %s", refused[k].name);
    fails(signature, two, 2, "RUNTIME-NATIVE-LOAD");
  }
  assert(inits == 1 && loads == 1);
  fails("module (Int, Int) -> Int add v_none", two, 2, "RUNTIME-NATIVE-LOAD");
  fails("module (Int, Int) -> Int crunch v_refuses", two, 2, "RUNTIME-NATIVE-LOAD");
  assert(inits == 1 && loads == 1);
  agc_native_register(&vm, "v_counts", init_counts);
  assert(agc_as_int(&vm, call("module (Int, Int) -> Int add v_counts", two, 2)) == 3);
  agc_value seven = agc_int(7);
  (void)call("module (Int) -> List[Int] range v_counts", &seven, 1);
  assert(inits == 2 && loads == 2);
  /* The same init under another name is the same module: it is not loaded again. */
  agc_native_register(&vm, "v_counts_again", init_counts);
  assert(agc_as_int(&vm, call("module (Int, Int) -> Int add v_counts_again", two, 2)) == 3);
  assert(inits == 2 && loads == 2);
}

/* The fuzz driver's no_files: a carried module runs, a library is never opened. */
static void test_no_files(void) {
  agc_value two[2] = {agc_int(1), agc_int(2)};
  vm.rt->no_files = true;
  assert(agc_as_int(&vm, call("module (Int, Int) -> Int add demo", two, 2)) == 3);
  fails("module (Int, Int) -> Int add /no/such/libmodule.so", two, 2, "RUNTIME-NATIVE-DENIED");
  fails("ll labs " LIBM, two, 1, "RUNTIME-NATIVE-DENIED");
  vm.rt->no_files = false;
}

/* The demo built as a shared library next to this test (mk/vm-test.mk): the same calls through dlopen, and a library
   with no entry point. Native modules open libraries through the libffi adapter. */
static void test_shared_library(const char *argv0) {
#ifdef AGC_FFI
  const char *slash = strrchr(argv0, '/'), *back = strrchr(argv0, '\\');
  if (back && (!slash || back > slash)) slash = back;
  char dir[PATH_BYTES] = ".";
  if (slash) {
    assert((size_t)(slash - argv0) < sizeof dir);
    memcpy(dir, argv0, (size_t)(slash - argv0));
    dir[slash - argv0] = '\0';
  }
#ifdef _WIN32
  char *full = _fullpath(NULL, dir, 0);
#else
  char *full = malloc(2 * PATH_BYTES + 2);
  assert(full && (dir[0] == '/' || getcwd(full, PATH_BYTES)));
  if (dir[0] == '/')
    strcpy(full, dir);
  else
    strcat(strcat(full, "/"), dir);
#endif
  assert(full);
  char signature[PATH_BYTES + 64];
  snprintf(signature, sizeof signature, "module (Int, Int) -> Int add %s/%s", full, DEMO_FILE);
  agc_value two[2] = {agc_int(20), agc_int(22)};
  assert(agc_as_int(&vm, call(signature, two, 2)) == 42);
  snprintf(signature, sizeof signature, "module (String) -> String upcase %s/%s", full, DEMO_FILE);
  agc_value word = text("abc");
  assert(same_text(call(signature, &word, 1), "ABC"));
  free(full);
  fails("module (Int, Int) -> Int add " LIBM, two, 2, "RUNTIME-NATIVE-LOAD");
#else
  (void)argv0;
#endif
}

static const char *racy_load(void) {
  atomic_fetch_add(&racy_loads, 1);
  return NULL;
}

static const an_module racy = {1, 0, sizeof(an_module), "racy", racy_load, functions, 1};

static const an_module *init_racy(const an_api *api) {
  (void)api;
  atomic_fetch_add(&racy_inits, 1);
  return &racy;
}

/* Each thread starts with the first call of the racy module, all at once, then calls the demo. */
static void work(void *arg) {
  worker *w = arg;
  assert(agc_gc_thread_enter());
  atomic_fetch_add(&ready, 1);
  while (atomic_load(&ready) < THREADS) {
  }
  agc_value one[2] = {agc_int(1), agc_int(1)};
  assert(agc_as_int(&w->vm, call_on(&w->vm, "module (Int, Int) -> Int add racy", one, 2)) == 2);
  for (int k = 0; k < ROUNDS; k++) {
    agc_value two[2] = {agc_int(k), agc_int(1)};
    w->total += agc_as_int(&w->vm, call_on(&w->vm, "module (Int, Int) -> Int add demo", two, 2));
    agc_value n = agc_int(k % 5);
    (void)call_on(&w->vm, "module (Int) -> Map[String, Int] row demo", &n, 1);
    (void)call_on(&w->vm, "module (Int) -> List[Int] range demo", &n, 1);
  }
  agc_gc_thread_leave();
}

/* Short calls run on several schedulers at once without rt->sync: each thread is a scheduler with its own task and
   memo, and they share the run's cache and modules. A module that they all bind at once loads once. */
static void test_threads(void) {
  worker workers[THREADS];
  uv_thread_t threads[THREADS];
  for (int k = 0; k < THREADS; k++) {
    workers[k].vm = vm;
    workers[k].vm.ffi_memo = NULL;
    workers[k].vm.task = agc_new_task(&vm);
    workers[k].total = 0;
  }
  agc_native_register(&vm, "racy", init_racy);
  agc_share(&vm);
  for (int k = 0; k < THREADS; k++) assert(uv_thread_create(&threads[k], work, &workers[k]) == 0);
  for (int k = 0; k < THREADS; k++) {
    assert(uv_thread_join(&threads[k]) == 0);
    assert(workers[k].total == (int64_t)ROUNDS * (ROUNDS + 1) / 2);
  }
  assert(atomic_load(&racy_inits) == 1 && atomic_load(&racy_loads) == 1);
}

int main(int argc, char **argv) {
  (void)argc;
  agc_test_io_vm(&vm);
  variants[0].shared = agc_new_enum(0, 0);
  program.variants = variants;
  program.variant_count = 2;
  program.optional = 0;
  vm.rt->program = &program;
  agc_native_register(&vm, "demo", agentica_native_init);
  test_values();
  test_failures();
  test_binding();
  test_versions();
  test_no_files();
  test_shared_library(argv[0]);
  test_threads();
  return 0;
}

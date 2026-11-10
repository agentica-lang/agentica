/* Native modules (vm/native_module.c) through Native.call: each kind of value both ways, structs and enums, the
   failures the env holds, binding and bad bytecode, version and load refusals, dirty calls, resources (a close and a
   cancel during a dirty call, the end of the run), the type table at its cap, no_files, the module as a shared
   library, short calls and a first load on several threads, and an_blocking while another thread collects. */
#include "../core.h"
#include "../services.h"
#include "io_harness.h"

#include "../../tests/fixtures/native/module_demo.c"

#include <assert.h>
#include <limits.h>
#include <setjmp.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#ifndef _WIN32
#include <unistd.h>
#endif
#ifdef __linux__
#include <sys/resource.h>
#endif
/* The collector is what an_blocking keeps away, so the case switches stacks only in a build that has it; TSan and
   ASan (built without libgc) do not follow a stack switch either. */
#if defined(__linux__) && !defined(AGC_NO_GC)
#define SWITCH_STACK 1
#include <ucontext.h>
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

/* What the function of an_blocking reads and gives back: the borrowed bytes of the argument and their sum. */
typedef struct {
  const char *data;
  size_t len;
  uint64_t sum;
} blocking_work;

static agc_vm vm;
/* Optional's None and Some, then the variants of enum Shape (Dot, Circle(Int), Rect(Point, Point)). */
static agc_variant_def variants[9];
static agc_struct_def structs[2];
static agc_enum_def enums[3];
static agc_string *point_fields[3];
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
static const an_module v_major = {2, 0, sizeof(an_module), "v", NULL, functions, 1, NULL, 0, NULL, 0};
static const an_module v_minor = {1, AN_API_MINOR + 1, sizeof(an_module), "v", NULL, functions, 1, NULL, 0, NULL, 0};
/* The size of an an_module of API 1.0, as vm/native_module.c checks it: one byte less is refused. */
#define SIZE_1_0 (offsetof(an_module, function_count) + sizeof(uint32_t))
#if UINTPTR_MAX == UINT64_MAX && ULONG_MAX == UINT64_MAX
_Static_assert(SIZE_1_0 == 44, "the 1.0 an_module layout on LP64");
#endif
static const an_module v_size = {1, 0, SIZE_1_0 - 1, "v", NULL, functions, 1, NULL, 0, NULL, 0};
static const an_module v_size_1_0 = {1, 0, SIZE_1_0, "v", NULL, functions, 1, NULL, 0, NULL, 0};
static const an_module v_rows = {1, 0, sizeof(an_module), "v", NULL, bad_rows, 1, NULL, 0, NULL, 0};
static const an_module v_refuses = {1, 0, sizeof(an_module), "v", refuse_load, functions, 1, NULL, 0, NULL, 0};
static const an_type twin_types[] = {{"Point", AN_STRUCT, "x: Int, y: Int"}, {"Point", AN_STRUCT, "x: Int"}};
static const an_module v_twins = {1, 1, sizeof(an_module), "v", NULL, functions, 1, twin_types, AN_COUNT(twin_types),
                                  NULL, 0};
static const an_resource_type twin_resources[] = {{"Db", 8, NULL}, {"Db", 16, NULL}};
static const an_module v_twin_resources = {1, 2, sizeof(an_module), "v", NULL, functions, 1, NULL, 0, twin_resources,
                                           AN_COUNT(twin_resources)};
static const an_resource_type point_resources[] = {{"Point", 8, NULL}};
static const an_module v_type_and_resource = {1, 2, sizeof(an_module), "v", NULL, functions, 1, types, AN_COUNT(types),
                                              point_resources, AN_COUNT(point_resources)};
static const an_module v_counts = {1, 0, sizeof(an_module), "v", count_load, functions, AN_COUNT(functions), NULL,
                                   0, NULL, 0};

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
static const an_module *init_size_1_0(const an_api *api) {
  (void)api;
  return &v_size_1_0;
}
static const an_module *init_rows(const an_api *api) {
  (void)api;
  return &v_rows;
}
static const an_module *init_twins(const an_api *api) {
  (void)api;
  return &v_twins;
}
static const an_module *init_twin_resources(const an_api *api) {
  (void)api;
  return &v_twin_resources;
}
static const an_module *init_type_and_resource(const an_api *api) {
  (void)api;
  return &v_type_and_resource;
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
                 {"v_size", init_size},   {"v_rows", init_rows},   {"v_twins", init_twins},
                 {"v_twin_resources", init_twin_resources}, {"v_type_and_resource", init_type_and_resource},
                 {"v_refuses", init_refuses}};
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
  agc_native_register(&vm, "v_size_1_0", init_size_1_0);
  assert(agc_as_int(&vm, call("module (Int, Int) -> Int add v_size_1_0", two, 2)) == 3);
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

static const an_module v_types_1_0 = {1, 0, SIZE_1_0, "v", NULL, functions, AN_COUNT(functions), types,
                                     AN_COUNT(types), NULL, 0};

static const an_module *init_types_1_0(const an_api *api) {
  (void)api;
  return &v_types_1_0;
}

#define POINT_BLOCK "{S0=x: Int, y: Int}"
#define SHAPE_BLOCK "{E0=Dot | Circle(Int) | Rect(Point, Point)}"
#define GROW "module " SHAPE_BLOCK POINT_BLOCK "(Shape, Int) -> Shape grow demo"

static agc_value point(int64_t x, int64_t y) {
  agc_struct *s = agc_new_struct(0, 2);
  s->fields[0] = agc_int(x);
  s->fields[1] = agc_int(y);
  return agc_struct_value(s);
}

static int64_t field(agc_value v, uint32_t k) { return agc_as_int(&vm, agc_as_struct(&vm, v)->fields[k]); }

/* Structs and enums through the type blocks of a signature: both ways, nested in a List and an enum; a block or a type
   that the bytecode gets wrong is bad bytecode, one that the module declares otherwise is RUNTIME-NATIVE-SIGNATURE. */
static void test_types(void) {
  agc_value p = point(1, 2);
  agc_value flipped = call("module " POINT_BLOCK "(Point) -> Point flip demo", &p, 1);
  assert(field(flipped, 0) == 2 && field(flipped, 1) == 1);
  agc_enum *rect = agc_new_enum(4, 2);
  rect->payload[0] = point(1, 1);
  rect->payload[1] = point(3, 4);
  agc_value shape = agc_enum_value(rect);
  assert(agc_as_int(&vm, call("module " SHAPE_BLOCK POINT_BLOCK "(Shape) -> Int area demo", &shape, 1)) == 6);
  agc_value grown[2] = {shape, agc_int(3)};
  const agc_enum *circle = agc_as_enum(&vm, call(GROW, grown, 2));
  assert(circle->variant == 3 && agc_as_int(&vm, circle->payload[0]) == 3);
  grown[0] = agc_enum_value((agc_enum *)circle);
  const agc_enum *square = agc_as_enum(&vm, call(GROW, grown, 2));
  assert(square->variant == 4 && field(square->payload[1], 0) == 3);
  grown[1] = agc_int(0);
  assert(agc_as_enum(&vm, call(GROW, grown, 2)) ==
         variants[2].shared);
  agc_value three = agc_int(3);
  const agc_list *list = agc_as_list(&vm, call("module " POINT_BLOCK "(Int) -> List[Point] points demo", &three, 1));
  assert(agc_list_len(list) == 3 && field(agc_list_get(list, 2), 1) == 4);
  fails("module " POINT_BLOCK "(Int) -> Point bad_type demo", &three, 1, "RUNTIME-NATIVE-ERROR");
  /* A 1.0 module has no type table, even with one past its size. */
  agc_native_register(&vm, "v_types_1_0", init_types_1_0);
  const char *refused[] = {
      "module {S0=x: Int, y: Float}(Point) -> Point flip demo",
      "module {E0=Dot | Circle(Float) | Rect(Point, Point)}" POINT_BLOCK "(Shape) -> Int area demo",
      "module " POINT_BLOCK "(Point) -> Point flip v_types_1_0",
  };
  for (size_t k = 0; k < sizeof refused / sizeof refused[0]; k++) fails(refused[k], &p, 1, "RUNTIME-NATIVE-SIGNATURE");
  /* Without the block of Point the getters of the module refuse a Point inside the Rect. */
  fails("module " SHAPE_BLOCK "(Shape) -> Int area demo", &shape, 1, "RUNTIME-NATIVE-ERROR");
  const char *bad[] = {"module (Point) -> Point flip demo", "module {S2=x: Int, y: Int}(Point) -> Point flip demo",
                       "module {S0=y: Int, x: Int}(Point) -> Point flip demo",
                       "module {S0=x: Int}(Point) -> Point flip demo",
                       "module {S0=x: Int, y: Int, z: Int}(Point) -> Point flip demo",
                       "module {S0=x: Int], y: Int}(Point) -> Point flip demo",
                       "module {S0=x: , y: Int}(Point) -> Point flip demo",
                       "module {S0=x: Int, y: Int(Point) -> Point flip demo",
                       "module {E0=x: Int, y: Int}(Point) -> Point flip demo",
                       "module {X0=x: Int, y: Int}(Point) -> Point flip demo",
                       "module {S=x: Int, y: Int}(Point) -> Point flip demo",
                       "module {S99999999999=x: Int, y: Int}(Point) -> Point flip demo",
                       "module " POINT_BLOCK POINT_BLOCK "(Point) -> Point flip demo",
                       "module " POINT_BLOCK "(Point[Int]) -> Point flip demo",
                       "module {E0=Dot | Circle | Rect(Point, Point)}(Shape) -> Int area demo",
                       "module {E0=Dot | Circle(Int) | Rect(Point)}(Shape) -> Int area demo",
                       "module {E0=Dot | Circle(Int)}(Shape) -> Int area demo"};
  for (size_t k = 0; k < sizeof bad / sizeof bad[0]; k++) fails(bad[k], &p, 1, "RUNTIME-INTERNAL");
  /* A name of the program with a separator in it would read the module's shape as other fields or variants: the Point
     of S1 has the one field "x: Int, y", and the Shapes of E1 and E2 have Dot and a variant "Circle(Int) | Rect..." of
     no or two payloads, which area and grow would index by the module's counts. With arguments of those types, only
     the bind refuses them. */
  agc_struct *split = agc_new_struct(1, 1);
  split->fields[0] = agc_int(1);
  agc_value split_point = agc_struct_value(split);
  agc_value split_dots[2] = {agc_enum_value(variants[5].shared), agc_enum_value(variants[7].shared)};
  agc_value split_grow[2] = {split_dots[1], agc_int(3)};
  fails("module {S1=x: Int, y: Int}(Point) -> Point flip demo", &split_point, 1, "RUNTIME-INTERNAL");
  fails("module {E1=Dot | Circle(Int) | Rect(Point, Point)}" POINT_BLOCK "(Shape) -> Int area demo", &split_dots[0], 1,
        "RUNTIME-INTERNAL");
  fails("module {E2=Dot | Circle(Int) | Rect(Point, Point)}" POINT_BLOCK "(Shape, Int) -> Shape grow demo", split_grow,
        2, "RUNTIME-INTERNAL");
  /* A struct of another type, and an enum of another enum's variant, are bad arguments. */
  agc_struct *other = agc_new_struct(1, 0);
  agc_value wrong[2] = {agc_struct_value(other), agc_enum_value(agc_new_enum(1, 1))};
  fails("module " POINT_BLOCK "(Point) -> Point flip demo", &wrong[0], 1, "RUNTIME-INTERNAL");
  fails("module " SHAPE_BLOCK POINT_BLOCK "(Shape) -> Int area demo", &wrong[1], 1, "RUNTIME-INTERNAL");
}

/* The task parks on a dirty call, as a builtin leaves it. */
static void park(const char *signature, const agc_value *items, size_t n) {
  agc_task *task = vm.task;
  atomic_store(&task->state, AGC_TASK_RUNNING);
  (void)call(signature, items, n);
  assert(task->parked && task->parking);
  task->parking = false;
  assert(agc_task_commit_park(task));
}

/* The task, woken, takes the value of its dirty call in its turn, as resume does. */
static agc_value finish(void) {
  atomic_store(&vm.task->state, AGC_TASK_RUNNING);
  vm.in_turn = true;
  agc_value v = agc_io_finish(&vm, vm.task);
  vm.in_turn = false;
  return v;
}

static agc_value take(void) {
  agc_test_wait_woken(&vm, vm.task);
  return finish();
}

static agc_value dirty(const char *signature, const agc_value *items, size_t n) {
  park(signature, items, n);
  return take();
}

static void dirty_fails(const char *signature, const agc_value *items, size_t n, const char *code) {
  park(signature, items, n);
  agc_test_wait_woken(&vm, vm.task);
  /* In the task's turn a failure jumps to vm.turn. */
  if (setjmp(vm.turn) == 0) {
    (void)finish();
    assert(!"the dirty call did not fail");
  }
  vm.in_turn = false;
  assert(strcmp(vm.outcome->code, code) == 0);
}

#define COUNTER "{R=Counter}"

static agc_c_resource *counter_of(agc_value v) { return agc_as_c_resource(&vm, v); }

static agc_value make_counter_value(int64_t id) {
  agc_value n = agc_int(id);
  return call("module " COUNTER "(Int) -> Counter counter demo", &n, 1);
}

static agc_value native_close(agc_value v) { return agc_ffi_builtins[1].fn(&vm, &v, 0); }

/* Each kind of value made apart on the pool and built in the task's turn, a failure raised there, and resources made
   by a dirty call. */
static void test_dirty(void) {
  agc_value two[2] = {agc_int(40), agc_int(2)};
  assert(agc_as_int(&vm, dirty("compute module (Int, Int) -> Int crunch demo", two, 2)) == 42);
  agc_value word = text("caf\xc3\xa9 ok");
  assert(same_text(dirty("compute module (String) -> String dirty_upcase demo", &word, 1), "CAF\xc3\xa9 OK"));
  agc_value seven = agc_int(7), found;
  const agc_map *row = agc_as_map(&vm, dirty("compute module (Int) -> Map[String, Int] dirty_row demo", &seven, 1));
  assert(row->size == 3 && agc_map_get(&vm, row, text("square"), &found) && agc_as_int(&vm, found) == 49);
  agc_value map = pair_map();
  const agc_list *pairs =
      agc_as_list(&vm, dirty("compute module (Map[String, Int]) -> List[String] dirty_pairs demo", &map, 1));
  assert(agc_list_len(pairs) == 2 && same_text(agc_list_get(pairs, 0), "b=2"));
  agc_value ask[2] = {map, text("a")};
  agc_value hit = dirty("compute module (Map[String, Int], String) -> Optional[Int] dirty_lookup demo", ask, 2);
  assert(agc_as_enum(&vm, hit)->variant == 1 && agc_as_int(&vm, agc_as_enum(&vm, hit)->payload[0]) == 1);
  agc_value letters = text("12x");
  agc_value refused = dirty("compute module (String) -> Result[Int] dirty_parse demo", &letters, 1);
  assert(!agc_as_result(&vm, refused)->ok && same_text(agc_as_result(&vm, refused)->value, "not a number"));
  dirty_fails("compute module (Result[Int]) -> Int dirty_unwrap demo", &refused, 1, "RUNTIME-NATIVE-ERROR");

  dirty_fails("compute module () -> String dirty_bad_text demo", NULL, 0, "RUNTIME-NATIVE-ERROR");
  agc_enum *circle = agc_new_enum(3, 1);
  circle->payload[0] = agc_int(2);
  agc_value grown[2] = {agc_enum_value(circle), agc_int(3)};
  const agc_enum *square = agc_as_enum(
      &vm, dirty("compute module {E0=Dot | Circle(Int) | Rect(Point, Point)}{S0=x: Int, y: Int}(Shape, Int) -> Shape "
                 "dirty_grow demo",
                 grown, 2));
  assert(square->variant == 4 && field(square->payload[1], 0) == 3);
  agc_value three = agc_int(3);
  const agc_list *list =
      agc_as_list(&vm, dirty("compute module {S0=x: Int, y: Int}(Int) -> List[Point] dirty_points demo", &three, 1));
  assert(agc_list_len(list) == 3 && field(agc_list_get(list, 2), 1) == 4);
  int before = atomic_load(&free_count);
  const char *counters_demo = "compute module " COUNTER "(Int) -> List[Counter] counters demo";
  const agc_list *made = agc_as_list(&vm, dirty(counters_demo, &three, 1));
  assert(agc_list_len(made) == 3);
  for (uint32_t k = 0; k < 3; k++) {
    agc_c_resource *res = counter_of(agc_list_get(made, k));
    assert(!res->closed && res->pointer && ((demo_counter *)res->pointer)->id == k + 1);
    native_close(agc_list_get(made, k));
  }
  assert(atomic_load(&free_count) == before + 3);
  /* The task is cancelled after the job ran: what it made is dropped, its counters freed. */
  park(counters_demo, &three, 1);
  agc_test_wait_woken(&vm, vm.task);
  agc_io_detach(&vm, vm.task);
  while (atomic_load(&free_count) < before + 6) assert(agc_io_poll(&vm, true));
  atomic_store(&vm.task->state, AGC_TASK_RUNNING);
  assert(atomic_load(&free_count) == before + 6);
}

/* A resource through short calls: made, held for a call, closed once; and the blocks of a resource that the bytecode
   or the module gets wrong. */
static void test_resources(void) {
  agc_value c = make_counter_value(5);
  agc_c_resource *res = counter_of(c);
  assert(!res->closed && strcmp(res->name, "Counter") == 0);
  const char *bump_demo = "module " COUNTER "(Counter) -> Int bump demo";
  assert(agc_as_int(&vm, call(bump_demo, &c, 1)) == 1 && agc_as_int(&vm, call(bump_demo, &c, 1)) == 2);
  int before = atomic_load(&free_count);
  native_close(c);
  native_close(c);
  assert(res->freed && atomic_load(&free_count) == before + 1);
  fails(bump_demo, &c, 1, "RUNTIME-NATIVE-CLOSED");
  agc_value p = point(1, 2);
  fails(bump_demo, &p, 1, "RUNTIME-INTERNAL");
  agc_value fresh = make_counter_value(6);
  fails("module {R=Nope}(Nope) -> Int bump demo", &fresh, 1, "RUNTIME-NATIVE-SIGNATURE");
  fails("module {R=Point}(Point) -> Point flip demo", &fresh, 1, "RUNTIME-NATIVE-SIGNATURE");
  fails("module " COUNTER POINT_BLOCK "(Point) -> Int bump demo", &fresh, 1, "RUNTIME-NATIVE-SIGNATURE");
  const char *bad[] = {"module (Counter) -> Int bump demo", "module {R=}(Counter) -> Int bump demo",
                       "module {R=Counter(Counter) -> Int bump demo", "module {R=Count er}(Counter) -> Int bump demo",
                       "module " COUNTER COUNTER "(Counter) -> Int bump demo",
                       "module " COUNTER "(Counter[Int]) -> Int bump demo"};
  for (size_t k = 0; k < sizeof bad / sizeof bad[0]; k++) fails(bad[k], &fresh, 1, "RUNTIME-INTERNAL");
  native_close(fresh);
}

/* Busy-waits until the pool thread sets FLAG (within milliseconds); after 10 seconds the test fails instead of
   hanging. */
static void wait_for_flag(atomic_bool *flag) {
  time_t start = time(NULL);
  while (!atomic_load(flag)) {
    if (time(NULL) - start >= 10) {
      fputs("the pool thread never set the flag\n", stderr);
      abort();
    }
  }
}

/* A dirty call holds its counter: ANOTHER task's close (or the end of the cancelled task that owns it, when CANCEL)
   meanwhile leaves it to the end of the call, which frees it once. A cancelled call's result is dropped. */
static void close_while_waiting(bool cancel) {
  agc_value off = agc_bool(false);
  (void)call("module (Bool) -> Void gate demo", &off, 1);
  /* Made in the task's turn, so the task owns it. */
  vm.in_turn = true;
  agc_value c = make_counter_value(cancel ? 8 : 9);
  vm.in_turn = false;
  agc_c_resource *res = counter_of(c);
  int before = atomic_load(&free_count);
  park("compute module " COUNTER "(Counter) -> Int wait_gate demo", &c, 1);
  wait_for_flag(&gate_was_entered);
  agc_task *task = vm.task;
  if (cancel) {
    agc_io_detach(&vm, task);
    agc_close_owned(&vm, task);
  } else {
    vm.task = agc_new_task(&vm);
    native_close(c);
    vm.task = task;
  }
  assert(res->closed && !res->freed && atomic_load(&free_count) == before);
  agc_value on = agc_bool(true);
  (void)call("module (Bool) -> Void gate demo", &on, 1);
  if (cancel) {
    while (!res->freed) assert(agc_io_poll(&vm, true));
    atomic_store(&task->state, AGC_TASK_RUNNING);
  } else {
    /* The id was read after the close: the state was still there. */
    assert(agc_as_int(&vm, take()) == 9);
  }
  assert(res->freed && atomic_load(&free_count) == before + 1);
  native_close(c);
  assert(atomic_load(&free_count) == before + 1);
}

static void test_close_during_a_dirty_call(void) {
  close_while_waiting(false);
  close_while_waiting(true);
}

#ifdef __linux__
static void no_work(void *arg) { (void)arg; }
#endif

/* A dirty call whose work cannot start (the pool has no thread yet and none starts: RLIMIT_NPROC at 0) fails its task
   with RUNTIME-INTERNAL once its done half gave back the hold on its counter, which a close then frees at once. Runs
   before any other dirty call; only on Linux, and only where the limit stops threads (not for root). */
static void test_a_dirty_call_that_cannot_start(void) {
#ifdef __linux__
  struct rlimit saved, none;
  if (getrlimit(RLIMIT_NPROC, &saved) != 0) return;
  none = saved;
  none.rlim_cur = 0;
  if (setrlimit(RLIMIT_NPROC, &none) != 0) return;
  uv_thread_t probe;
  if (uv_thread_create(&probe, no_work, NULL) == 0) {
    (void)uv_thread_join(&probe);
    assert(setrlimit(RLIMIT_NPROC, &saved) == 0);
    return;
  }
  agc_value c = make_counter_value(4);
  agc_c_resource *res = counter_of(c);
  park("compute module " COUNTER "(Counter) -> Int wait_gate demo", &c, 1);
  agc_test_wait_woken(&vm, vm.task);
  assert(setrlimit(RLIMIT_NPROC, &saved) == 0);
  if (setjmp(vm.turn) == 0) {
    (void)finish();
    assert(!"the call that could not start did not fail");
  }
  vm.in_turn = false;
  assert(strcmp(vm.outcome->code, "RUNTIME-INTERNAL") == 0 && res->jobs == 0);
  int before = atomic_load(&free_count);
  native_close(c);
  assert(res->freed && atomic_load(&free_count) == before + 1);
#endif
}

/* MODULE_MAX_TYPES rows, Point among them, found by the binary search; one row more refuses the module. */
#define TYPE_CAP 65536
static an_type *big_types;
static an_module big_module, too_big_module;

static const an_module *init_big(const an_api *api) {
  (void)api;
  return &big_module;
}

static const an_module *init_too_big(const an_api *api) {
  (void)api;
  return &too_big_module;
}

static void test_type_cap(void) {
  big_types = calloc(TYPE_CAP + 1, sizeof *big_types);
  char *names = malloc((size_t)(TYPE_CAP + 1) * 8);
  assert(big_types && names);
  for (uint32_t k = 0; k <= TYPE_CAP; k++) {
    char *name = names + (size_t)k * 8;
    snprintf(name, 8, "T%05u", (unsigned)k);
    big_types[k] = (an_type){name, AN_STRUCT, "x: Int"};
  }
  /* Point and Shape at the indexes that the demo's functions use. */
  big_types[POINT_TYPE] = types[POINT_TYPE];
  big_types[SHAPE_TYPE] = types[SHAPE_TYPE];
  big_module = (an_module){1, 1, sizeof(an_module), "big", NULL, functions, AN_COUNT(functions), big_types, TYPE_CAP,
                             NULL, 0};
  too_big_module = big_module;
  too_big_module.type_count = TYPE_CAP + 1;
  agc_native_register(&vm, "big", init_big);
  agc_native_register(&vm, "too_big", init_too_big);
  agc_value p = point(1, 2);
  agc_value flipped = call("module " POINT_BLOCK "(Point) -> Point flip big", &p, 1);
  assert(field(flipped, 0) == 2 && field(flipped, 1) == 1);
  fails("module " POINT_BLOCK "(Point) -> Point flip too_big", &p, 1, "RUNTIME-NATIVE-LOAD");
}

static int never_stopped(void) { return 0; }

/* The end of the run frees the live resources once, newest first, and before them the counters that a dirty call
   made for a task that is still parked when the run ends (its value is never taken). The loop's close later drops
   that job: ASan would see a second free. */
static void test_end_of_run(void) {
  int before = atomic_load(&free_count);
  for (int64_t id = 11; id <= 13; id++) (void)make_counter_value(id);
  agc_value two = agc_int(2);
  park("compute module " COUNTER "(Int) -> List[Counter] counters demo", &two, 1);
  agc_test_wait_woken(&vm, vm.task);
  agc_io_flush_files(&vm);
  assert(agc_ffi_end(&vm, never_stopped));
  assert(atomic_load(&free_count) == before + 5);
  const int64_t order[5] = {2, 1, 13, 12, 11};
  for (int k = 0; k < 5; k++) assert(atomic_load(&freed_ids[before + k]) == order[k]);
}

/* A dirty call walks and looks up String keys (of more bytes than AGC_COST_BYTES, so a lookup would charge) on the
   pool thread with no charge: the task that vm.task names meanwhile, a sentinel, pays nothing. The bytes it read are
   charged to the task that takes the value. */
static void test_dirty_calls_charge_on_the_scheduler(void) {
  agc_value off = agc_bool(false);
  (void)call("module (Bool) -> Void gate demo", &off, 1);
  char key[300];
  memset(key, 'k', sizeof key - 1);
  key[sizeof key - 1] = '\0';
  agc_map *m = agc_map_put(&vm, agc_new_map(), text(key), agc_int(20));
  key[0] = 'j';
  agc_value map = agc_map_value(agc_map_put(&vm, m, text(key), agc_int(1)));
  agc_task *task = vm.task, *sentinel = agc_new_task(&vm);
  park("compute module (Map[String, Int]) -> Int gated_sum demo", &map, 1);
  wait_for_flag(&gate_was_entered);
  vm.task = sentinel;
  int64_t cost = sentinel->turn_cost;
  /* Opened here, not by a short call, which would charge the sentinel. */
  atomic_store(&gate_is_open, true);
  wait_for_flag(&gate_was_left);
  assert(sentinel->turn_cost == cost);
  vm.task = task;
  int64_t paid = task->turn_cost;
  assert(agc_as_int(&vm, take()) == 42);
  assert(task->turn_cost > paid);
}

/* The fuzz driver's no_files: a carried module runs, a library is never opened. */
static void test_no_files(void) {
  agc_value two[2] = {agc_int(1), agc_int(2)};
  vm.rt->no_files = true;
  assert(agc_as_int(&vm, call("module (Int, Int) -> Int add demo", two, 2)) == 3);
  fails("module (Int, Int) -> Int add /no/such/libmodule.so", two, 2, "RUNTIME-NATIVE-DENIED");
  fails("ll labs " LIBM, two, 1, "RUNTIME-NATIVE-DENIED");
  fails("compute module (Int, Int) -> Int crunch demo", two, 2, "RUNTIME-NATIVE-DENIED");
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

static const an_module racy = {1, 0, sizeof(an_module), "racy", racy_load, functions, 1, NULL, 0, NULL, 0};

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

#define SWITCH_ROUNDS 64
#define COROUTINE_STACK 65536
#define FILLER_STRINGS 4096

/* The collecting thread runs collections only when the function of an_blocking asks for them, so it never starves
   the scheduler of the test around the calls. */
static uv_mutex_t gc_lock;
static uv_cond_t gc_wake;
static uint64_t gc_asked, gc_done;
static bool gc_stop;

/* Asks the other thread for N collections and waits for them. */
static void wait_collections(uint64_t n) {
  uv_mutex_lock(&gc_lock);
  gc_asked += n;
  uv_cond_broadcast(&gc_wake);
  while (gc_done < gc_asked) uv_cond_wait(&gc_wake, &gc_lock);
  uv_mutex_unlock(&gc_lock);
}

#ifdef SWITCH_STACK
static ucontext_t caller_context, coroutine_context;
static blocking_work *coroutine_work;

/* Runs on a stack of its own, as a coroutine of a C library does, and goes back to the caller each round. */
static void coroutine(void) {
  for (int round = 0; round < SWITCH_ROUNDS; round++) {
    for (size_t k = 0; k < coroutine_work->len; k++) coroutine_work->sum += (unsigned char)coroutine_work->data[k];
    if (round == 0) wait_collections(2);
    assert(swapcontext(&coroutine_context, &caller_context) == 0);
  }
}
#endif

static void blocking_body(void *arg) {
  blocking_work *w = arg;
#ifdef SWITCH_STACK
  void *stack = malloc(COROUTINE_STACK);
  assert(stack && getcontext(&coroutine_context) == 0);
  coroutine_context.uc_stack.ss_sp = stack;
  coroutine_context.uc_stack.ss_size = COROUTINE_STACK;
  coroutine_context.uc_link = &caller_context;
  coroutine_work = w;
  makecontext(&coroutine_context, coroutine, 0);
  for (int round = 0; round < SWITCH_ROUNDS; round++) assert(swapcontext(&caller_context, &coroutine_context) == 0);
  free(stack);
#else
  for (int round = 0; round < SWITCH_ROUNDS; round++)
    for (size_t k = 0; k < w->len; k++) w->sum += (unsigned char)w->data[k];
  wait_collections(2);
#endif
}

/* A copy of the argument made before an_blocking (kept only in this frame, which the collector still scans) comes
   back after it; the call fails when the sum read during it is wrong. */
static an_term blocking_copy(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  blocking_work w = {NULL, 0, 0};
  if (!an_get_string(env, argv[0], &w.data, &w.len)) return an_badarg(env, 0);
  an_term copy = an_string(env, w.data, w.len);
  uint64_t want = 0;
  for (size_t k = 0; k < w.len; k++) want += (unsigned char)w.data[k];
  an_blocking(env, blocking_body, &w);
  if (w.sum != want * SWITCH_ROUNDS) return an_raise(env, "wrong sum");
  /* One more collection, then strings of the copy's size: libgc sweeps lazily, so a copy freed by mistake would only
     show once its block is given out again, with other bytes. */
  wait_collections(1);
  char filler[64];
  memset(filler, 'X', sizeof filler);
  for (int k = 0; k < FILLER_STRINGS; k++) (void)an_string(env, filler, w.len < sizeof filler ? w.len : sizeof filler);
  return copy;
}

static const an_function blocking_functions[] = {{"copy", "(String) -> String", blocking_copy, AN_SHORT},
                                                 {"copy", "(String) -> String", blocking_copy, AN_DIRTY}};
static const an_module blocking_module = {1, 3, sizeof(an_module), "blocking", NULL, blocking_functions, 1, NULL,
                                          0, NULL, 0};
static const an_module blocking_dirty_module = {
  1, 3, sizeof(an_module), "blocking_dirty", NULL, blocking_functions + 1, 1, NULL, 0, NULL, 0};

static const an_module *init_blocking(const an_api *api) {
  (void)api;
  return &blocking_module;
}
static const an_module *init_blocking_dirty(const an_api *api) {
  (void)api;
  return &blocking_dirty_module;
}

static void collect(void *arg) {
  (void)arg;
  assert(agc_gc_thread_enter());
  uv_mutex_lock(&gc_lock);
  for (;;) {
    while (!gc_stop && gc_done == gc_asked) uv_cond_wait(&gc_wake, &gc_lock);
    if (gc_stop) break;
    uv_mutex_unlock(&gc_lock);
    agc_gc_collect();
    uv_mutex_lock(&gc_lock);
    gc_done++;
    uv_cond_broadcast(&gc_wake);
  }
  uv_mutex_unlock(&gc_lock);
  agc_gc_thread_leave();
}

/* A short and a dirty call each run an_blocking (on Linux, on a stack of its own) while another thread collects
   meanwhile: no hang, and the argument and the copy made before it survive the collections and the reuse of freed
   blocks. */
static void test_blocking(void) {
  agc_native_register(&vm, "blocking", init_blocking);
  agc_native_register(&vm, "blocking_dirty", init_blocking_dirty);
  assert(uv_mutex_init(&gc_lock) == 0 && uv_cond_init(&gc_wake) == 0);
  uv_thread_t thread;
  assert(uv_thread_create(&thread, collect, NULL) == 0);
  agc_value word = text("a string the collector must keep");
  assert(same_text(call("module (String) -> String copy blocking", &word, 1), "a string the collector must keep"));
  assert(same_text(dirty("compute module (String) -> String copy blocking_dirty", &word, 1),
                   "a string the collector must keep"));
  uv_mutex_lock(&gc_lock);
  assert(gc_done == 6);
  gc_stop = true;
  uv_cond_broadcast(&gc_wake);
  uv_mutex_unlock(&gc_lock);
  assert(uv_thread_join(&thread) == 0);
  uv_cond_destroy(&gc_wake);
  uv_mutex_destroy(&gc_lock);
}

int main(int argc, char **argv) {
  (void)argc;
  agc_test_io_vm(&vm);
  /* Shape twice more with a variant name that the loader takes but the front end never writes, so that the shape of
     the Shape of the module reads as two variants of other payload counts (test_types). */
  const char *names[] = {"None", "Some", "Dot", "Circle", "Rect", "Dot", "Circle(Int) | Rect(Point, Point)", "Dot",
                         "Circle(Int) | Rect"};
  const uint32_t arities[] = {0, 1, 0, 1, 2, 0, 0, 0, 2};
  for (uint32_t k = 0; k < 9; k++) {
    variants[k].name = agc_make_string(names[k], strlen(names[k]), strlen(names[k]));
    variants[k].arity = arities[k];
    variants[k].shared = arities[k] ? NULL : agc_new_enum(k, 0);
  }
  point_fields[0] = agc_make_string("x", 1, 1);
  point_fields[1] = agc_make_string("y", 1, 1);
  point_fields[2] = agc_make_string("x: Int, y", 9, 9);
  structs[0] = (agc_struct_def){agc_make_string("Point", 5, 5), 2, false, point_fields, NULL, NULL};
  structs[1] = (agc_struct_def){agc_make_string("Point", 5, 5), 1, false, &point_fields[2], NULL, NULL};
  enums[0] = (agc_enum_def){agc_make_string("Shape", 5, 5), 2, 3, NULL, NULL};
  enums[1] = (agc_enum_def){agc_make_string("Shape", 5, 5), 5, 2, NULL, NULL};
  enums[2] = (agc_enum_def){agc_make_string("Shape", 5, 5), 7, 2, NULL, NULL};
  program.variants = variants;
  program.variant_count = 9;
  program.structs = structs;
  program.struct_count = 2;
  program.enums = enums;
  program.enum_count = 3;
  program.optional = 0;
  vm.rt->program = &program;
  agc_native_register(&vm, "demo", agentica_native_init);
  test_values();
  test_failures();
  test_binding();
  test_versions();
  test_types();
  test_a_dirty_call_that_cannot_start();
  test_dirty();
  test_dirty_calls_charge_on_the_scheduler();
  test_resources();
  test_close_during_a_dirty_call();
  test_type_cap();
  test_no_files();
  test_shared_library(argv[0]);
  test_threads();
  test_blocking();
  test_end_of_run();
  agc_test_settle_loop(&vm);
  return 0;
}

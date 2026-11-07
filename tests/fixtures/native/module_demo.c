/* A native module (vm/agentica_native.h, #1149) for the tests and the benchmark: vm/tests/native_module_test.c
   compiles it in as a module the binary carries and opens it as a shared library (mk/vm-test.mk builds it),
   tests/test_vm_native_module.py builds it and calls it from extern module blocks, and benchmarks/native/run.py calls
   `add` and `points`. It links nothing but the C library: every VM call goes through the env. */
/* The header next to the VM's sources, so this file builds with no -I (a module of a package gets the header of the
   binary it runs in). */
#include "../../../vm/agentica_native.h"

#include <stdlib.h>
#include <string.h>

static an_term add(an_env *env, int argc, const an_term *argv) {
  int64_t a, b;
  (void)argc;
  if (!an_get_int(env, argv[0], &a)) return an_badarg(env, 0);
  if (!an_get_int(env, argv[1], &b)) return an_badarg(env, 1);
  return an_int(env, (int64_t)((uint64_t)a + (uint64_t)b));
}

/* The text with its ASCII letters in upper case. */
static an_term upcase(an_env *env, int argc, const an_term *argv) {
  const char *data;
  size_t len;
  (void)argc;
  if (!an_get_string(env, argv[0], &data, &len)) return an_badarg(env, 0);
  char *copy = malloc(len ? len : 1);
  if (!copy) return an_raise(env, "out of memory");
  for (size_t k = 0; k < len; k++) copy[k] = data[k] >= 'a' && data[k] <= 'z' ? (char)(data[k] - 32) : data[k];
  an_term t = an_string(env, copy, len);
  free(copy);
  return t;
}

static an_term reverse(an_env *env, int argc, const an_term *argv) {
  const uint8_t *data;
  size_t len;
  uint8_t *out;
  (void)argc;
  if (!an_get_bytes(env, argv[0], &data, &len)) return an_badarg(env, 0);
  an_term t = an_bytes_fill(env, len, &out);
  for (size_t k = 0; k < len; k++) out[k] = data[len - 1 - k];
  return t;
}

/* The sum of a List[Int]: an item of another type is a bad argument. */
static an_term sum(an_env *env, int argc, const an_term *argv) {
  an_list_cursor c;
  an_term item;
  uint64_t total = 0;
  (void)argc;
  if (!an_list_cursor_begin(env, argv[0], &c, NULL)) return an_badarg(env, 0);
  while (an_list_next(env, &c, &item)) {
    int64_t n;
    if (!an_get_int(env, item, &n)) return an_badarg(env, 0);
    total += (uint64_t)n;
  }
  return an_int(env, (int64_t)total);
}

/* [0, 1, ..., n - 1], one push at a time, with no hint, so the builder grows. */
static an_term range(an_env *env, int argc, const an_term *argv) {
  an_list_builder b;
  int64_t n;
  (void)argc;
  if (!an_get_int(env, argv[0], &n) || n < 0) return an_badarg(env, 0);
  an_list_begin(env, &b, 0);
  for (int64_t k = 0; k < n; k++) an_list_push(env, &b, an_int(env, k));
  return an_list_end(env, &b);
}

/* {"id" => n, "double" => 2n, "square" => n * n}, in one pass. */
static an_term row(an_env *env, int argc, const an_term *argv) {
  int64_t n;
  (void)argc;
  if (!an_get_int(env, argv[0], &n)) return an_badarg(env, 0);
  an_term keys[3] = {an_string(env, "id", 2), an_string(env, "double", 6), an_string(env, "square", 6)};
  uint64_t u = (uint64_t)n;
  an_term values[3] = {an_int(env, n), an_int(env, (int64_t)(2 * u)), an_int(env, (int64_t)(u * u))};
  return an_map_from(env, keys, values, 3);
}

/* The keys of a Map[String, Int], in its order, each followed by "=" and its value: ["a=1", "b=2"]. */
static an_term pairs(an_env *env, int argc, const an_term *argv) {
  an_map_cursor c;
  an_term key, value;
  an_list_builder b;
  size_t len;
  (void)argc;
  if (!an_map_cursor_begin(env, argv[0], &c, &len)) return an_badarg(env, 0);
  an_list_begin(env, &b, len);
  while (an_map_next(env, &c, &key, &value)) {
    const char *data;
    size_t n;
    int64_t v;
    char text[96];
    if (!an_get_string(env, key, &data, &n) || n > 64 || !an_get_int(env, value, &v) || v < 0 || v > 9)
      return an_badarg(env, 0);
    memcpy(text, data, n);
    text[n] = '=';
    text[n + 1] = (char)('0' + v);
    an_list_push(env, &b, an_string(env, text, n + 2));
  }
  return an_list_end(env, &b);
}

/* MAP[KEY] as an Optional. */
static an_term lookup(an_env *env, int argc, const an_term *argv) {
  an_term value;
  (void)argc;
  return an_map_get(env, argv[0], argv[1], &value) ? an_some(env, value) : an_none(env);
}

static an_term put(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  return an_map_put(env, argv[0], argv[1], argv[2]);
}

static an_term or_zero(an_env *env, int argc, const an_term *argv) {
  bool some;
  an_term value;
  (void)argc;
  if (!an_get_optional(env, argv[0], &some, &value)) return an_badarg(env, 0);
  return some ? value : an_int(env, 0);
}

/* ok(n) for a text of decimal digits, else error("not a number"). */
static an_term parse(an_env *env, int argc, const an_term *argv) {
  const char *data;
  size_t len;
  int64_t n = 0;
  (void)argc;
  if (!an_get_string(env, argv[0], &data, &len)) return an_badarg(env, 0);
  for (size_t k = 0; k < len; k++) {
    if (data[k] < '0' || data[k] > '9' || len > 18) return an_error(env, "not a number", 12);
    n = n * 10 + (data[k] - '0');
  }
  return len ? an_ok(env, an_int(env, n)) : an_error(env, "not a number", 12);
}

/* The value of ok(n), or a failure with the error's message. */
static an_term unwrap(an_env *env, int argc, const an_term *argv) {
  bool ok;
  an_term value;
  const char *data;
  size_t len;
  char message[64];
  (void)argc;
  if (!an_get_result(env, argv[0], &ok, &value)) return an_badarg(env, 0);
  if (ok) return value;
  if (!an_get_string(env, value, &data, &len)) return an_badarg(env, 0);
  len = len < sizeof message - 1 ? len : sizeof message - 1;
  memcpy(message, data, len);
  message[len] = '\0';
  return an_raise(env, message);
}

static an_term truthy(an_env *env, int argc, const an_term *argv) {
  bool b;
  double x;
  (void)argc;
  if (!an_get_bool(env, argv[0], &b)) return an_badarg(env, 0);
  if (!an_get_float(env, argv[1], &x)) return an_badarg(env, 1);
  return an_float(env, b ? x * 2 : -x);
}

/* The first items of a List[Int], at most 8, copied through an array. */
static an_term head(an_env *env, int argc, const an_term *argv) {
  an_list_cursor c;
  an_term items[8];
  size_t n = 0;
  (void)argc;
  if (!an_list_cursor_begin(env, argv[0], &c, NULL)) return an_badarg(env, 0);
  while (n < 8 && an_list_next(env, &c, &items[n])) n++;
  return an_list(env, items, n);
}

/* The bytes copied, and empty bytes from an_bytes_fill. */
static an_term copy(an_env *env, int argc, const an_term *argv) {
  const uint8_t *data;
  size_t len;
  (void)argc;
  if (!an_get_bytes(env, argv[0], &data, &len)) return an_badarg(env, 0);
  return an_bytes(env, data, len);
}

static an_term empty(an_env *env, int argc, const an_term *argv) {
  uint8_t *data;
  (void)argc;
  (void)argv;
  return an_bytes_fill(env, 0, &data);
}

static an_term nothing(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  (void)argv;
  return an_void(env);
}

/* Module bugs that the VM reports: text that is not UTF-8, a Map key that is no key, a result of the wrong type. */
static an_term bad_text(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  (void)argv;
  return an_string(env, "\xff", 1);
}

static an_term bad_key(an_env *env, int argc, const an_term *argv) {
  an_term key = an_float(env, 1.5), value = an_int(env, 1);
  (void)argc;
  (void)argv;
  return an_map_from(env, &key, &value, 1);
}

static an_term lie(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  (void)argv;
  return an_string(env, "not an Int", 10);
}

/* The rows of the type table. */
enum { POINT_TYPE, SHAPE_TYPE };
enum { SHAPE_DOT, SHAPE_CIRCLE, SHAPE_RECT };

/* Point(x: y, y: x). */
static an_term flip(an_env *env, int argc, const an_term *argv) {
  an_term fields[2];
  (void)argc;
  if (!an_get_field(env, argv[0], POINT_TYPE, 1, &fields[0]) || !an_get_field(env, argv[0], POINT_TYPE, 0, &fields[1]))
    return an_badarg(env, 0);
  return an_struct(env, POINT_TYPE, fields);
}

static bool get_xy(an_env *env, an_term point, int64_t *x, int64_t *y) {
  an_term t;
  return an_get_field(env, point, POINT_TYPE, 0, &t) && an_get_int(env, t, x) &&
         an_get_field(env, point, POINT_TYPE, 1, &t) && an_get_int(env, t, y);
}

/* 0 for a Dot, r * r for a Circle(r), and the area between the corners of a Rect. */
static an_term area(an_env *env, int argc, const an_term *argv) {
  uint32_t variant;
  an_term first, second;
  int64_t r, x0, y0, x1, y1;
  (void)argc;
  if (!an_get_variant(env, argv[0], SHAPE_TYPE, &variant)) return an_badarg(env, 0);
  if (variant == SHAPE_DOT) return an_int(env, 0);
  if (!an_get_payload(env, argv[0], SHAPE_TYPE, 0, &first)) return an_badarg(env, 0);
  if (variant == SHAPE_CIRCLE)
    return an_get_int(env, first, &r) ? an_int(env, (int64_t)((uint64_t)r * (uint64_t)r)) : an_badarg(env, 0);
  if (!an_get_payload(env, argv[0], SHAPE_TYPE, 1, &second) || !get_xy(env, first, &x0, &y0) ||
      !get_xy(env, second, &x1, &y1))
    return an_badarg(env, 0);
  return an_int(env, (int64_t)(((uint64_t)x1 - (uint64_t)x0) * ((uint64_t)y1 - (uint64_t)y0)));
}

/* Circle(n) for n > 0, else Dot; Rect from (0, 0) to (n, n) when it is a Circle already. */
static an_term grow(an_env *env, int argc, const an_term *argv) {
  uint32_t variant;
  int64_t n;
  (void)argc;
  if (!an_get_variant(env, argv[0], SHAPE_TYPE, &variant)) return an_badarg(env, 0);
  if (!an_get_int(env, argv[1], &n)) return an_badarg(env, 1);
  if (n <= 0) return an_enum(env, SHAPE_TYPE, SHAPE_DOT, NULL);
  if (variant != SHAPE_CIRCLE) return an_enum(env, SHAPE_TYPE, SHAPE_CIRCLE, &argv[1]);
  an_term origin[2] = {an_int(env, 0), an_int(env, 0)}, corner[2] = {argv[1], argv[1]};
  an_term corners[2] = {an_struct(env, POINT_TYPE, origin), an_struct(env, POINT_TYPE, corner)};
  return an_enum(env, SHAPE_TYPE, SHAPE_RECT, corners);
}

/* [Point(x: 0, y: 0), Point(x: 1, y: 2), ...], n of them, at most a million. */
static an_term points(an_env *env, int argc, const an_term *argv) {
  int64_t n;
  an_list_builder b;
  (void)argc;
  if (!an_get_int(env, argv[0], &n) || n < 0 || n > 1000000) return an_badarg(env, 0);
  an_list_begin(env, &b, (size_t)n);
  for (int64_t k = 0; k < n; k++) {
    an_term fields[2] = {an_int(env, k), an_int(env, (int64_t)(2 * (uint64_t)k))};
    an_list_push(env, &b, an_struct(env, POINT_TYPE, fields));
  }
  return an_list_end(env, &b);
}

/* A type index that the table does not have: the call fails. */
static an_term bad_type(an_env *env, int argc, const an_term *argv) {
  an_term fields[2];
  (void)argc;
  fields[0] = fields[1] = argv[0];
  return an_struct(env, SHAPE_TYPE + 1, fields);
}

/* demo_keep keeps a C function pointer that an extern block passes (a callback), and call_kept calls it from inside a
   short call, where the VM refuses callbacks: the callback runs nothing and gives 0. demo_call_kept calls it from an
   extern call, where it runs. */
static int (*kept)(int); // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

AN_EXPORT void demo_keep(int (*f)(int));
AN_EXPORT void demo_keep(int (*f)(int)) { kept = f; }
AN_EXPORT int demo_call_kept(int n);
AN_EXPORT int demo_call_kept(int n) { return kept ? kept(n) : -1; }

static an_term call_kept(an_env *env, int argc, const an_term *argv) {
  int64_t n;
  (void)argc;
  if (!an_get_int(env, argv[0], &n)) return an_badarg(env, 0);
  return an_int(env, demo_call_kept((int)n));
}

static const an_type types[] = {
  {"Point", AN_STRUCT, "x: Int, y: Int"},
  {"Shape", AN_ENUM, "Dot | Circle(Int) | Rect(Point, Point)"},
};

static const an_function functions[] = {
  {"add", "(Int, Int) -> Int", add, AN_SHORT},
  {"upcase", "(String) -> String", upcase, AN_SHORT},
  {"reverse", "(Bytes) -> Bytes", reverse, AN_SHORT},
  {"sum", "(List[Int]) -> Int", sum, AN_SHORT},
  {"range", "(Int) -> List[Int]", range, AN_SHORT},
  {"row", "(Int) -> Map[String, Int]", row, AN_SHORT},
  {"pairs", "(Map[String, Int]) -> List[String]", pairs, AN_SHORT},
  {"lookup", "(Map[String, Int], String) -> Optional[Int]", lookup, AN_SHORT},
  {"put", "(Map[String, Int], String, Int) -> Map[String, Int]", put, AN_SHORT},
  {"or_zero", "(Optional[Int]) -> Int", or_zero, AN_SHORT},
  {"parse", "(String) -> Result[Int]", parse, AN_SHORT},
  {"unwrap", "(Result[Int]) -> Int", unwrap, AN_SHORT},
  {"truthy?", "(Bool, Float) -> Float", truthy, AN_SHORT},
  {"head", "(List[Int]) -> List[Int]", head, AN_SHORT},
  {"copy", "(Bytes) -> Bytes", copy, AN_SHORT},
  {"empty", "() -> Bytes", empty, AN_SHORT},
  {"nothing", "() -> Void", nothing, AN_SHORT},
  {"bad_text", "() -> String", bad_text, AN_SHORT},
  {"bad_key", "() -> Map[String, Int]", bad_key, AN_SHORT},
  {"lie", "() -> Int", lie, AN_SHORT},
  {"crunch", "(Int, Int) -> Int", add, AN_DIRTY},
  {"flip", "(Point) -> Point", flip, AN_SHORT},
  {"area", "(Shape) -> Int", area, AN_SHORT},
  {"grow", "(Shape, Int) -> Shape", grow, AN_SHORT},
  {"points", "(Int) -> List[Point]", points, AN_SHORT},
  {"bad_type", "(Int) -> Point", bad_type, AN_SHORT},
  {"call_kept", "(Int) -> Int", call_kept, AN_SHORT},
};

AN_MODULE_TYPES("module_demo", functions, types, NULL)

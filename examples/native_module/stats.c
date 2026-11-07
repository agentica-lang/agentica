/* The native module of examples/native_module: `summary` gives a struct in an Optional, and `rows` reads a small CSV
   text into typed rows in one call. Build it as README.md says. It includes the header next to the VM's sources. */
#include "../../vm/agentica_native.h"

#include <stdlib.h>
#include <string.h>

/* The rows of the type table, and the variants of Cell in declared order. */
enum { SUMMARY, CELL };
enum { EMPTY, NUMBER, TEXT };

/* The most columns of a CSV text. */
#define MAX_COLUMNS 32

/* Summary(count, min, max, mean) of the values, or none for no values. */
static an_term summary(an_env *env, int argc, const an_term *argv) {
  an_list_cursor c;
  an_term item;
  size_t n;
  double min = 0, max = 0, total = 0, x;
  (void)argc;
  if (!an_list_cursor_begin(env, argv[0], &c, &n)) return an_badarg(env, 0);
  if (n == 0) return an_none(env);
  for (size_t k = 0; an_list_next(env, &c, &item); k++) {
    if (!an_get_float(env, item, &x)) return an_badarg(env, 0);
    min = k == 0 || x < min ? x : min;
    max = k == 0 || x > max ? x : max;
    total += x;
  }
  an_term fields[4] = {an_int(env, (int64_t)n), an_float(env, min), an_float(env, max), an_float(env, total / n)};
  return an_some(env, an_struct(env, SUMMARY, fields));
}

/* Empty for no text, a Number when the whole text is a number, else its Text. */
static an_term cell(an_env *env, const char *text, size_t len) {
  char number[64], *end;
  if (len == 0) return an_enum(env, CELL, EMPTY, NULL);
  if (len < sizeof number) {
    memcpy(number, text, len);
    number[len] = '\0';
    double x = strtod(number, &end);
    an_term value = an_float(env, x);
    if (end == number + len) return an_enum(env, CELL, NUMBER, &value);
  }
  an_term value = an_string(env, text, len);
  return an_enum(env, CELL, TEXT, &value);
}

/* The lines after the header, each a Map from the header's names to its cells; a line with another number of cells
   is an error. A comma always separates: there is no quoting. */
static an_term rows(an_env *env, int argc, const an_term *argv) {
  const char *text;
  size_t len, columns = 0;
  an_term names[MAX_COLUMNS], cells[MAX_COLUMNS];
  an_list_builder b;
  (void)argc;
  if (!an_get_string(env, argv[0], &text, &len)) return an_badarg(env, 0);
  an_list_begin(env, &b, 0);
  const char *at = text, *end = text + len;
  for (size_t line = 0; at < end; line++) {
    const char *stop = memchr(at, '\n', (size_t)(end - at));
    if (!stop) stop = end;
    size_t n = 0;
    for (const char *field = at;;) {
      const char *comma = memchr(field, ',', (size_t)(stop - field));
      const char *cut = comma ? comma : stop;
      if (n == MAX_COLUMNS) return an_error(env, "too many columns", 16);
      if (line == 0)
        names[n++] = an_string(env, field, (size_t)(cut - field));
      else
        cells[n++] = cell(env, field, (size_t)(cut - field));
      if (!comma) break;
      field = comma + 1;
    }
    if (line == 0)
      columns = n;
    else if (n != columns)
      return an_error(env, "a row has another number of cells", 33);
    else
      an_list_push(env, &b, an_map_from(env, names, cells, n));
    at = stop < end ? stop + 1 : end;
  }
  return an_ok(env, an_list_end(env, &b));
}

static const an_type types[] = {
  {"Summary", AN_STRUCT, "count: Int, min: Float, max: Float, mean: Float"},
  {"Cell", AN_ENUM, "Empty | Number(Float) | Text(String)"},
};

static const an_function functions[] = {
  {"summary", "(List[Float]) -> Optional[Summary]", summary, AN_SHORT},
  {"rows", "(String) -> Result[List[Map[String, Cell]]]", rows, AN_SHORT},
};

AN_MODULE_TYPES("stats", functions, types, NULL)

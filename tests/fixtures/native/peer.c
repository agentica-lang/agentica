/* The independent peer of the native calls (tests/test_vm_native.py): a shared library that the test builds with the
   system C compiler, so each C type crosses the boundary through a real ABI. */
#include <ctype.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

static char shout[64];
static int32_t bumps;

int32_t peer_add(int32_t a, int32_t b) { return a + b; }
int64_t peer_mul64(int64_t a, int64_t b) { return a * b; }
double peer_scale(double x, double k) { return x * k; }
bool peer_not(bool b) { return !b; }
int64_t peer_len(const char *s) { return (int64_t)strlen(s); }
void peer_bump(void) { bumps++; }
int32_t peer_bumps(void) { return bumps; }
const char *peer_null(void) { return NULL; }
const char *peer_bad_utf8(void) { return "a\xff" "b"; }

/* The returned text stays in the library; Agentica copies it. */
const char *peer_upper(const char *s) {
  size_t k = 0;
  for (; s[k] && k + 1 < sizeof shout; k++) shout[k] = (char)toupper((unsigned char)s[k]);
  shout[k] = '\0';
  return shout;
}

/* More integer and floating arguments than the registers hold, so some go on the stack. */
int64_t peer_sum9(int32_t a, int32_t b, int32_t c, int32_t d, int32_t e, int32_t f, int32_t g, int32_t h, int64_t i) {
  return (int64_t)a + b + c + d + e + f + g + h + i;
}

double peer_mix(int32_t a, double b, int64_t c, bool d, const char *s, double e, double f, double g, double h,
                double i, double j, double k, double l) {
  return a + b + (double)c + (d ? 1000.0 : 0.0) + (double)strlen(s) + e + f + g + h + i + j + k + l;
}

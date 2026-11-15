/*
 * Float text, checked against the values of the reference behavior
 * (docs/vm/02-reference-behavior.md §2.2), and against the snprintf formatter it replaced
 * over every exponent and random bit patterns.
 */
#include "../core.h"

#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static const struct {
  uint64_t bits;
  const char *text;
} cases[] = {
  {0x3fb999999999999aULL, "0.1"},
  {0x3fd3333333333334ULL, "0.30000000000000004"},
  {0x444b1ae4d6e2ef50ULL, "1e+21"},
  {0x3e7ad7f29abcaf48ULL, "1e-7"},
  {0x430c6bf526340000ULL, "1e+15"},
  {0x4341c37937e08000ULL, "1e+16"},
  {0x4376345785d8a000ULL, "1e+17"},
  {0x4345ee2a2eb5a5c4ULL, "12345678901234568.0"},
  {0x437b69b4ba630f35ULL, "123456789012345680.0"},
  {0x43118b54f22aeb03ULL, "1234567890123456.8"},
  {0x430c6bf52633ffffULL, "999999999999999.9"},
  {0x4341c37937e07fffULL, "9999999999999998.0"},
  {0x4340000000000000ULL, "9007199254740992.0"},
  {0x8000000000000000ULL, "-0.0"},
  {0x0ULL, "0.0"},
  {0x7ff8000000000000ULL, "+nan.0"},
  {0xfff8000000000000ULL, "+nan.0"},
  {0x7ff0000000000000ULL, "+inf.0"},
  {0xfff0000000000000ULL, "-inf.0"},
  {0x1ULL, "5e-324"},
  {0x2ULL, "1e-323"},
  {0x10000000000000ULL, "2.2250738585072014e-308"},
  {0xfffffffffffffULL, "2.225073858507201e-308"},
  {0x7fefffffffffffffULL, "1.7976931348623157e+308"},
  {0x4059000000000000ULL, "100.0"},
  {0x3f1a36e2eb1c432dULL, "0.0001"},
  {0x3ee4f8b588e368f1ULL, "1e-5"},
  {0x3f201f31f46ed246ULL, "0.000123"},
  {0x3f06ce789e774eecULL, "4.35e-5"},
  {0x4415af1d78b58c40ULL, "1e+20"},
  {0x4480f0cf064dd592ULL, "1e+22"},
  {0x42a57207f4439720ULL, "11789751951819.563"},
  {0xc2d3bc5ddc2b8328ULL, "-86798997958156.63"},
  {0x431f6229a4371f49ULL, "2208413816571858.3"},
  {0x60000000000000ULL, "7.120236347223045e-307"},
  {0x100000000000000ULL, "7.291122019556398e-304"},
  {0x40fe240c9fbe76c9ULL, "123456.789"},
  {0xbff8000000000000ULL, "-1.5"},
  {0x54b249ad2594c37dULL, "1e+100"},
  {0x7e41eb2d66005835ULL, "1.5e+300"},
};

static const char min_subnormal[] =
    "4.9406564584124654417656879286822137236505980261432476442558568250067550"
    "727020875186529983636163599237979656469544571773092665671035593979639877"
    "479601078187812630071319031140452784581716784898210368871863605699873072"
    "305000638740915356498438731247339727316961514003171538539807412623856559"
    "117102665855668676818703956031062493194527159149245532930545654440112748"
    "012970999954193198940908041656332452475714786901472678015935523861155013"
    "480352649347201937902681071074917033322268447533357208324319360923828934"
    "583680601060115061698097530783422773183292479049825247307763759272478746"
    "560847782037344696995336470179726777175851256605511991315048911014510378"
    "627381672509558373897335989936648099411642057026370902792427675445652290"
    "8753868250641971826553344726562500000000000000000e-324";

/* The formatter before Ryu: the exact digits from "%.767e", then the first length from 1 to 17 whose nearest candidate
   (ties up) or other neighbour reads back as x. */
static size_t reference_text(double x, char *out) {
  if (isnan(x)) return (size_t)sprintf(out, "+nan.0");
  if (isinf(x)) return (size_t)sprintf(out, x > 0 ? "+inf.0" : "-inf.0");
  size_t at = 0;
  if (signbit(x)) {
    out[at++] = '-';
    x = -x;
  }
  if (x == 0) return at + (size_t)sprintf(out + at, "0.0");
  char exact[800], all[800], digits[20];
  snprintf(exact, sizeof exact, "%.767e", x);
  size_t total = 0;
  for (const char *c = exact; *c != 'e'; c++)
    if (*c != '.') all[total++] = *c;
  int e = atoi(strchr(exact, 'e') + 1), digits_e = e;
  size_t n = 0;
  bool found = false;
  for (size_t precision = 1; precision <= 17 && !found; precision++)
    for (int attempt = 0; attempt < 2 && !found; attempt++) {
      memcpy(digits, all, precision);
      n = precision;
      digits_e = e;
      if ((all[precision] >= '5') != (attempt == 1)) {
        size_t k = n;
        while (k > 0 && digits[k - 1] == '9') digits[--k] = '0';
        if (k == 0) {
          digits[0] = '1';
          digits_e++;
        } else {
          digits[k - 1]++;
        }
      }
      char text[40];
      snprintf(text, sizeof text, "%c.%.*se%d", digits[0], (int)n - 1, digits + 1, digits_e);
      found = strtod(text, NULL) == x;
    }
  while (n > 1 && digits[n - 1] == '0') n--;
  e = digits_e;
  int exponent_digits = snprintf(NULL, 0, "%d", abs(e));
  int positional = (int)n > e + 1 ? (int)n + 1 : e + 3;
  int scientific = (int)n + (n > 1) + 2 + exponent_digits;
  if (e < -4 || (e >= 0 && positional > 16 && positional > scientific))
    return at + (size_t)sprintf(out + at, "%c%s%.*se%c%d", digits[0], n > 1 ? "." : "", (int)n - 1, digits + 1,
                                e < 0 ? '-' : '+', abs(e));
  if (e < 0) {
    at += (size_t)sprintf(out + at, "0.");
    for (int k = -1; k > e; k--) out[at++] = '0';
    return at + (size_t)sprintf(out + at, "%.*s", (int)n, digits);
  }
  if ((int)n > e + 1) return at + (size_t)sprintf(out + at, "%.*s.%.*s", e + 1, digits, (int)n - e - 1, digits + e + 1);
  at += (size_t)sprintf(out + at, "%.*s", (int)n, digits);
  for (int k = (int)n; k < e + 1; k++) out[at++] = '0';
  return at + (size_t)sprintf(out + at, ".0");
}

static uint64_t random_state = 0x9E3779B97F4A7C15u;

static uint64_t random_bits(void) {
  random_state ^= random_state << 13;
  random_state ^= random_state >> 7;
  random_state ^= random_state << 17;
  return random_state;
}

static void check_reference(uint64_t bits) {
  double x;
  memcpy(&x, &bits, sizeof x);
  char got[AGC_SCALAR_TEXT], want[64];
  size_t n = agc_float_text(x, got);
  got[n] = '\0';
  reference_text(x, want);
  if (strcmp(got, want) != 0) fprintf(stderr, "%016llx: got %s, want %s\n", (unsigned long long)bits, got, want);
  assert(strcmp(got, want) == 0);
}

int main(void) {
  double tiny;
  uint64_t tiny_bits = 1;
  memcpy(&tiny, &tiny_bits, sizeof tiny);
  char exact[800];
  snprintf(exact, sizeof exact, "%.767e", tiny);
  assert(strcmp(exact, min_subnormal) == 0);
  for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
    double x;
    memcpy(&x, &cases[i].bits, sizeof x);
    char text[AGC_SCALAR_TEXT];
    size_t n = agc_float_text(x, text);
    text[n] = '\0';
    if (strcmp(text, cases[i].text) != 0) fprintf(stderr, "%s: got %s\n", cases[i].text, text);
    assert(strcmp(text, cases[i].text) == 0);
  }
  for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) check_reference(cases[i].bits);
  uint64_t mantissa = (UINT64_C(1) << 52) - 1;
  for (uint64_t e = 0; e < 0x7FF; e++)
    for (uint64_t m = 0; m < 4; m++) {
      check_reference(e << 52 | m);
      check_reference(e << 52 | (mantissa - m));
      check_reference(e << 52 | (random_bits() & mantissa));
      check_reference(e << 52 | (random_bits() & mantissa & ~((UINT64_C(1) << (random_bits() % 53)) - 1)));
    }
  for (int i = 0; i < 20000; i++) check_reference(random_bits());
  puts("float text tests passed");
  return 0;
}

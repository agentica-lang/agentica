#include "../agc.h"

#include <assert.h>
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

int main(void) {
  for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
    double x;
    memcpy(&x, &cases[i].bits, sizeof x);
    char text[AGC_FLOAT_TEXT];
    size_t n = agc_float_text(x, text);
    text[n] = '\0';
    if (strcmp(text, cases[i].text) != 0) fprintf(stderr, "%s: got %s\n", cases[i].text, text);
    assert(strcmp(text, cases[i].text) == 0);
  }
  puts("float text tests passed");
  return 0;
}

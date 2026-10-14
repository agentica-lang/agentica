/*
 * The generator: a seed repeats, seeds differ, the Float and Int bounds hold,
 * rough uniformity, and low > high.
 */
#include "../core.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
  agc_random a, b;
  agc_random_seed(&a, 7);
  agc_random_seed(&b, 7);
  for (int i = 0; i < 1000; i++) assert(agc_random_next(&a) == agc_random_next(&b));
  agc_random_seed(&b, 8);
  assert(agc_random_next(&a) != agc_random_next(&b));

  agc_random_seed(&a, 0);
  assert(a.s[0] | a.s[1] | a.s[2] | a.s[3]);
  for (int i = 0; i < 1000000; i++) {
    double x = agc_random_float(&a);
    assert(x >= 0.0 && x < 1.0);
  }

  static const int64_t ranges[][2] = {
    {1, 6}, {-5, 5}, {0, 4294967087}, {1, 1000000000000000000}, {INT64_MIN, -1}, {INT64_MIN, INT64_MAX}, {7, 7},
    {INT64_MAX, INT64_MAX}, {INT64_MIN, INT64_MIN}, {-1, INT64_MAX},
  };
  for (size_t i = 0; i < sizeof ranges / sizeof ranges[0]; i++) {
    for (int k = 0; k < 10000; k++) {
      int64_t value;
      assert(agc_random_int(&a, ranges[i][0], ranges[i][1], &value));
      assert(value >= ranges[i][0] && value <= ranges[i][1]);
    }
  }

  int counts[3] = {0, 0, 0};
  for (int k = 0; k < 30000; k++) {
    int64_t value;
    assert(agc_random_int(&a, 0, 2, &value));
    counts[value]++;
  }
  for (int k = 0; k < 3; k++) assert(counts[k] > 9000 && counts[k] < 11000);

  agc_random before = a;
  int64_t unused = 0;
  assert(!agc_random_int(&a, 1, 0, &unused) && unused == 0);
  assert(!agc_random_int(&a, INT64_MAX, INT64_MIN, &unused));
  assert(memcmp(&before, &a, sizeof a) == 0);
  puts("random tests passed");
  return 0;
}

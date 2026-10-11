#include "agc.h"

#include <string.h>

static uint64_t splitmix64(uint64_t *x) {
  uint64_t z = (*x += 0x9e3779b97f4a7c15u);
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9u;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebu;
  return z ^ (z >> 31);
}

void agc_random_seed(agc_random *r, uint64_t seed) {
  for (int k = 0; k < 4; k++) r->s[k] = splitmix64(&seed);
}

static uint64_t rotl(uint64_t x, int k) { return (x << k) | (x >> (64 - k)); }

uint64_t agc_random_next(agc_random *r) {
  uint64_t *s = r->s;
  uint64_t result = rotl(s[1] * 5, 7) * 9;
  uint64_t t = s[1] << 17;
  s[2] ^= s[0];
  s[3] ^= s[1];
  s[1] ^= s[2];
  s[0] ^= s[3];
  s[2] ^= t;
  s[3] = rotl(s[3], 45);
  return result;
}

double agc_random_float(agc_random *r) { return (double)(agc_random_next(r) >> 11) * 0x1.0p-53; }

bool agc_random_int(agc_random *r, int64_t low, int64_t high, int64_t *out) {
  if (low > high) return false;
  uint64_t size = (uint64_t)high - (uint64_t)low + 1;
  uint64_t offset = agc_random_next(r);
  if (size != 0) {
    uint64_t threshold = (0 - size) % size;
    while (offset < threshold) offset = agc_random_next(r);
    offset %= size;
  }
  uint64_t value = (uint64_t)low + offset;
  memcpy(out, &value, sizeof value);
  return true;
}

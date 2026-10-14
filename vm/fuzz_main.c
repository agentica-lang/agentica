/*
 * The plain fuzz driver (make vm-fuzz): it applies 1 to 4 mutations to a
 * fixture and passes each mutant to agc_fuzz_one. Driver layer. Design:
 * docs/vm/11-build-ci-supply-chain.md (Fuzzing).
 */
#include "core.h"
#include "services.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#define MAX_INSERT ((size_t)16)

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
#define AGC_FUZZ_DEATH 1
#endif
#endif
#if defined(__SANITIZE_ADDRESS__)
#define AGC_FUZZ_DEATH 1
#endif

static uint64_t state = 0x9E3779B97F4A7C15u; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static const uint8_t *current; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static size_t current_len; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
static long current_index = -1; // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)

static uint64_t next_random(void) {
  state ^= state << 13;
  state ^= state >> 7;
  state ^= state << 17;
  return state;
}

static uint8_t *read_all(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  size_t cap = 4096, n = 0;
  uint8_t *data = malloc(cap);
  size_t got;
  while (data && (got = fread(data + n, 1, cap - n, f)) > 0) {
    n += got;
    if (n == cap) {
      cap *= 2;
      uint8_t *bigger = realloc(data, cap);
      if (!bigger) free(data);
      data = bigger;
    }
  }
  fclose(f);
  *len = n;
  return data;
}

static size_t mutate_once(uint8_t *data, size_t len) {
  size_t at = len ? (size_t)(next_random() % len) : 0;
  switch (next_random() % 5) {
    case 0: {
      size_t n = 1 + (size_t)(next_random() % MAX_INSERT);
      if (n > len - at) n = len - at;
      memmove(data + at, data + at + n, len - at - n);
      return len - n;
    }
    case 1: {
      size_t n = 1 + (size_t)(next_random() % MAX_INSERT);
      memmove(data + at + n, data + at, len - at);
      for (size_t k = 0; k < n; k++) data[at + k] = (uint8_t)next_random();
      return len + n;
    }
    case 2:
      if (len) data[at] ^= (uint8_t)(1u << (next_random() % 8));
      return len;
    case 3:
      if (len) data[at] = (uint8_t)next_random();
      return len;
    default:
      if (at + 1 < len) {
        uint16_t value = (uint16_t)(next_random() % 4 == 0 ? 0xFFFF : next_random() % 64);
        data[at] = (uint8_t)value;
        data[at + 1] = (uint8_t)(value >> 8);
      }
      return len;
  }
}

#ifdef AGC_FUZZ_DEATH
void __sanitizer_set_death_callback(void (*callback)(void)); // NOLINT(readability-identifier-naming)

static void save_crash(void) {
  if (!current) return;
  fprintf(stderr, "fuzz: crashed at mutant %ld, saved to fuzz-crash.agcb\n", current_index);
  FILE *f = fopen("fuzz-crash.agcb", "wb");
  if (f) {
    fwrite(current, 1, current_len, f);
    fclose(f);
  }
}
#endif

static bool parse_count(const char *text, unsigned long long *out) {
  char *end;
  if (!*text || *text == '-') return false;
  *out = strtoull(text, &end, 10);
  return *end == '\0';
}

static size_t mutate(uint8_t *out, const uint8_t *in, size_t len) {
  memcpy(out, in, len);
  for (int k = 0, rounds = 1 + (int)(next_random() % 4); k < rounds; k++) len = mutate_once(out, len);
  return len;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fputs("usage: agentica-vm-fuzz ITERATIONS file.agcb...\n", stderr);
    return 2;
  }
  unsigned long long runs;
  if (!parse_count(argv[1], &runs) || runs == 0 || runs > LONG_MAX) {
    fprintf(stderr, "agentica-vm-fuzz: ITERATIONS must be a positive integer, got %s\n", argv[1]);
    return 2;
  }
  long iterations = (long)runs;
  const char *seed = getenv("FUZZ_SEED");
  if (seed && *seed) {
    unsigned long long value;
    if (!parse_count(seed, &value)) {
      fprintf(stderr, "agentica-vm-fuzz: FUZZ_SEED must be a non-negative integer, got %s\n", seed);
      return 2;
    }
    state ^= (value + 1) * 0xBF58476D1CE4E5B9u;
    if (!state) state = 0x9E3779B97F4A7C15u;
    fprintf(stderr, "fuzz: seed %llu\n", value);
  }
#ifdef AGC_FUZZ_DEATH
  __sanitizer_set_death_callback(save_crash);
#endif
  int files = argc - 2;
  uint8_t **corpus = calloc((size_t)files, sizeof *corpus);
  size_t *sizes = calloc((size_t)files, sizeof *sizes);
  size_t largest = 0;
  for (int i = 0; i < files; i++) {
    corpus[i] = read_all(argv[i + 2], &sizes[i]);
    if (!corpus[i]) {
      fprintf(stderr, "agentica-vm-fuzz: cannot read %s\n", argv[i + 2]);
      return 2;
    }
    if (agc_fuzz_one(corpus[i], sizes[i]) != 1) {
      fprintf(stderr, "agentica-vm-fuzz: seed %s is not accepted\n", argv[i + 2]);
      return 1;
    }
    if (sizes[i] > largest) largest = sizes[i];
  }
  uint8_t *buffer = malloc(largest + 4 * MAX_INSERT);
  long accepted = 0;
  for (long n = 0; n < iterations; n++) {
    int pick = (int)(next_random() % (uint64_t)files);
    size_t len = mutate(buffer, corpus[pick], sizes[pick]);
    current = buffer;
    current_len = len;
    current_index = n;
    int result = agc_fuzz_one(buffer, len);
    if (result == 1 || result == 2) accepted++;
  }
  printf("fuzz: %ld mutants, %ld accepted and run\n", iterations, accepted);
  return 0;
}

/*
 * The libFuzzer entry point (make vm-libfuzz): each input is one .agcb file for agc_fuzz_one.
 * AFL++, honggfuzz and Centipede call the same function. Driver layer.
 * Design: docs/vm/11-build-ci-supply-chain.md (Fuzzing).
 */
#include "core.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size); // NOLINT(readability-identifier-naming)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  // The return value of agc_fuzz_one (accepted, refused, over the limit) is not a failure; a crash is.
  agc_fuzz_one(data, size);
  return 0;
}

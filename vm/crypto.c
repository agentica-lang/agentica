/*
 * The Crypto builtins (agc_crypto_builtins): hashes of byte lists, the first
 * part of the Crypto module of docs/future/20-crypto.md. The hash itself is
 * the digest adapter (digest.h). Service layer. Design:
 * docs/vm/02-reference-behavior.md §2.3.
 */
#include "services.h"
#include "digest.h"

/* Crypto.sha256(data): the 32 bytes of the digest. Each item must be 0..255, else RUNTIME-INVALID-NUMBER at the
   argument. The work grows with the list, so the row charges AGC_COST_SIZE: one turn-cost unit per item
   (docs/vm/10-io-scheduler.md §10.2.1). Like List.sort or String.from_bytes the call is not split: the task yields
   after it once the cost spends its turn. It runs without the shared lock, since it reads only its argument. */
static agc_value builtin_sha256(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_list *data = agc_as_list(vm, args[0]);
  size_t n = agc_list_len(data);
  /* A GC atomic block (bytes only); the list is read through the cursor, never by its layout. */
  const uint8_t *bytes = agc_byte_list(vm, data, n);
  if (!bytes) agc_fail(vm, "RUNTIME-INVALID-NUMBER", "Crypto.sha256 needs bytes between 0 and 255", span + 1);
  unsigned char digest[AGC_SHA256_BYTES];
  if (!agc_digest_sha256(bytes, n, digest)) agc_fail(vm, "RUNTIME-INTERNAL", "SHA-256 is not available", span);
  agc_list_builder out;
  agc_list_builder_sized(&out, AGC_SHA256_BYTES);
  for (size_t k = 0; k < AGC_SHA256_BYTES; k++) agc_list_builder_push(&out, agc_int(digest[k]));
  return agc_list_value(agc_list_builder_finish(&out));
}

const agc_builtin agc_crypto_builtins[] = {
  {"Crypto.sha256", 1, builtin_sha256, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false, false},
};

const size_t agc_crypto_builtin_count = sizeof agc_crypto_builtins / sizeof agc_crypto_builtins[0];

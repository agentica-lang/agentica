/*
 * The gzip decoder adapter: a streaming gzip-only inflate over the vendored
 * zlib, behind a malloc-only interface. Adapter layer. Design:
 * docs/vm/15-layers.md §15.1.
 */
#ifndef AGC_GUNZIP_H
#define AGC_GUNZIP_H

#include <stddef.h>
#include <stdint.h>

typedef struct agc_gunzip agc_gunzip;

typedef enum {
  AGC_GUNZIP_MORE,
  AGC_GUNZIP_DONE,
  AGC_GUNZIP_FORMAT,
  AGC_GUNZIP_CRC,
  AGC_GUNZIP_NOMEM
} agc_gunzip_status;

/* Starts a gzip-only decoder (windowBits 31: RFC 1952 members with their
   optional FEXTRA/FNAME/FCOMMENT/FHCRC headers and trailer check, no zlib
   wrappers or raw deflate); NULL when there is no memory. */
agc_gunzip *agc_gunzip_begin(void);

/* Inflates the bytes at *inout (of *in_left bytes) into out (of out_cap
   bytes): advances *inout and shrinks *in_left by what was consumed, and
   writes the produced count. DONE ends the single gzip member with its
   trailer validated; MORE needs another call (more input, or room in out);
   FORMAT covers a bad header, reserved flags, a truncated or corrupt stream
   and a refused wrapper; CRC covers a CRC32 or ISIZE mismatch. */
agc_gunzip_status agc_gunzip_feed(agc_gunzip *g, const uint8_t **inout, size_t *in_left, uint8_t *out, size_t out_cap,
                                  size_t *produced);

/* Frees a decoder started by agc_gunzip_begin; NULL is free of charge. */
void agc_gunzip_free(agc_gunzip *g);

#endif

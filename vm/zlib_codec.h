/*
 * The zlib codec adapter: streaming deflate and inflate over zlib, behind a
 * malloc-only interface that never retains a caller pointer. Adapter layer.
 * Design: docs/vm/15-layers.md §15.1, RFC 1950 (zlib), RFC 1951 (deflate)
 * and RFC 1952 (gzip).
 */
#ifndef AGC_ZLIB_CODEC_H
#define AGC_ZLIB_CODEC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct agc_zcodec agc_zcodec;

typedef enum {
  AGC_ZCODEC_MORE,
  AGC_ZCODEC_DONE,
  AGC_ZCODEC_FORMAT,
  AGC_ZCODEC_CHECK,
  AGC_ZCODEC_NOMEM
} agc_zcodec_status;

/* Starts an encoder (window_bits 15 for a zlib wrapper, -15 for raw deflate,
   31 for gzip) at the given level 0..9, or a decoder of one wrapper selected
   the same way (no auto-detect, no dictionaries); NULL when there is no
   memory or the parameters are refused. */
agc_zcodec *agc_zcodec_encode_begin(int window_bits, int level);
agc_zcodec *agc_zcodec_decode_begin(int window_bits);

/* The CRC32 of data (of len bytes) chained after crc: the zlib checksum
   with the ZIP polynomial (RFC 1952 §8), for Zlib.crc32. An empty input
   returns crc unchanged (zlib crc32(Z_NULL, 0) resets to zero, so the empty
   case never reaches zlib). Pure: no stream, no handle, no retained
   pointer. */
uint32_t agc_zlib_crc32(uint32_t crc, const uint8_t *data, size_t len);

/* Feeds the bytes at *inout (of *in_left bytes) through the codec into out
   (of out_cap bytes): advances *inout and shrinks *in_left by what was
   consumed, and writes the produced count. The encoder takes finish for its
   last inputs (Z_FINISH) and NO_FLUSH before that; the decoder always takes
   NO_FLUSH and checks the trailer itself. DONE ends the stream with its
   checksum verified; MORE needs another call (more input, or room in out);
   FORMAT covers a bad header, reserved flags, a truncated or corrupt stream
   and a refused wrapper; CHECK covers a CRC32, ADLER32 or ISIZE mismatch.
   Every return clears the stream's input and output pointers, so no caller
   buffer is retained on any path. */
agc_zcodec_status agc_zcodec_encode(agc_zcodec *c, const uint8_t **inout, size_t *in_left, bool finish, uint8_t *out,
                                    size_t out_cap, size_t *produced);
agc_zcodec_status agc_zcodec_decode(agc_zcodec *c, const uint8_t **inout, size_t *in_left, uint8_t *out,
                                    size_t out_cap, size_t *produced);

/* Frees a codec started by agc_zcodec_encode_begin or agc_zcodec_decode_begin;
   NULL is free of charge. */
void agc_zcodec_free(agc_zcodec *c);

#endif

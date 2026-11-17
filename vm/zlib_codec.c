/*
 * The zlib codec over the maintained zlib, in system or vendored builds:
 * deflate with windowBits 15 (zlib wrapper), -15 (raw) or 31 (gzip), and
 * inflate with the same selection, so each side reads only the wrapper it
 * was started for and the trailer is always checked. Adapter layer, behind
 * zlib_codec.h. Design: docs/vm/15-layers.md §15.1.
 */
#include "zlib_codec.h"

#include <limits.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "zlib.h"

struct agc_zcodec {
  z_stream stream;
  bool encoding, ready;
  /* A gzip decoder: after each member it starts over for the next (members counts the ones that ended), and magic is
     how many bytes of the next member's magic number it has checked. */
  bool multi;
  unsigned members, magic;
};

static const uint8_t gzip_magic[2] = {0x1f, 0x8b};

/* The CRC32 chained after crc: empty input returns crc (never zlib, whose
   NULL call resets to zero), longer inputs run in uInt chunks so the cast
   below never overflows even for a hostile length. */
uint32_t agc_zlib_crc32(uint32_t crc, const uint8_t *data, size_t len) {
  if (len == 0 || !data) return crc;
  uLong acc = (uLong)crc;
  for (size_t at = 0; at < len;) {
    uInt take = len - at > (size_t)UINT_MAX ? UINT_MAX : (uInt)(len - at);
    acc = crc32(acc, data + at, take);
    at += take;
  }
  return (uint32_t)(acc & 0xffffffffUL);
}

static unsigned capped(size_t n) { return n > (size_t)UINT_MAX ? UINT_MAX : (unsigned)n; }

/* The stream holds no caller pointer on any return: the service owns its
   buffers and accounts consumed and produced itself, so a retained next_in
   or next_out could outlive a moved or freed caller buffer. */
static void clear_stream(z_stream *s) {
  s->next_in = Z_NULL;
  s->next_out = Z_NULL;
  s->avail_in = 0;
  s->avail_out = 0;
}

/* Starts either side: the caller's window_bits and level are already
   validated, so a refused init here is only out of memory. */
static agc_zcodec *codec_begin(bool encoding, int window_bits, int level) {
  agc_zcodec *c = calloc(1, sizeof *c);
  if (!c) return NULL;
  c->stream.zalloc = Z_NULL;
  c->stream.zfree = Z_NULL;
  c->stream.opaque = Z_NULL;
  int err = encoding ? deflateInit2(&c->stream, level, Z_DEFLATED, window_bits, 8, Z_DEFAULT_STRATEGY)
                     : inflateInit2(&c->stream, window_bits);
  if (err != Z_OK) {
    free(c);
    return NULL;
  }
  c->encoding = encoding;
  c->multi = !encoding && window_bits == 31;
  c->ready = true;
  return c;
}

agc_zcodec *agc_zcodec_encode_begin(int window_bits, int level) {
  if ((window_bits != 15 && window_bits != -15 && window_bits != 31) || level < 0 || level > 9) return NULL;
  return codec_begin(true, window_bits, level);
}

agc_zcodec *agc_zcodec_decode_begin(int window_bits) {
  if (window_bits != 15 && window_bits != -15 && window_bits != 31) return NULL;
  return codec_begin(false, window_bits, 0);
}

static void take_input(z_stream *s, const uint8_t **inout, size_t *in_left, uint8_t *out, size_t out_cap,
                       unsigned *in_count, unsigned *out_count) {
  *in_count = capped(*in_left);
  *out_count = capped(out_cap);
  s->next_in = (Bytef *)(*inout);
  s->avail_in = *in_count;
  s->next_out = out;
  s->avail_out = *out_count;
}

static void give_back(z_stream *s, const uint8_t **inout, size_t *in_left, unsigned in_count, unsigned out_count,
                      size_t *produced) {
  size_t consumed = (size_t)in_count - s->avail_in;
  /* An empty feed passes a NULL cursor: advancing it, even by zero, is
     undefined, so only a real consumption moves it. */
  if (consumed) *inout += consumed;
  *in_left -= consumed;
  *produced = (size_t)out_count - s->avail_out;
  clear_stream(s);
}

agc_zcodec_status agc_zcodec_encode(agc_zcodec *c, const uint8_t **inout, size_t *in_left, bool finish, uint8_t *out,
                                    size_t out_cap, size_t *produced) {
  *produced = 0;
  if (!c || !c->ready || !c->encoding || !inout || !in_left) return AGC_ZCODEC_FORMAT;
  if (out_cap == 0) return AGC_ZCODEC_MORE;
  unsigned in_count = 0, out_count = 0;
  take_input(&c->stream, inout, in_left, out, out_cap, &in_count, &out_count);
  int ret = deflate(&c->stream, finish ? Z_FINISH : Z_NO_FLUSH);
  give_back(&c->stream, inout, in_left, in_count, out_count, produced);
  switch (ret) {
    case Z_STREAM_END: return AGC_ZCODEC_DONE;
    case Z_OK:
    case Z_BUF_ERROR: return AGC_ZCODEC_MORE;
    case Z_MEM_ERROR: return AGC_ZCODEC_NOMEM;
    default: return AGC_ZCODEC_FORMAT;
  }
}

static bool is_check_error(const char *message) {
  if (!message) return false;
  return strstr(message, "incorrect data check") != NULL || strstr(message, "incorrect length check") != NULL;
}

agc_zcodec_status agc_zcodec_decode(agc_zcodec *c, const uint8_t **inout, size_t *in_left, uint8_t *out,
                                    size_t out_cap, size_t *produced) {
  *produced = 0;
  if (!c || !c->ready || c->encoding || !inout || !in_left) return AGC_ZCODEC_FORMAT;
  if (out_cap == 0) return AGC_ZCODEC_MORE;
  /* After a member, bytes that are not the magic number of another are trailing bytes: refused before zlib sees them,
     so the error is not that of a corrupt second member. */
  for (size_t at = 0; c->multi && c->members > 0 && c->magic < 2 && at < *in_left; at++, c->magic++)
    if ((*inout)[at] != gzip_magic[c->magic]) return AGC_ZCODEC_TRAILING;
  unsigned in_count = 0, out_count = 0;
  take_input(&c->stream, inout, in_left, out, out_cap, &in_count, &out_count);
  /* Z_NO_FLUSH only: the decoder never finishes a stream by itself, so the
     caller sees every trailing byte as unconsumed input. */
  int ret = inflate(&c->stream, Z_NO_FLUSH);
  const char *message = c->stream.msg;
  give_back(&c->stream, inout, in_left, in_count, out_count, produced);
  switch (ret) {
    case Z_STREAM_END:
      if (c->multi) {
        c->members++;
        c->magic = 0;
        if (inflateReset(&c->stream) != Z_OK) return AGC_ZCODEC_FORMAT;
      }
      return AGC_ZCODEC_DONE;
    case Z_OK:
    case Z_BUF_ERROR: return AGC_ZCODEC_MORE;
    case Z_MEM_ERROR: return AGC_ZCODEC_NOMEM;
    case Z_NEED_DICT:
    case Z_DATA_ERROR: return is_check_error(message) ? AGC_ZCODEC_CHECK : AGC_ZCODEC_FORMAT;
    default: return AGC_ZCODEC_FORMAT;
  }
}

unsigned agc_zcodec_members(const agc_zcodec *c) { return c && c->multi ? c->members : 0; }

void agc_zcodec_free(agc_zcodec *c) {
  if (!c) return;
  if (c->ready) {
    if (c->encoding)
      deflateEnd(&c->stream);
    else
      inflateEnd(&c->stream);
  }
  free(c);
}

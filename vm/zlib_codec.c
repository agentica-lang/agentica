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
};

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
  unsigned in_count = 0, out_count = 0;
  take_input(&c->stream, inout, in_left, out, out_cap, &in_count, &out_count);
  /* Z_NO_FLUSH only: the decoder never finishes a stream by itself, so the
     caller sees every trailing byte as unconsumed input. */
  int ret = inflate(&c->stream, Z_NO_FLUSH);
  const char *message = c->stream.msg;
  give_back(&c->stream, inout, in_left, in_count, out_count, produced);
  switch (ret) {
    case Z_STREAM_END: return AGC_ZCODEC_DONE;
    case Z_OK:
    case Z_BUF_ERROR: return AGC_ZCODEC_MORE;
    case Z_MEM_ERROR: return AGC_ZCODEC_NOMEM;
    case Z_NEED_DICT:
    case Z_DATA_ERROR: return is_check_error(message) ? AGC_ZCODEC_CHECK : AGC_ZCODEC_FORMAT;
    default: return AGC_ZCODEC_FORMAT;
  }
}

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

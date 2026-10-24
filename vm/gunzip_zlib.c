/*
 * The gzip decoder over the vendored zlib: inflate with windowBits 31, so
 * only RFC 1952 gzip members decode and their trailer is checked. Adapter
 * layer, behind gunzip.h. Design: docs/vm/15-layers.md §15.1.
 */
#include "gunzip.h"

#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "zlib.h"

struct agc_gunzip {
  z_stream stream;
  bool ready;
};

agc_gunzip *agc_gunzip_begin(void) {
  agc_gunzip *g = calloc(1, sizeof *g);
  if (!g) return NULL;
  g->stream.zalloc = Z_NULL;
  g->stream.zfree = Z_NULL;
  g->stream.opaque = Z_NULL;
  /* 31 = 15 + 16: gzip decoding with automatic header parsing (FEXTRA,
     FNAME, FCOMMENT, FHCRC) and CRC32 + ISIZE trailer validation. A zlib
     wrapper or raw deflate stream is refused here, never decoded. */
  if (inflateInit2(&g->stream, 31) != Z_OK) {
    free(g);
    return NULL;
  }
  g->ready = true;
  return g;
}

static bool is_check_error(const char *message) {
  if (!message) return false;
  return strstr(message, "incorrect data check") != NULL || strstr(message, "incorrect length check") != NULL;
}

agc_gunzip_status agc_gunzip_feed(agc_gunzip *g, const uint8_t **inout, size_t *in_left, uint8_t *out, size_t out_cap,
                                  size_t *produced) {
  *produced = 0;
  if (!g || !g->ready) return AGC_GUNZIP_FORMAT;
  if (out_cap == 0) return AGC_GUNZIP_MORE;
  uInt in_count = *in_left > (size_t)UINT_MAX ? UINT_MAX : (uInt)*in_left;
  uInt out_count = out_cap > (size_t)UINT_MAX ? UINT_MAX : (uInt)out_cap;
  g->stream.next_in = (Bytef *)(*inout);
  g->stream.avail_in = in_count;
  g->stream.next_out = out;
  g->stream.avail_out = out_count;
  int ret = inflate(&g->stream, Z_NO_FLUSH);
  size_t consumed = in_count - g->stream.avail_in;
  *inout += consumed;
  *in_left -= consumed;
  *produced = out_count - g->stream.avail_out;
  switch (ret) {
    case Z_STREAM_END: return AGC_GUNZIP_DONE;
    case Z_OK:
    case Z_BUF_ERROR: return AGC_GUNZIP_MORE;
    case Z_MEM_ERROR: return AGC_GUNZIP_NOMEM;
    case Z_DATA_ERROR: return is_check_error(g->stream.msg) ? AGC_GUNZIP_CRC : AGC_GUNZIP_FORMAT;
    default: return AGC_GUNZIP_FORMAT;
  }
}

void agc_gunzip_free(agc_gunzip *g) {
  if (!g) return;
  if (g->ready) inflateEnd(&g->stream);
  free(g);
}

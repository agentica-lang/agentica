/*
 * The HTTP head and body adapter interface: the limits, agc_http_error with
 * its status and text, the head parsers, the framing rules and the body
 * decoder. Adapter header: it uses no core, port or service header. Design:
 * docs/vm/10-io-http.md §10.6.
 */
#ifndef AGC_HTTP_PARSE_H
#define AGC_HTTP_PARSE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define AGC_HTTP_MAX_LINE ((size_t)8192)
#define AGC_HTTP_MAX_BLOCK ((size_t)65536)
#define AGC_HTTP_MAX_HEADERS ((size_t)100)
#define AGC_HTTP_MAX_HEAD (AGC_HTTP_MAX_LINE + 4 + AGC_HTTP_MAX_BLOCK)
#define AGC_HTTP_MAX_INTERIM 15

typedef enum { AGC_HTTP_OK, AGC_HTTP_INCOMPLETE, AGC_HTTP_ERROR } agc_http_status;

typedef enum {
  AGC_HTTP_ERR_NONE,
  AGC_HTTP_ERR_HEAD,
  AGC_HTTP_ERR_BARE_LF,
  AGC_HTTP_ERR_LINE_TOO_LONG,
  AGC_HTTP_ERR_BLOCK_TOO_LARGE,
  AGC_HTTP_ERR_TOO_MANY_HEADERS,
  AGC_HTTP_ERR_VERSION,
  AGC_HTTP_ERR_METHOD,
  AGC_HTTP_ERR_CONNECT,
  AGC_HTTP_ERR_TARGET,
  AGC_HTTP_ERR_OBS_FOLD,
  AGC_HTTP_ERR_HEADER,
  AGC_HTTP_ERR_HOST,
  AGC_HTTP_ERR_STATUS,
  AGC_HTTP_ERR_UPGRADE,
  AGC_HTTP_ERR_INTERIM,
  AGC_HTTP_ERR_AMBIGUOUS,
  AGC_HTTP_ERR_LENGTH,
  AGC_HTTP_ERR_TRANSFER,
  AGC_HTTP_ERR_TOO_LARGE,
  AGC_HTTP_ERR_CHUNK,
  AGC_HTTP_ERR_CHUNK_END,
  AGC_HTTP_ERR_TRAILER,
  AGC_HTTP_ERR_TRUNCATED
} agc_http_error;

typedef enum { AGC_HTTP_FRAME_LENGTH, AGC_HTTP_FRAME_CHUNKED, AGC_HTTP_FRAME_CLOSE } agc_http_frame;

typedef enum {
  AGC_HTTP_BODY_DATA,
  AGC_HTTP_BODY_SIZE,
  AGC_HTTP_BODY_EXTENSION,
  AGC_HTTP_BODY_SIZE_LF,
  AGC_HTTP_BODY_CHUNK,
  AGC_HTTP_BODY_CHUNK_CR,
  AGC_HTTP_BODY_CHUNK_LF,
  AGC_HTTP_BODY_TRAILER,
  AGC_HTTP_BODY_TRAILER_NAME,
  AGC_HTTP_BODY_TRAILER_VALUE,
  AGC_HTTP_BODY_TRAILER_LF,
  AGC_HTTP_BODY_END_LF,
  AGC_HTTP_BODY_DONE,
  AGC_HTTP_BODY_FAILED
} agc_http_body_state;

typedef struct {
  const uint8_t *data;
  size_t len;
} agc_http_slice;

typedef struct {
  agc_http_slice name, value;
} agc_http_field;

typedef struct {
  agc_http_slice method, target, reason;
  int status;
  agc_http_frame frame;
  uint64_t length;
  size_t count;
  agc_http_field fields[AGC_HTTP_MAX_HEADERS];
} agc_http_head;

typedef struct {
  agc_http_frame frame;
  agc_http_body_state state;
  agc_http_error error;
  uint64_t remaining, limit, size;
  size_t line, block, count, name_len;
  char name[24];
  uint8_t *data;
  size_t len, cap;
} agc_http_body;

int agc_http_error_code(agc_http_error error);
const char *agc_http_error_text(agc_http_error error);
bool agc_http_token(const uint8_t *s, size_t len);
bool agc_http_value_byte(uint8_t c);
bool agc_http_named(agc_http_slice name, const char *lower);
agc_http_slice agc_http_trim(agc_http_slice s);
agc_http_error agc_http_framing(agc_http_head *head, bool request);
agc_http_status agc_http_parse_request_head(const uint8_t *buf, size_t len, agc_http_head *out, size_t *used,
                                            agc_http_error *error);
agc_http_status agc_http_parse_response_head(const uint8_t *buf, size_t len, agc_http_head *out, size_t *used,
                                             agc_http_error *error);
void agc_http_body_init(agc_http_body *b, agc_http_frame frame, uint64_t length, uint64_t limit);
agc_http_status agc_http_body_feed(agc_http_body *b, const uint8_t *in, size_t len, size_t *used);
agc_http_status agc_http_body_end(agc_http_body *b);
void agc_http_body_free(agc_http_body *b);

#endif

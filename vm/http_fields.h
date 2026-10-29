/*
 * Header fields and bytes that the HTTP client and server share: the byte
 * buffer, the header writer, the kept fields and List[Header], and the
 * connection-close checks. Service header. Design: docs/vm/10-io-http.md §10.7.
 */
#ifndef AGC_HTTP_FIELDS_H
#define AGC_HTTP_FIELDS_H

#include "services.h"
#include "http_parse.h"

typedef struct {
  uint8_t *data;
  size_t len, cap;
} agc_http_bytes;

typedef struct {
  size_t count;
  size_t *sizes;
  uint8_t *data;
} agc_http_fields;

void agc_http_put(agc_http_bytes *b, const void *data, size_t n);
void agc_http_put_text(agc_http_bytes *b, const char *text);
const char *agc_http_put_headers(agc_vm *vm, agc_http_bytes *b, const agc_list *headers, const char *const *managed,
                                 size_t managed_count, const char *managed_reason, const char *skip, size_t *count);
void agc_http_fields_keep(agc_http_fields *f, const agc_http_head *head);
void agc_http_fields_free(agc_http_fields *f);
size_t agc_http_fields_bytes(const agc_http_fields *f);
agc_value agc_http_header_list(agc_vm *vm, const agc_http_fields *f);
bool agc_http_closes(const agc_http_head *head);
agc_http_slice agc_http_text(agc_vm *vm, agc_value v);
bool agc_http_list_closes(agc_vm *vm, const agc_list *headers);
agc_value agc_http_error_result(const char *prefix, const char *reason);
/* The HttpWire.Text of buf[0, len): its UTF-8 text up to an unfinished last
   character, which comes back as the carry (a Bytes, or a byte list with
   list), and bytes, the count read. Not a Result: when the text is not UTF-8,
   valid is false and text and carry empty. */
agc_value agc_http_text_value(agc_vm *vm, const uint8_t *buf, size_t len, size_t bytes, size_t buffered,
                              bool ended, bool list);
agc_value agc_http_head_value(agc_vm *vm, const uint8_t *buf, size_t len, uint64_t limit, size_t buffered);
agc_value agc_http_response_value(agc_vm *vm, const uint8_t *buf, size_t len, bool head_only, uint64_t limit,
                                  int read_error, size_t buffered, bool ended);
int64_t agc_http_max_body(agc_vm *vm, agc_value v, uint32_t span);

#endif

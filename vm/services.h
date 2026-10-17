/*
 * The exports of the services: the builtin tables that builtin_tables.c lists,
 * the entry points that the core and the driver call, and the types that the
 * services share. Services header. Design: docs/vm/15-layers.md §15.4.
 */
#ifndef AGC_SERVICES_H
#define AGC_SERVICES_H

#include "port.h"

struct agc_test_note {
  agc_string *message, *expected, *actual;
  uint32_t span;
};

typedef struct {
  uint8_t *data;
  size_t start, end, cap, scanned;
  bool eof;
  int error;
} agc_inbuf;

typedef enum {
  AGC_JSON_PARSED, AGC_JSON_CONTROL, AGC_JSON_INVALID, AGC_JSON_EMPTY, AGC_JSON_TRAILING, AGC_JSON_NOT_FINITE
} agc_json_status;

typedef enum { AGC_NUMBER_OK, AGC_NUMBER_INVALID, AGC_NUMBER_OVERFLOW } agc_number_status;

#define AGC_NOT_FOUND SIZE_MAX

/* agc_remove_tree returns 0, an errno, or one of these. */
#define AGC_TREE_TOO_DEEP (-1)
#define AGC_TREE_REFUSED (-2)
#define AGC_TREE_MAX_DEPTH 128

size_t agc_utf8_encode(uint32_t cp, char out[4]);
size_t agc_utf8_offset(agc_vm *vm, const agc_string *s, size_t index);
size_t agc_text_find(const agc_string *text, const agc_string *part, size_t from);
agc_string *agc_change_case(const agc_string *s, bool up);
agc_number_status agc_parse_int(const uint8_t *s, size_t len, int64_t *value);
agc_number_status agc_parse_float(const uint8_t *s, size_t len, double *value);
agc_string *agc_around(const char *before, const agc_string *part, const char *after);

const char *agc_json_version(void);
agc_json_status agc_json_parse(agc_vm *vm, const uint8_t *text, size_t len, agc_value *out);
const char *agc_json_status_message(agc_json_status status);
bool agc_json_to_float(agc_vm *vm, const agc_json *j, double *out);
agc_value agc_json_decode(agc_vm *vm, agc_value root, uint32_t type);
agc_value agc_json_schema(agc_vm *vm, uint32_t type);

void agc_processes_stop(agc_vm *vm);
void agc_files_init(agc_vm *vm);
agc_file_ids agc_files_inherited(void);
void agc_files_forget(agc_file_ids *ids, int fd);
void agc_files_close(agc_vm *vm);
char *agc_host_path(agc_vm *vm, const agc_string *s);
agc_value agc_utf8_error(const uint8_t *data, size_t len);
agc_value agc_system_error(agc_vm *vm, const char *what, int err);
bool agc_tree_refused(const char *path);
/* Removes the tree at path; on a failure inside it, *failed is a malloc'd path of the entry that failed, else NULL. */
int agc_remove_tree(const char *path, char **failed);
#if defined(__linux__) || defined(__APPLE__)
bool agc_each_fd(bool (*visit)(int fd, void *data), void *data);
#endif

struct uv_stream_s;
struct uv_write_s;
agc_value agc_stream_bad_timeout(void);
agc_value agc_stream_timed_out(void);
agc_resource *agc_new_lock(agc_vm *vm);
bool agc_stream_lock(agc_vm *vm, agc_resource *lock, int64_t *timeout, agc_value *result);
size_t agc_inbuf_pending(const agc_inbuf *b);
void agc_inbuf_free(agc_inbuf *b);
bool agc_inbuf_ready(agc_inbuf *b, bool line, size_t count);
size_t agc_inbuf_want(const agc_inbuf *b, bool line, size_t count);
uint8_t *agc_inbuf_room(agc_inbuf *b, size_t want);
void agc_inbuf_got(agc_inbuf *b, int64_t n, bool eof);
agc_value agc_inbuf_line(agc_vm *vm, agc_inbuf *b, const char *too_long, const char *at_end, bool *over);
agc_value agc_inbuf_bytes(agc_vm *vm, agc_inbuf *b, size_t count);
void agc_inbuf_take(agc_inbuf *b, size_t n);
int agc_stream_write(struct uv_stream_s *stream, struct uv_write_s *req, uint8_t **copy, const uint8_t *data,
                     size_t len, void (*done)(struct uv_write_s *req, int status));

#define AGC_CHANNEL_ENV "AGENTICA_CHANNEL"
#define AGC_CHANNEL_VALUE "3"
#define AGC_CHANNEL_FD 3

typedef struct agc_duplex agc_duplex;

agc_duplex *agc_duplex_new(agc_vm *vm, int fd);
void agc_duplex_shut(agc_duplex *d);
void agc_duplex_release(agc_duplex *d);
void agc_duplex_overflow(agc_duplex *d, const char *text);
agc_value agc_duplex_read_line(agc_vm *vm, agc_duplex *d, agc_resource *lock, int64_t timeout);
agc_value agc_duplex_send(agc_vm *vm, agc_duplex *d, agc_resource *lock, agc_value line, int64_t timeout);
agc_value agc_duplex_close_write(agc_vm *vm, agc_duplex *d, agc_resource *lock, int64_t timeout);
void agc_parent_take(agc_vm *vm);
bool agc_parent_open(agc_vm *vm);
agc_input_status agc_parent_line(agc_vm *vm, agc_string **line);
bool agc_parent_send(agc_vm *vm, const agc_string *text);

extern const agc_builtin agc_string_builtins[];
extern const size_t agc_string_builtin_count;
extern const agc_builtin agc_number_builtins[];
extern const size_t agc_number_builtin_count;
extern const agc_builtin agc_json_builtins[];
extern const size_t agc_json_builtin_count;
extern const agc_builtin agc_file_builtins[];
extern const size_t agc_file_builtin_count;
extern const agc_builtin agc_system_builtins[];
extern const size_t agc_system_builtin_count;
extern const agc_builtin agc_process_builtins[];
extern const size_t agc_process_builtin_count;
extern const agc_builtin agc_duplex_builtins[];
extern const size_t agc_duplex_builtin_count;
extern const agc_builtin agc_tcp_builtins[];
extern const size_t agc_tcp_builtin_count;
extern const agc_builtin agc_http_builtins[];
extern const size_t agc_http_builtin_count;
extern const agc_builtin agc_http_server_builtins[];
extern const size_t agc_http_server_builtin_count;
extern const agc_builtin agc_logger_builtins[];
extern const size_t agc_logger_builtin_count;
extern const agc_builtin agc_test_builtins[];
extern const size_t agc_test_builtin_count;
extern const agc_builtin agc_front_end_builtins[];
extern const size_t agc_front_end_builtin_count;

#endif

/*
 * The exports of the services: the builtin tables that builtin_tables.c lists,
 * the entry points that the core and the driver call, and the types that the
 * services share. Services header. Design: docs/vm/15-layers.md §15.4.
 */
#ifndef AGC_SERVICES_H
#define AGC_SERVICES_H

#include "port.h"

/* The errors of a call that --deny-fs, --deny-net or --deny-env turns off (rt->deny_fs, deny_net, deny_env).
   Programs may test the prefix up to the flag ("denied: --deny-fs"), so it is stable. */
#define AGC_DENIED_FS "denied: --deny-fs turns off file access"
#define AGC_DENIED_NET "denied: --deny-net turns off the network"
#define AGC_DENIED_ENV "denied: --deny-env turns off environment variables"

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

/* A read cut out of an agc_inbuf by the thread that owns the buffer, so that another thread builds its value later
   (vm/tcp.c: the I/O thread cuts, the done half builds). `data` is malloc'd; the statuses are a line or bytes, a line
   longer than the limit, a read error, and the end of input. */
typedef enum { AGC_CUT_DATA, AGC_CUT_OVER, AGC_CUT_FAILED, AGC_CUT_END } agc_cut_status;

typedef struct {
  agc_cut_status status;
  int error;
  uint8_t *data;
  size_t len;
} agc_inbuf_cut;

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
/* The lines of a file by path, read with a block buffer: the reader of File.each_line and File.foreach (vm/lazy.c),
   driven by a stepper one line at a time. Its steps start file jobs and close the handle, so the stepper that drives
   it runs with rt->sync (it is not `unlocked`). agc_lines_new opens nothing; the first agc_lines_next opens the file.
   LINE puts the next line in *out; WAIT means the task parks on a file job, whose result is the `last` of the next
   call; END puts the outcome in *out (ok() at the end of the file, else the error) and comes only after the file is
   closed. agc_lines_stop, between two lines, ends the reader with that outcome: the next calls close the file. */
typedef struct agc_line_reader agc_line_reader;
typedef enum { AGC_LINES_LINE, AGC_LINES_WAIT, AGC_LINES_END } agc_lines_status;
bool agc_lines_buffer_ok(int64_t buffer_bytes);
agc_line_reader *agc_lines_new(agc_vm *vm, agc_value path, int64_t buffer_bytes, int64_t timeout, uint32_t span);
agc_lines_status agc_lines_next(agc_vm *vm, agc_line_reader *r, agc_value last, agc_value *out);
void agc_lines_stop(agc_line_reader *r, agc_value outcome);
/* The lines of Lazy.write_lines (vm/lazy.c) into a file by path, created or truncated: the same rules as the reader.
   agc_writer_new opens nothing; the first agc_writer_next opens the file. READY means the writer waits for a line:
   the next call passes it as `line` (a String; Void passes none). WAIT means the task parks on a file job, whose
   result is the `last` of the next call (with a Void line). END puts the outcome in *out and comes only after the
   file is flushed and closed. agc_writer_stop, while READY, ends the writer with that outcome: the next calls close
   the file. */
typedef struct agc_line_writer agc_line_writer;
typedef enum { AGC_WRITER_READY, AGC_WRITER_WAIT, AGC_WRITER_END } agc_writer_status;
agc_line_writer *agc_writer_new(agc_vm *vm, agc_value path, int64_t timeout, uint32_t span);
agc_writer_status agc_writer_next(agc_vm *vm, agc_line_writer *w, agc_value last, agc_value line, agc_value *out);
void agc_writer_stop(agc_line_writer *w, agc_value outcome);
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
/* The result of a finished write: Ok(Void), or the write error for a negative libuv status. */
agc_value agc_stream_written(agc_vm *vm, int status);
agc_resource *agc_new_lock(agc_vm *vm);
bool agc_stream_lock(agc_vm *vm, agc_resource *lock, int64_t *timeout, agc_value *result);
size_t agc_inbuf_pending(const agc_inbuf *b);
void agc_inbuf_free(agc_inbuf *b);
bool agc_inbuf_ready(agc_inbuf *b, bool line, size_t count);
size_t agc_inbuf_want(const agc_inbuf *b, bool line, size_t count);
uint8_t *agc_inbuf_room(agc_inbuf *b, size_t want);
void agc_inbuf_got(agc_inbuf *b, int64_t n, bool eof);
bool agc_inbuf_unread(agc_inbuf *b, const uint8_t *data, size_t len);
agc_value agc_inbuf_line(agc_vm *vm, agc_inbuf *b, const char *too_long, const char *at_end, bool *over);
agc_value agc_inbuf_bytes(agc_vm *vm, agc_inbuf *b, size_t count);
void agc_inbuf_take(agc_inbuf *b, size_t n);
void agc_inbuf_cut_line(agc_inbuf *b, agc_inbuf_cut *cut);
void agc_inbuf_cut_bytes(agc_inbuf *b, size_t count, agc_inbuf_cut *cut);
agc_value agc_inbuf_cut_line_value(agc_vm *vm, const agc_inbuf_cut *cut, const char *too_long, const char *at_end);
agc_value agc_inbuf_cut_bytes_value(agc_vm *vm, const agc_inbuf_cut *cut);
void agc_inbuf_cut_free(agc_inbuf_cut *cut);
int agc_stream_write(struct uv_stream_s *stream, struct uv_write_s *req, uint8_t **copy, const uint8_t *data,
                     size_t len, void (*done)(struct uv_write_s *req, int status));

#define AGC_CHANNEL_ENV "AGENTICA_CHANNEL"

typedef struct agc_duplex agc_duplex;

agc_duplex *agc_duplex_new(agc_loop *io, int read_fd, int write_fd);
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
extern const agc_builtin agc_crypto_builtins[];
extern const size_t agc_crypto_builtin_count;
extern const agc_builtin agc_json_builtins[];
extern const size_t agc_json_builtin_count;
extern const agc_builtin agc_file_builtins[];
extern const size_t agc_file_builtin_count;
extern const agc_builtin agc_lazy_builtins[];
extern const size_t agc_lazy_builtin_count;
char *agc_system_env(const char *name);
/* Size of the buffers that hold an operating system name. */
#define AGC_OS_NAME_MAX 64
/* The System.os name for a uname sysname (NULL when there is none); see system.c. */
void agc_system_os_name(const char *sysname, char *out, size_t size);

extern const agc_builtin agc_system_builtins[];
extern const size_t agc_system_builtin_count;
extern const agc_builtin agc_process_builtins[];
extern const size_t agc_process_builtin_count;
extern const agc_builtin agc_duplex_builtins[];
extern const size_t agc_duplex_builtin_count;
extern const agc_builtin agc_tcp_builtins[];
extern const size_t agc_tcp_builtin_count;
extern const agc_builtin agc_http_service_builtins[];
extern const size_t agc_http_service_builtin_count;
extern const agc_builtin agc_http_server_builtins[];
extern const size_t agc_http_server_builtin_count;
extern const agc_builtin agc_http_wire_builtins[];
extern const size_t agc_http_wire_builtin_count;
extern const agc_builtin agc_logger_builtins[];
extern const size_t agc_logger_builtin_count;
extern const agc_builtin agc_test_builtins[];
extern const size_t agc_test_builtin_count;
extern const agc_builtin agc_ffi_builtins[];
extern const size_t agc_ffi_builtin_count;
/* Whether a run may start PROGRAM: NULL, or the code of the refusal with its message and span, when the program
   imports a native builtin (Native.call for its extern functions, or a Native.wait_*) and this build cannot call
   native code or DENY (--deny-native) refuses it. */
const char *agc_ffi_refusal(const agc_program *program, bool deny, const char **message, uint32_t *span);
extern const agc_builtin agc_front_end_builtins[];
extern const size_t agc_front_end_builtin_count;
extern const agc_builtin agc_std_builtins[];
extern const size_t agc_std_builtin_count;

#endif

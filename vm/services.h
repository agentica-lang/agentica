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
   longer than the limit, a read error, and the end of input. PARTIAL is only made by agc_inbuf_drop_unterminated's
   callers (the child channel): a final line that the end of input cut off, with no data kept. Their value is made by
   the caller (duplex.c cut_value): agc_inbuf_cut_line_value must never see it. */
typedef enum { AGC_CUT_DATA, AGC_CUT_OVER, AGC_CUT_FAILED, AGC_CUT_END, AGC_CUT_PARTIAL } agc_cut_status;

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
/* A byte pattern prepared for a search in linear time: KMP above 8 bytes (FAIL, a GC block), memchr and memcmp at or
   below. agc_finder_find returns the first match in T[0..N) that starts at FROM or later, or AGC_NOT_FOUND; it reads
   at most N - FROM bytes of T, each a bounded number of times. */
typedef struct {
  const uint8_t *p;
  size_t m;
  size_t *fail;
} agc_finder;
agc_finder agc_finder_new(const uint8_t *p, size_t m);
size_t agc_finder_find(const agc_finder *f, const uint8_t *t, size_t n, size_t from);
agc_string *agc_change_case(const agc_string *s, bool up);
agc_number_status agc_parse_int(const uint8_t *s, size_t len, int64_t *value);
agc_number_status agc_parse_float(const uint8_t *s, size_t len, double *value);
agc_string *agc_around(const char *before, const agc_string *part, const char *after);

const char *agc_json_version(void);
agc_json_status agc_json_parse(agc_vm *vm, const uint8_t *text, size_t len, agc_value *out);
const char *agc_json_status_message(agc_json_status status);
bool agc_json_to_float(agc_vm *vm, const agc_json *j, double *out);
/* A decodable type is a struct or an enum of the program: kind is AGC_TYPE_STRUCT or AGC_TYPE_ENUM and index its place. */
agc_value agc_json_decode(agc_vm *vm, agc_value root, uint32_t kind, uint32_t index);
agc_value agc_json_schema(agc_vm *vm, uint32_t kind, uint32_t index);

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
/* The same reader over the bytes of a regular file (File.chunks): each LINE is a Bytes of `size` bytes, the last one
   shorter, and a file that is not regular is refused when it opens. */
bool agc_chunks_size_ok(int64_t size);
agc_line_reader *agc_chunks_new(agc_vm *vm, agc_value path, int64_t size, int64_t timeout, uint32_t span);
agc_lines_status agc_lines_next(agc_vm *vm, agc_line_reader *r, agc_value last, agc_value *out);
void agc_lines_stop(agc_line_reader *r, agc_value outcome);
/* The lines of Lazy.write_lines (vm/lazy.c) into a file by path, created or truncated: the same rules as the reader.
   agc_writer_new opens nothing; the first agc_writer_next opens the file. READY means the writer waits for a line:
   the next call passes it as `line` (a String, or with AGC_WRITE_BYTES a Bytes chunk written as it is:
   Lazy.write_bytes; Void passes none). WAIT
   means the task parks on a file job, whose result is the `last` of the next call (with a Void line). END puts the outcome in *out and comes only after the
   file is flushed and closed. agc_writer_stop, while READY, ends the writer with that outcome: the next calls close
   the file. */
typedef struct agc_line_writer agc_line_writer;
typedef enum { AGC_WRITER_READY, AGC_WRITER_WAIT, AGC_WRITER_END } agc_writer_status;
typedef enum { AGC_WRITE_LINES, AGC_WRITE_BYTES } agc_writer_form;
agc_line_writer *agc_writer_new(agc_vm *vm, agc_value path, int64_t timeout, agc_writer_form form, uint32_t span);
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
/* The area that starts a stream's timeout errors: TCP is `network:`, a process and the child channel `process:`. */
typedef enum { AGC_STREAM_NETWORK, AGC_STREAM_PROCESS } agc_stream_area;
agc_value agc_stream_bad_timeout(agc_stream_area area);
agc_value agc_stream_timed_out(agc_stream_area area);
/* The result of a finished write: Ok(Void), or the write error for a negative libuv status. */
agc_value agc_stream_written(agc_vm *vm, int status);
agc_resource *agc_new_lock(agc_vm *vm);
bool agc_stream_lock(agc_vm *vm, agc_resource *lock, agc_stream_area area, int64_t *timeout, agc_value *result);
size_t agc_inbuf_pending(const agc_inbuf *b);
void agc_inbuf_free(agc_inbuf *b);
bool agc_inbuf_ready(agc_inbuf *b, bool line, size_t count);
size_t agc_inbuf_want(const agc_inbuf *b, bool line, size_t count);
uint8_t *agc_inbuf_room(agc_inbuf *b, size_t want);
void agc_inbuf_got(agc_inbuf *b, int64_t n, bool eof);
bool agc_inbuf_unread(agc_inbuf *b, const uint8_t *data, size_t len);
agc_value agc_inbuf_line(agc_vm *vm, agc_inbuf *b, const char *too_long, const char *at_end, bool *over);
/* The data and length of a Bytes argument of TCP, Process and HttpWire, which the argument keeps alive; NULL when it
   has more than limit bytes. */
const uint8_t *agc_stream_bytes(agc_vm *vm, agc_value arg, size_t limit, size_t *len);
/* A byte read's value is a Bytes. */
agc_value agc_inbuf_bytes(agc_vm *vm, agc_inbuf *b, size_t count);
void agc_inbuf_take(agc_inbuf *b, size_t n);
/* For a protocol whose every record ends in LF (the child channel): at the end of input, drops a final line that has no
   LF (at most the line limit; a longer one is `over`, a read error is reported as such) and says so. */
bool agc_inbuf_drop_unterminated(agc_inbuf *b);
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
extern const agc_builtin agc_bytes_builtins[];
extern const size_t agc_bytes_builtin_count;
extern const agc_builtin agc_text_codec_builtins[];
extern const size_t agc_text_codec_builtin_count;
extern const agc_builtin agc_number_builtins[];
extern const size_t agc_number_builtin_count;
extern const agc_builtin agc_crypto_builtins[];
extern const size_t agc_crypto_builtin_count;
extern const agc_builtin agc_json_builtins[];
extern const size_t agc_json_builtin_count;
extern const agc_builtin agc_file_builtins[];
extern const size_t agc_file_builtin_count;
/* The zlib stream of a Lazy step (vm/lazy.c drives it, vm/zlib.c owns it). kind is the step of __lazy_zlib: 0
   deflate, 1 raw deflate, 2 gzip, 3 inflate, 4 raw inflate, 5 gunzip. agc_zstep_check gives Void or the error of a bad
   level or max_bytes. agc_zstep_open starts the codec as a registered entry the calling task owns, so the task's end
   frees it when the run did not; agc_zstep_close frees it (idempotent). agc_zstep_next runs one pass over `in` with
   `finish` once no item will come, sets *used, and puts a chunk of at most 64 KiB in *out when it produced bytes
   (Void when not): a Bytes. INPUT: the stream wants the next item. AGAIN: call again with what is left of `in` (maybe
   none).
   END: the stream ended; a later call with bytes is a trailing byte. FAILED: *out is the error Result. */
typedef enum { AGC_ZSTEP_INPUT, AGC_ZSTEP_AGAIN, AGC_ZSTEP_END, AGC_ZSTEP_FAILED } agc_zstep_status;
agc_value agc_zstep_check(int64_t kind, int64_t level, int64_t max_bytes);
agc_resource *agc_zstep_open(agc_vm *vm, int64_t kind, int64_t level, int64_t max_bytes);
void agc_zstep_close(agc_vm *vm, agc_resource *r);
agc_zstep_status agc_zstep_next(agc_vm *vm, agc_resource *r, const uint8_t *in, size_t len, size_t *used, bool finish,
                                agc_value *out);
extern const agc_builtin agc_zlib_builtins[];
extern const size_t agc_zlib_builtin_count;
extern const agc_builtin agc_lazy_builtins[];
extern const size_t agc_lazy_builtin_count;
extern const agc_builtin agc_ats_builtins[];
extern const size_t agc_ats_builtin_count;
/* True when both trees of the ATS table v are valid AVL trees holding its size (vm/ats.c; for the C test). */
bool agc_ats_valid(agc_vm *vm, agc_value v);
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
extern const agc_builtin agc_tls_context_builtins[];
extern const size_t agc_tls_context_builtin_count;
extern const agc_builtin agc_http_server_builtins[];
extern const size_t agc_http_server_builtin_count;
extern const agc_builtin agc_http_wire_builtins[];
extern const size_t agc_http_wire_builtin_count;
extern const agc_builtin agc_logger_builtins[];
extern const size_t agc_logger_builtin_count;
extern const agc_builtin agc_regex_builtins[];
extern const size_t agc_regex_builtin_count;
extern const agc_builtin agc_test_builtins[];
extern const size_t agc_test_builtin_count;
extern const agc_builtin agc_ffi_builtins[];
extern const size_t agc_ffi_builtin_count;
/* Whether a run may start PROGRAM: NULL, or the code of the refusal with its message and span, when the program
   imports a native builtin (Native.call for its extern functions, or another Native.*) and this build cannot call
   native code or DENY (--deny-native) refuses it. */
const char *agc_ffi_refusal(const agc_program *program, bool deny, const char **message, uint32_t *span);
/* The end of the run (docs/vm/14-core-invariants.md §14.4), once the schedulers have joined. stop_queued, first:
   the compute calls that no pool thread took are never made. end, after the file flush: waits for the running compute
   calls that hold a resource, then frees every resource and owned buffer of native code still open, whatever task owns
   it, newest first (the reverse of opening), on a thread apart. The wait ends at rt->flush_by, or once STOP_SIGNAL()
   is nonzero; the frees then stop at the first resource that a running call still holds and never skip past it, so
   that one and all older ones are not freed. False when the deadline ran out first; the frees not made are left to the
   exit. */
void agc_ffi_stop_queued(agc_vm *vm);
bool agc_ffi_end(agc_vm *vm, int (*stop_signal)(void));
/* Frees the cache of the run (rt->ffi) and its native modules, and clears the thread's native call, for the fuzz
   driver after each input: under no_files the cache holds only struct layouts and functions of carried modules,
   which nothing uses once the run is over. */
void agc_ffi_forget(agc_vm *vm);
/* A malloc'd copy of the LEN bytes at DATA with a NUL after them (out of memory exits). */
char *agc_ffi_text_copy(const char *data, size_t len);
/* Runs RUN(ARG) with the callbacks of extern blocks that C starts on this thread refused, as a free function runs:
   they give C zero and run nothing. The call of a native module runs this way. RUN may jump out (the fuzz driver's
   allocation limit, a failed check of vm/map.c); the thread then stays refusing, outside its own native calls (a fast
   call and compute_work put back the refusing site they found), until agc_ffi_forget clears it. */
void agc_ffi_refusing_callbacks(void (*run)(void *arg), void *arg);
/* Native modules (vm/native_module.c, vm/agentica_native.h). A bound function lives in vm/ffi.c's cache of the run:
   bind makes it from the text after "module " of a Native.call signature (DIRTY for "compute module "), failing with
   RUNTIME-NATIVE-LOAD, -SIGNATURE or -DENIED, under rt->sync. arguments checks ARGS, the List of its arity of
   arguments, before C sees them (bad bytecode fails), copies them to ARGV and gives the resources among them in HELD,
   their count the result. call makes one short call; vm/ffi.c holds HELD around it and raises what it failed with
   (the outcome's CODE and MESSAGE) only after letting go, so call itself never jumps out once C ran. A dirty call
   (dirty_new, under rt->sync, then dirty_run on a pool thread, then dirty_done on a scheduler) reads ARGV in place on
   the pool thread: the caller keeps them alive until dirty_done (the job's context) and holds HELD. done builds the
   value when TAKE (a task takes it), or frees what the call staged; free frees the call after done, or without it
   when the job is dropped. free_state frees the state of a resource of a module with the free function of its ROW,
   then the memory. register adds a module that the binary carries, by its library name (the C tests and the fuzz
   driver); forget frees the modules of the run. */
typedef struct agc_native_fn agc_native_fn;
typedef struct agc_native_dirty agc_native_dirty;
typedef struct {
  agc_value value;
  const char *code;
  agc_string *message;
} agc_native_outcome;
struct an_api;
struct an_module;
typedef const struct an_module *(*agc_native_init)(const struct an_api *api);
agc_native_fn *agc_native_bind(agc_vm *vm, const char *text, size_t len, bool dirty, uint32_t span);
uint32_t agc_native_arity(const agc_native_fn *fn);
uint32_t agc_native_arguments(agc_vm *vm, const agc_native_fn *fn, const agc_list *args, agc_value *argv,
                              agc_c_resource **held, uint32_t span);
agc_native_outcome agc_native_call(agc_vm *vm, agc_native_fn *fn, const agc_value *argv, agc_c_resource *const *held,
                                   uint32_t holds);
agc_native_dirty *agc_native_dirty_new(agc_vm *vm, agc_native_fn *fn, const agc_value *argv,
                                       agc_c_resource *const *held, uint32_t holds);
void agc_native_dirty_run(agc_native_dirty *d);
agc_native_outcome agc_native_dirty_done(agc_vm *vm, agc_native_dirty *d, bool take);
void agc_native_dirty_free(agc_native_dirty *d);
void agc_native_free_state(const void *row, void *state);
/* Hands TAKE each resource state that D staged and that has no value yet, with its row, newest first (a later state
   may point into an earlier one, as built values are freed), and forgets it: D frees it no more. */
void agc_native_dirty_states(agc_native_dirty *d, void (*take)(const void *row, void *state, void *arg), void *arg);
/* A resource of a native module (vm/ffi.c) around STATE, freed by agc_native_free_state with ROW, coming from the
   resources that the call which makes it holds (HELD, HOLDS entries), and owned by the calling task. Takes rt->sync. */
agc_value agc_ffi_module_resource(agc_vm *vm, const void *row, const char *name, void *state,
                                  agc_c_resource *const *held, uint32_t holds);
void agc_native_unbind(agc_native_fn *fn);
void agc_native_register(agc_vm *vm, const char *library, agc_native_init init);
void agc_native_forget(agc_runtime *rt);
extern const agc_builtin agc_front_end_builtins[];
extern const size_t agc_front_end_builtin_count;
extern const agc_builtin agc_std_builtins[];
extern const size_t agc_std_builtin_count;

#endif

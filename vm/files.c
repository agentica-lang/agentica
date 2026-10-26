/*
 * The File, Dir and Path builtins on Unix: the argument checks, host
 * paths, and file handles with their read and write buffers, including the
 * owner-only creates, lstat, the handle lock, the removals and the no-replace
 * rename. Work runs on the libuv pool. Service layer. Design:
 * docs/vm/02-reference-behavior.md §2.8.
 */
/* glibc declares renameat2 and RENAME_NOREPLACE only for _GNU_SOURCE. */
#define _GNU_SOURCE
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "services.h"
#include "digest.h"
#include "file_io.h"
#include "zlib_codec.h"

/* The bounds of buffer_bytes (File.each_line, File.foreach), on every platform: the stub below reads them too. */
#define MIN_LINE_BUFFER ((int64_t)1024)
#define MAX_LINE_BUFFER ((int64_t)16777216)

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
#ifndef _WIN32
#include <dirent.h>
#endif
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#ifdef __linux__
#include <linux/magic.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __linux__
#include <sys/epoll.h>
#endif
#ifndef _WIN32
#include <sys/file.h>
#endif
#include <sys/stat.h>
#ifdef __linux__
#include <sys/vfs.h>
#endif
#include <unistd.h>

#define LIMIT ((size_t)1048576)
#define FORM_WIDTH 256
#define CHUNK ((size_t)65536)
#define WRITE_BUFFER ((size_t)4096)
#define NO_DEADLINE ((int64_t)-1)
/* Zlib.*_file bounds: the caller caps the output bytes (at most 1 GiB),
   while the source read never exceeds a fixed cap, so hostile headers or a
   compression bomb are cut in streaming: 256 MiB of compressed input for
   decompression, 1 GiB of raw input for compression. */
#define ZLIB_FILE_MAX_OUT ((int64_t)1073741824)
#define ZLIB_FILE_MAX_DECOMP_IN ((uint64_t)268435456)
#define ZLIB_FILE_MAX_COMP_IN ((uint64_t)1073741824)

typedef enum {
  FS_OK, FS_NOT_REGULAR, FS_TOO_BIG, FS_OPEN, FS_IS_DIR, FS_READ, FS_WRITE, FS_MISSING, FS_LINK, FS_EOF, FS_LONG_LINE,
  FS_MKDIR, FS_RESOLVE, FS_REMOVE, FS_TREE_DEEP, FS_REFUSED, FS_LOCK, FS_NOT_LOCKABLE, FS_RENAME, FS_ZLIB_FORMAT,
  FS_ZLIB_CHECK, FS_ZLIB_TRAILING, FS_ZLIB_TOO_BIG, FS_ZLIB_INPUT_BIG
} fs_status;

typedef enum {
  OP_READ_TEXT, OP_WRITE_TEXT, OP_APPEND_TEXT, OP_STAT, OP_LIST, OP_MKDIR, OP_OPEN_READ, OP_OPEN_WRITE,
  OP_OPEN_APPEND, OP_READ_BYTES, OP_READ_LINE, OP_READ_BLOCK, OP_WRITE, OP_CLOSE, OP_REAL, OP_LSTAT,
  OP_OPEN_CREATE, OP_MKDIR_PRIVATE, OP_REMOVE, OP_TRY_LOCK, OP_RENAME, OP_SHA256, OP_ZLIB_FILE
} op_kind;

typedef struct {
  int fd;
  bool readable, writable, polled, eof, locked;
  agc_poller *poller;
  uint8_t *buf;
  size_t start, end, cap, scan;
} file_state;

typedef struct {
  op_kind kind;
  const agc_runtime *rt;
  char *path, *to;
  file_state *st;
  uint8_t *in;
  size_t in_len;
  uint8_t *out;
  size_t out_len, out_cap, count, fail_at;
  fs_status status;
  int err, fd;
  bool owns_st, polled, locked, dst_failed;
  const char *file_type;
  agc_vm *vm;
  agc_poller *poller;
  agc_io_job *job;
  size_t sent;
  int64_t size, mtime, mode, user_id, group_id;
  int zlib_kind;
  int64_t zlib_level;
  uint64_t zlib_in;
} op;

typedef struct {
  agc_fs_info pipe;
  int fd;
  bool found;
} pipe_search;

typedef enum { LINES_START, LINES_OPENED, LINES_SCAN, LINES_READ, LINES_CLOSE, LINES_CLOSED } lines_phase;

struct agc_line_reader {
  lines_phase phase;
  agc_value path, handle, outcome;
  size_t limit;
  int64_t timeout;
};

typedef enum {
  WRITER_START, WRITER_OPENED, WRITER_READY, WRITER_WROTE, WRITER_CLOSE, WRITER_CLOSING, WRITER_CLOSED
} writer_phase;

struct agc_line_writer {
  writer_phase phase;
  agc_value path, handle, outcome;
  int64_t timeout;
};

/* File.each_line: the reader and whether the block is running (its result comes back as `last`). */
typedef struct {
  agc_stepper stepper;
  agc_line_reader reader;
  bool in_block;
} lines;

typedef struct {
  char *data;
  size_t len, cap;
} text;

typedef enum { LINE_FOUND, LINE_LONG, LINE_TAIL, LINE_END, LINE_MORE } line_kind;

typedef struct {
  line_kind kind;
  size_t len, consume, scanned;
} line_scan;

static const char not_regular[] = "filesystem: path does not refer to a regular file";
/* A handle of another library: File, Zlib and lock handles share the
   AGC_T_HANDLE tag, so identity is checked before any cast of native. */
static const char not_file[] = "filesystem: handle is not a file handle";
static const char timed_out[] = "filesystem: operation timed out";
static const char line_too_long[] = "filesystem: line exceeds buffer_bytes";
static const char bad_timeout[] = "filesystem: timeout must be positive milliseconds";
static const char too_deep[] = "filesystem: directory tree is deeper than 128 levels";
static const char refused_path[] = "filesystem: refusing to remove /, . or ..";
#ifdef _WIN32
static const char refused_windows_path[] = "filesystem: refusing to remove an unsafe Windows path";
#endif
static const char not_lockable[] = "filesystem: only a regular file can be locked";
static const char rename_who[] = "rename-file-or-directory";
static const char complete_who[] = "path->complete-path";
static const char complete_expected[] = "(or/c path-string? path-for-some-system?)";

static void put(text *t, const char *data, size_t len) {
  if (agc_size_add(t->len, len) > t->cap) {
    size_t cap = t->cap ? t->cap : 128;
    while (cap < t->len + len) cap = agc_size_mul(cap, 2);
    char *bigger = agc_alloc_atomic(cap);
    if (t->len) memcpy(bigger, t->data, t->len);
    t->data = bigger;
    t->cap = cap;
  }
  if (len) memcpy(t->data + t->len, data, len);
  t->len += len;
}

static void puts_text(text *t, const char *s) { put(t, s, strlen(s)); }

static agc_string *lossy(const void *data, size_t len) {
  return agc_utf8_decode((const uint8_t *)data, len, "\xEF\xBF\xBD", false);
}

static agc_value error_text(const text *t) { return agc_result_value(false, agc_string_value(lossy(t->data, t->len))); }

static agc_value error_of(const char *message) {
  text t = {0};
  puts_text(&t, message);
  return error_text(&t);
}

static const char *os_message(agc_vm *vm, int err) {
#ifdef __linux__
  locale_t messages = vm->rt->messages_locale;
  return messages ? strerror_l(err, messages) : strerror(err);
#else
  (void)vm;
  return strerror(err);
#endif
}

static void put_system_error(agc_vm *vm, text *t, int err) {
  char number[32];
  puts_text(t, "\n  system error: ");
  puts_text(t, os_message(vm, err));
  int n = snprintf(number, sizeof number, "; errno=%d", err);
  put(t, number, (size_t)n);
}

static void put_os_error(agc_vm *vm, text *t, const char *path, size_t path_len, int err) {
  puts_text(t, "\n  path: ");
  put(t, path, path_len);
  put_system_error(vm, t, err);
}

static agc_value os_error(agc_vm *vm, const char *what, const char *path, size_t path_len, int err) {
  text t = {0};
  puts_text(&t, what);
  put_os_error(vm, &t, path, path_len, err);
  return error_text(&t);
}

static void put_form(text *t, const agc_string *s) {
  size_t chars;
  size_t bytes = agc_write_form(s, NULL, &chars);
  char *form = agc_alloc_atomic(bytes ? bytes : 1);
  agc_write_form(s, form, &chars);
  if (chars <= FORM_WIDTH) {
    put(t, form, bytes);
    return;
  }
  size_t at = 0;
  for (size_t k = 0; k < FORM_WIDTH - 3; k++) at += agc_utf8_width((uint8_t)form[at]);
  put(t, form, at);
  puts_text(t, "...");
}

static agc_value contract_error(const char *who, const char *expected, const agc_string *given) {
  text t = {0};
  puts_text(&t, who);
  puts_text(&t, ": contract violation\n  expected: ");
  puts_text(&t, expected);
  puts_text(&t, "\n  given: ");
  put_form(&t, given);
  return error_text(&t);
}

static bool same_text(const char *data, size_t len, const char *word) {
  return len == strlen(word) && memcmp(data, word, len) == 0;
}

static bool path_string(const agc_string *s) {
  if (!s->bytes || memchr(s->data, 0, s->bytes)) return false;
#ifdef _WIN32
  if (s->bytes >= 4 && (s->data[0] == '/' || s->data[0] == '\\') &&
      (s->data[1] == '/' || s->data[1] == '\\') && (s->data[2] == '.' || s->data[2] == '?')) return false;
#endif
  return true;
}

#ifdef _WIN32
static bool windows_remove_input_valid(const agc_string *s) {
  size_t len = s->bytes;
  if (s->data[len - 1] == '/' || s->data[len - 1] == '\\' ||
      (len == 2 && ((s->data[0] >= 'A' && s->data[0] <= 'Z') ||
                    (s->data[0] >= 'a' && s->data[0] <= 'z')) && s->data[1] == ':')) return false;
  size_t start = len;
  while (start && s->data[start - 1] != '/' && s->data[start - 1] != '\\') start--;
  size_t last = len - start;
  if (last == 0 || (last == 1 && s->data[start] == '.') ||
      (last == 2 && s->data[start] == '.' && s->data[start + 1] == '.')) return false;
  if (len >= 2 && s->data[1] == ':' && start == 2) return false;
  bool drive_colon = len >= 3 && ((s->data[0] >= 'A' && s->data[0] <= 'Z') ||
                                  (s->data[0] >= 'a' && s->data[0] <= 'z')) && s->data[1] == ':';
  size_t component = 0;
  for (size_t k = 0; k <= len; k++) {
    if (k < len && s->data[k] == ':' && !(drive_colon && k == 1)) return false;
    if (k == len || s->data[k] == '/' || s->data[k] == '\\') {
      size_t part = k - component;
      bool dot = part == 1 && s->data[component] == '.';
      bool dotdot = part == 2 && s->data[component] == '.' && s->data[component + 1] == '.';
      if (part && !dot && !dotdot && (s->data[k - 1] == '.' || s->data[k - 1] == ' ')) return false;
      component = k + 1;
    }
  }
  return true;
}
#endif

void agc_files_init(agc_vm *vm) {
  char *buf = agc_fs_cwd();
  if (!buf) buf = strdup("/");
  if (!buf) agc_out_of_memory();
  size_t len = strlen(buf);
  text t = {0};
  put(&t, buf, len);
  if (len == 0 || buf[len - 1] != '/') puts_text(&t, "/");
  vm->rt->cwd = agc_make_string(t.data, t.len, 0);
  free(buf);
#ifdef __linux__
  if (!vm->rt->messages_locale) vm->rt->messages_locale = newlocale(LC_MESSAGES_MASK | LC_CTYPE_MASK, "", (locale_t)0);
#endif
}

void agc_files_close(agc_vm *vm) {
#ifdef __linux__
  if (vm->rt->messages_locale) freelocale(vm->rt->messages_locale);
  vm->rt->messages_locale = (locale_t)0;
#else
  (void)vm;
#endif
}

static const agc_string *cwd_of(agc_vm *vm) {
  if (!vm->rt->cwd) agc_files_init(vm);
  return vm->rt->cwd;
}

char *agc_host_path(agc_vm *vm, const agc_string *s) {
#ifdef _WIN32
  (void)vm;
  char *given = agc_cstr(s);
  char *resolved = given ? agc_fs_absolute(given) : NULL;
  if (!resolved) return given;
  free(given);
  return resolved;
#else
  const agc_string *cwd = s->data[0] == '/' ? NULL : cwd_of(vm);
  text t = {0};
  for (size_t part = 0; part < 2; part++) {
    const agc_string *from = part == 0 ? cwd : s;
    for (size_t k = 0; from && k < from->bytes; k++) {
      if (from->data[k] == '/' && t.len > 0 && t.data[t.len - 1] == '/') continue;
      put(&t, from->data + k, 1);
    }
  }
  char *path = agc_cstr(agc_make_string(t.data, t.len, 0));
  if (!path) agc_fail(vm, "RUNTIME-INTERNAL", "a path contains NUL", 0);
  return path;
#endif
}

static op *new_op(agc_vm *vm, op_kind kind) {
  op *o = calloc(1, sizeof(op));
  if (!o) agc_out_of_memory();
  o->kind = kind;
  o->fd = -1;
  o->rt = vm->rt;
  return o;
}

static file_state *new_state(bool readable, bool writable) {
  file_state *st = calloc(1, sizeof(file_state));
  if (!st) agc_out_of_memory();
  st->fd = -1;
  st->readable = readable;
  st->writable = writable;
  return st;
}

static void free_state(file_state *st) {
  if (!st) return;
  if (st->poller)
    agc_poller_close(st->poller);
  else if (st->fd >= 0)
    agc_fs_close(st->fd);
  free(st->buf);
  free(st);
}

static void free_op(op *o) {
  free(o->path);
  free(o->to);
  free(o->in);
  free(o->out);
  free(o);
}

/* What can wait forever waits on the loop; epoll refuses (EPERM) only
   what never waits (docs/vm/14-core-invariants.md, 14.1). */
static int probe(int fd, bool *polled) {
  agc_fs_info info;
  *polled = false;
  if (agc_fs_fstat(fd, &info) != 0) return errno;
  if (AGC_FS_ISREG(info.mode) || AGC_FS_ISBLK(info.mode) || AGC_FS_ISDIR(info.mode)) return 0;
#ifdef _WIN32
  return ENOTSUP;
#elif defined(__linux__)
  int ep = epoll_create1(EPOLL_CLOEXEC);
  if (ep < 0) return errno;
  struct epoll_event event = {.events = EPOLLIN};
  int err = epoll_ctl(ep, EPOLL_CTL_ADD, fd, &event) == 0 ? 0 : errno;
  agc_fs_close(ep);
  *polled = err == 0;
  return err == EPERM ? 0 : err;
#else
  if (AGC_FS_ISCHR(info.mode)) {
    agc_fs_info device;
    const char *devices[] = {"/dev/null", "/dev/zero", "/dev/urandom"};
    for (size_t k = 0; k < sizeof devices / sizeof devices[0]; k++)
      if (agc_fs_stat(devices[k], &device, true) == 0 && info.rdev == device.rdev) return 0;
  }
  *polled = true;
  return 0;
#endif
}

static void blocking(int fd) {
#ifdef _WIN32
  (void)fd;
#else
  int flags = fcntl(fd, F_GETFL);
  if (flags >= 0) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
#endif
}

static bool read_all(int fd, uint8_t *buf, size_t want, size_t *got, int *err) {
  size_t done = 0;
  while (done < want) {
    int64_t n = agc_fs_read(fd, buf + done, want - done);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) {
      *err = errno;
      *got = done;
      return false;
    }
    if (n == 0) break;
    done += (size_t)n;
  }
  *got = done;
  return true;
}

static bool write_all(int fd, const uint8_t *data, size_t len, int *err) {
  size_t done = 0;
  while (done < len) {
    int64_t n = agc_fs_write(fd, data + done, len - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) {
      *err = n < 0 ? errno : EIO;
      return false;
    }
    done += (size_t)n;
  }
  return true;
}

/* The release of a handle that was not closed: one blocking write of what it buffers (at most WRITE_BUFFER, or CHUNK
   for a line writer's handle; §14.1, release flush), then the descriptor is closed. */
static void release_state(void *native) {
  file_state *st = native;
  int err;
  if (st->writable && st->end) write_all(st->fd, st->buf, st->end, &err);
  free_state(st);
}

static void fail_op(op *o, fs_status status, int err) {
  o->status = status;
  o->err = err;
}

static bool write_target(const char *path) {
  agc_fs_info info;
  if (agc_fs_stat(path, &info, true) == 0) return !AGC_FS_ISDIR(info.mode);
  return errno != ELOOP;
}

#ifndef _WIN32
bool agc_each_fd(bool (*visit)(int fd, void *data), void *data) {
#ifdef __linux__
  DIR *dir = opendir("/proc/self/fd");
#else
  DIR *dir = opendir("/dev/fd");
#endif
  if (!dir) return false;
  int own = dirfd(dir);
  for (struct dirent *e = readdir(dir); e; e = readdir(dir)) {
    char *end = NULL;
    long fd = strtol(e->d_name, &end, 10);
    if (end == e->d_name || *end || fd < 0 || fd == own || fd > INT32_MAX) continue;
    if (visit((int)fd, data)) break;
  }
  closedir(dir);
  return true;
}

static bool same_file(int fd, const agc_fs_info *file) {
  agc_fs_info info;
  return agc_fs_fstat(fd, &info) == 0 && info.dev == file->dev && info.ino == file->ino;
}

static bool pipe_info(int fd, agc_fs_info *info) {
#ifdef __linux__
  struct statfs fs;
  return agc_fs_fstat(fd, info) == 0 && AGC_FS_ISFIFO(info->mode) && fstatfs(fd, &fs) == 0 && fs.f_type == PIPEFS_MAGIC;
#elif defined(__APPLE__)
  char path[PATH_MAX];
  return agc_fs_fstat(fd, info) == 0 && AGC_FS_ISFIFO(info->mode) && fcntl(fd, F_GETPATH, path) != 0;
#else
  return agc_fs_fstat(fd, info) == 0 && AGC_FS_ISFIFO(info->mode);
#endif
}

static bool same_pipe(int fd, void *data) {
  pipe_search *s = data;
  s->found = fd > 2 && fd != s->fd && same_file(fd, &s->pipe);
  return s->found;
}

static bool note_pipe(int fd, void *data) {
  agc_file_ids *ids = data;
  agc_fs_info info;
  if (!pipe_info(fd, &info)) return false;
  if (ids->count == ids->cap) {
    size_t cap = ids->cap ? agc_size_mul(ids->cap, 2) : 8;
    agc_file_id *grown = agc_alloc_atomic(agc_size_mul(cap, sizeof *grown));
    if (ids->count) memcpy(grown, ids->ids, ids->count * sizeof *grown);
    ids->ids = grown;
    ids->cap = cap;
  }
  ids->ids[ids->count++] = (agc_file_id){(uint64_t)info.dev, (uint64_t)info.ino};
  return false;
}

agc_file_ids agc_files_inherited(void) {
  agc_file_ids ids = {0};
  agc_each_fd(note_pipe, &ids);
  return ids;
}

void agc_files_forget(agc_file_ids *ids, int fd) {
  agc_fs_info info;
  if (!pipe_info(fd, &info)) return;
  for (size_t k = ids->count; k-- > 0;)
    if (ids->ids[k].dev == (uint64_t)info.dev && ids->ids[k].ino == (uint64_t)info.ino)
      ids->ids[k] = ids->ids[--ids->count];
}

static bool inherited(const agc_file_ids *ids, const agc_fs_info *info) {
  for (size_t k = 0; k < ids->count; k++)
    if (ids->ids[k].dev == (uint64_t)info->dev && ids->ids[k].ino == (uint64_t)info->ino) return true;
  return false;
}

/* A path like /proc/self/fd/N can reopen a pipe the VM itself made (libuv's
   signal pipes, a child's stdio); using it would corrupt the runtime. Pipes
   the VM got at start stay reachable. */
static bool private_pipe(const agc_runtime *rt, int fd) {
  pipe_search s = {.fd = fd};
  if (!pipe_info(fd, &s.pipe) || inherited(&rt->inherited, &s.pipe)) return false;
  return !agc_each_fd(same_pipe, &s) || s.found;
}

#else
agc_file_ids agc_files_inherited(void) { return (agc_file_ids){0}; }

void agc_files_forget(agc_file_ids *ids, int fd) {
  (void)ids;
  (void)fd;
}

static bool private_pipe(const agc_runtime *rt, int fd) {
  (void)rt;
  (void)fd;
  return false;
}
#endif

static int checked(op *o, int fd) {
  if (fd < 0 || !private_pipe(o->rt, fd)) return fd;
  agc_fs_close(fd);
  fail_op(o, FS_NOT_REGULAR, 0);
  return -1;
}

#ifndef _WIN32
static bool same_directory(const agc_fs_info *info, const char *path) {
  agc_fs_info other;
  return agc_fs_stat(path, &other, true) == 0 && other.dev == info->dev && other.ino == info->ino;
}

static bool names_output_fd(const op *o) {
  const char *slash = strrchr(o->path, '/');
  const char *name = slash ? slash + 1 : o->path;
  char *end = NULL;
  long fd = strtol(name, &end, 10);
  if (end == name || *end || fd <= 2 || (fd != o->rt->out.fd && fd != o->rt->err.fd)) return false;
  char copy[PATH_MAX];
  size_t len = slash ? (size_t)(slash - o->path) : 0;
  if (len >= sizeof copy) return false;
  memcpy(copy, o->path, len);
  copy[len] = '\0';
  agc_fs_info info;
  if (agc_fs_stat(slash ? (len ? copy : "/") : ".", &info, true) != 0) return false;
#ifdef __linux__
  return same_directory(&info, "/proc/self/fd") || same_directory(&info, "/proc/thread-self/fd");
#else
  return same_directory(&info, "/dev/fd");
#endif
}

#else
static bool names_output_fd(const op *o) { (void)o; return false; }
#endif

static int open_for(op *o, bool reading, bool append) {
  if (o->kind == OP_OPEN_CREATE) {
    /* O_EXCL fails on any existing entry, a dangling link included, and never follows one. */
    int fd = agc_fs_open(o->path, AGC_FS_WRITE | AGC_FS_CREATE | AGC_FS_EXCLUSIVE | AGC_FS_PRIVATE);
    if (fd < 0) fail_op(o, FS_OPEN, errno);
    return fd;
  }
  if (names_output_fd(o)) {
    fail_op(o, FS_NOT_REGULAR, 0);
    return -1;
  }
  if (reading) {
    agc_fs_info info;
    if (agc_fs_stat(o->path, &info, true) != 0 || AGC_FS_ISDIR(info.mode)) {
      fail_op(o, FS_NOT_REGULAR, 0);
      return -1;
    }
    if (o->kind == OP_READ_TEXT) {
      if ((uint64_t)info.size > LIMIT) {
        fail_op(o, FS_TOO_BIG, 0);
        return -1;
      }
      o->count = (size_t)info.size + 1;
    }
    int fd = agc_fs_open(o->path, AGC_FS_READ);
    if (fd < 0) fail_op(o, FS_OPEN, errno);
    return checked(o, fd);
  }
  if (!write_target(o->path)) {
    fail_op(o, FS_NOT_REGULAR, 0);
    return -1;
  }
  size_t len = strlen(o->path);
  if (len && o->path[len - 1] == '/') {
    fail_op(o, FS_IS_DIR, 0);
    return -1;
  }
  int fd = agc_fs_open(o->path, AGC_FS_WRITE | AGC_FS_CREATE | (append ? AGC_FS_APPEND : AGC_FS_TRUNCATE));
  if (fd < 0) fail_op(o, errno == EISDIR ? FS_IS_DIR : FS_OPEN, errno);
  return checked(o, fd);
}

static bool on_loop(op *o, int fd) {
  bool polled;
  int err = probe(fd, &polled);
  if (err) {
    agc_fs_close(fd);
    fail_op(o, FS_OPEN, err);
    return true;
  }
  if (!polled) return false;
  o->fd = fd;
  o->polled = true;
  return true;
}

static bool grow_out(op *o, size_t extra) {
  if (o->out_len + extra <= o->out_cap) return true;
  size_t cap = o->out_cap ? o->out_cap : 1024;
  while (cap < o->out_len + extra) cap *= 2;
  uint8_t *bigger = realloc(o->out, cap);
  if (!bigger) return false;
  o->out = bigger;
  o->out_cap = cap;
  return true;
}

static void step_read_text(op *o) {
  for (;;) {
    if (o->out_len == o->out_cap && !grow_out(o, CHUNK)) {
      fail_op(o, FS_READ, ENOMEM);
      return;
    }
    int64_t n = agc_fs_read(o->fd, o->out + o->out_len, o->out_cap - o->out_len);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) {
      fail_op(o, FS_READ, errno);
      return;
    }
    o->out_len += (size_t)n;
    if (n == 0 || o->out_len > LIMIT) return;
  }
}

static void work_read_text(op *o) {
  int fd = open_for(o, true, false);
  if (fd < 0 || on_loop(o, fd)) return;
  blocking(fd);
  agc_fs_info info;
  if (o->count == 1 && agc_fs_fstat(fd, &info) == 0 && AGC_FS_ISREG(info.mode)) {
    o->fd = fd;
    step_read_text(o);
    o->fd = -1;
    agc_fs_close(fd);
    return;
  }
  o->out = malloc(o->count);
  if (!o->out) {
    fail_op(o, FS_READ, ENOMEM);
  } else if (!read_all(fd, o->out, o->count, &o->out_len, &o->err)) {
    o->status = FS_READ;
  }
  agc_fs_close(fd);
}

static void work_write_text(op *o) {
  int fd = open_for(o, false, o->kind == OP_APPEND_TEXT);
  if (fd < 0 || on_loop(o, fd)) return;
  blocking(fd);
  if (!write_all(fd, o->in, o->in_len, &o->err)) o->status = FS_WRITE;
  agc_fs_close(fd);
}

/* The hash of a whole regular file, streamed in fixed chunks with O(chunk) memory: one private descriptor, read from
   the start and closed on every return path. The fstat of the descriptor itself decides what is regular, so a rename
   or a replacement between the path stat and the open cannot turn this into a read of a pipe or a device; the open
   is non-blocking, a non-regular descriptor is refused before any blocking read, and the job never waits on the loop.
   Only malloc'd memory is touched here, no GC pointer, and nothing raises. */
static void work_sha256(op *o) {
  int fd = open_for(o, true, false);
  if (fd < 0) return;
  agc_fs_info info;
  if (agc_fs_fstat(fd, &info) != 0) {
    int err = errno;
    agc_fs_close(fd);
    fail_op(o, FS_READ, err);
    return;
  }
  if (!AGC_FS_ISREG(info.mode)) {
    agc_fs_close(fd);
    fail_op(o, FS_NOT_REGULAR, 0);
    return;
  }
  blocking(fd);
  /* The digest of the bytes in read order; a concurrent writer changes what is hashed, as with File.read_text. */
  unsigned char digest[AGC_SHA256_BYTES];
  agc_sha256_stream *hash = agc_sha256_begin();
  uint8_t *buf = malloc(CHUNK);
  if (!hash || !buf) {
    agc_sha256_free(hash);
    free(buf);
    agc_fs_close(fd);
    fail_op(o, FS_READ, ENOMEM);
    return;
  }
  bool ok = true;
  int err = 0;
  for (;;) {
    int64_t n = agc_fs_read(fd, buf, CHUNK);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) {
      err = errno;
      ok = false;
      break;
    }
    if (n == 0) break;
    if (!agc_sha256_update(hash, buf, (size_t)n)) {
      err = EIO;
      ok = false;
      break;
    }
  }
  if (ok && !agc_sha256_final(hash, digest)) {
    err = EIO;
    ok = false;
  }
  agc_sha256_free(hash);
  free(buf);
  agc_fs_close(fd);
  if (!ok) {
    fail_op(o, FS_READ, err);
    return;
  }
  o->out = malloc(AGC_SHA256_BYTES);
  if (!o->out) {
    fail_op(o, FS_READ, ENOMEM);
    return;
  }
  memcpy(o->out, digest, AGC_SHA256_BYTES);
  o->out_len = AGC_SHA256_BYTES;
  o->out_cap = AGC_SHA256_BYTES;
}

/* Zlib.*_file: one stream file-to-file in fixed 64 KiB chunks with O(chunk)
   memory, through the shared codec kernel of zlib_codec.h, so compression and
   decompression share it with the byte and streaming calls and no second
   decoder exists: DEFLATE/INFLATE wrap in zlib, GZIP/GUNZIP in gzip. The
   source opens like File.sha256 (non-blocking, and the fstat of the
   descriptor itself decides regular, so a FIFO swap cannot turn this into a
   wait); the destination opens like OP_OPEN_CREATE (O_EXCL, never following
   a link, an existing path stays intact). Output is checked against max_out
   before every write, so a partial file never grows past it and is conserved
   on error (never removed: removal would race with a replacement). Only
   malloc'd memory is touched here, no GC pointer, and nothing raises. A job
   already running runs to its end on timeout or cancel and its result is
   dropped, as with the other whole-file calls: there is no handle to close. */
static void work_zlib_file(op *o) {
  bool compress = o->zlib_kind == AGC_ZLIB_DEFLATE_FILE || o->zlib_kind == AGC_ZLIB_GZIP_FILE;
  bool gzip = o->zlib_kind == AGC_ZLIB_GZIP_FILE || o->zlib_kind == AGC_ZLIB_GUNZIP_FILE;
  uint64_t max_out = (uint64_t)o->count;
  uint64_t max_in = compress ? ZLIB_FILE_MAX_COMP_IN : ZLIB_FILE_MAX_DECOMP_IN;
  int sfd = open_for(o, true, false);
  if (sfd < 0) return;
  agc_fs_info info;
  if (agc_fs_fstat(sfd, &info) != 0) {
    int err = errno;
    agc_fs_close(sfd);
    fail_op(o, FS_READ, err);
    return;
  }
  if (!AGC_FS_ISREG(info.mode)) {
    agc_fs_close(sfd);
    fail_op(o, FS_NOT_REGULAR, 0);
    return;
  }
  blocking(sfd);
  /* O_EXCL on any existing entry, a dangling link included, and never follows one. */
  int dfd = agc_fs_open(o->to, AGC_FS_WRITE | AGC_FS_CREATE | AGC_FS_EXCLUSIVE | AGC_FS_PRIVATE);
  if (dfd < 0) {
    int err = errno;
    agc_fs_close(sfd);
    o->dst_failed = true;
    fail_op(o, FS_OPEN, err);
    return;
  }
  uint8_t *in = malloc(CHUNK);
  uint8_t *out = malloc(CHUNK);
  agc_zcodec *codec = compress ? agc_zcodec_encode_begin(gzip ? 31 : 15, (int)o->zlib_level)
                               : agc_zcodec_decode_begin(gzip ? 31 : 15);
  if (!in || !out || !codec) {
    agc_zcodec_free(codec);
    free(in);
    free(out);
    agc_fs_close(sfd);
    agc_fs_close(dfd);
    fail_op(o, FS_READ, ENOMEM);
    return;
  }
  uint64_t total_out = 0;
  const uint8_t *next = NULL;
  size_t left = 0;
  bool src_eof = false, finished = false;
  for (;;) {
    if (left == 0 && !src_eof) {
      int64_t n = agc_fs_read(sfd, in, CHUNK);
      if (n < 0 && errno == EINTR) continue;
      if (n < 0) {
        fail_op(o, FS_READ, errno);
        break;
      }
      if (n == 0) {
        src_eof = true;
      } else {
        if (o->zlib_in + (uint64_t)n > max_in) {
          fail_op(o, FS_ZLIB_INPUT_BIG, 0);
          break;
        }
        o->zlib_in += (uint64_t)n;
        next = in;
        left = (size_t)n;
      }
    }
    size_t produced = 0;
    agc_zcodec_status fed;
    if (left > 0 || !src_eof) {
      fed = compress ? agc_zcodec_encode(codec, &next, &left, false, out, CHUNK, &produced)
                     : agc_zcodec_decode(codec, &next, &left, out, CHUNK, &produced);
    } else {
      /* Past end of source the encoder drains with FINISH and the decoder
         proves the truncation: neither takes new input here. */
      const uint8_t *empty = NULL;
      size_t empty_left = 0;
      fed = compress ? agc_zcodec_encode(codec, &empty, &empty_left, true, out, CHUNK, &produced)
                     : agc_zcodec_decode(codec, &empty, &empty_left, out, CHUNK, &produced);
    }
    if (fed == AGC_ZCODEC_NOMEM) {
      fail_op(o, FS_READ, ENOMEM);
      break;
    }
    if (fed == AGC_ZCODEC_CHECK) {
      fail_op(o, FS_ZLIB_CHECK, 0);
      break;
    }
    if (fed == AGC_ZCODEC_FORMAT) {
      fail_op(o, FS_ZLIB_FORMAT, 0);
      break;
    }
    if (produced > 0) {
      if (total_out + (uint64_t)produced > max_out) {
        fail_op(o, FS_ZLIB_TOO_BIG, 0);
        break;
      }
      int err = 0;
      if (!write_all(dfd, out, produced, &err)) {
        fail_op(o, FS_WRITE, err);
        break;
      }
      total_out += (uint64_t)produced;
    }
    if (fed == AGC_ZCODEC_DONE) {
      finished = true;
      break;
    }
    if (fed == AGC_ZCODEC_MORE && left == 0 && src_eof && produced == 0) {
      fail_op(o, FS_ZLIB_FORMAT, 0);
      break;
    }
  }
  if (finished && o->status == FS_OK && !compress) {
    if (left != 0) {
      fail_op(o, FS_ZLIB_TRAILING, 0);
    } else {
      /* A stream that ends exactly at end of file has no byte beyond it: one
         more byte decides trailing data from a clean end. Every trailing byte
         is refused, zeros and concatenated members alike. */
      uint8_t extra = 0;
      for (;;) {
        int64_t n = agc_fs_read(sfd, &extra, 1);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) {
          fail_op(o, FS_READ, errno);
        } else if (n > 0) {
          fail_op(o, FS_ZLIB_TRAILING, 0);
        }
        break;
      }
    }
  }
  agc_zcodec_free(codec);
  free(in);
  free(out);
  agc_fs_close(sfd);
  agc_fs_close(dfd);
  if (o->status != FS_OK) return;
  o->size = (int64_t)total_out;
}

static void work_stat(op *o) {
  agc_fs_info info;
  if ((o->kind == OP_LSTAT ? agc_fs_stat(o->path, &info, false) : agc_fs_stat(o->path, &info, true)) != 0) {
    fail_op(o, errno == ELOOP ? FS_LINK : FS_MISSING, 0);
    return;
  }
  bool dir = AGC_FS_ISDIR(info.mode);
  o->file_type = dir ? "directory" : AGC_FS_ISLNK(info.mode) ? "link" : "file";
  o->size = dir ? 0 : (int64_t)info.size;
  o->mtime = info.mtime;
  o->mode = (int64_t)(info.mode & 07777);
  o->user_id = (int64_t)info.uid;
  o->group_id = (int64_t)info.gid;
}

static void work_list(op *o) {
  char *names;
  if (agc_fs_list(o->path, &names, &o->out_len, &o->count) != 0) fail_op(o, FS_OPEN, errno);
  o->out = (uint8_t *)names;
  o->out_cap = o->out_len;
}

static size_t parent_len(const char *path, size_t len) {
  if (len <= 1) return 0;
  size_t m = len;
  while (m > 1 && path[m - 1] == '/') m--;
  while (m > 0 && path[m - 1] != '/') m--;
  return m;
}

static bool is_dir_prefix(char *path, size_t len) {
  char saved = path[len];
  path[len] = '\0';
  agc_fs_info info;
  bool dir = agc_fs_stat(path, &info, true) == 0 && AGC_FS_ISDIR(info.mode);
  path[len] = saved;
  return dir;
}

static void work_mkdir(op *o) {
  size_t len = strlen(o->path), levels = 1;
  for (size_t k = 0; k < len; k++) levels += o->path[k] == '/';
  size_t *chain = malloc(levels * sizeof(size_t));
  if (!chain) {
    fail_op(o, FS_MKDIR, ENOMEM);
    o->fail_at = len;
    return;
  }
  size_t n = 0;
  for (size_t at = len; at && n < levels; at = parent_len(o->path, at)) chain[n++] = at;
  size_t top = 0;
  while (top + 1 < n && !is_dir_prefix(o->path, chain[top + 1])) top++;
  for (size_t k = top + 1; k-- > 0;) {
    if (is_dir_prefix(o->path, chain[k])) continue;
    char saved = o->path[chain[k]];
    o->path[chain[k]] = '\0';
    int failed = agc_fs_mkdir(o->path, false);
    int err = errno;
    o->path[chain[k]] = saved;
    if (failed != 0 && err != EEXIST) {
      fail_op(o, FS_MKDIR, err);
      o->fail_at = chain[k];
      break;
    }
  }
  free(chain);
}

static void work_real(op *o) {
  char *resolved = agc_fs_realpath(o->path);
  if (!resolved) {
    fail_op(o, FS_RESOLVE, errno);
    return;
  }
  o->out = (uint8_t *)resolved;
  o->out_len = strlen(resolved);
}

/* Exactly one directory, owner only: an existing path is the caller's error, never a success. */
static void work_mkdir_private(op *o) {
  if (agc_fs_mkdir(o->path, true) == 0) return;
  fail_op(o, FS_MKDIR, errno);
  o->fail_at = strlen(o->path);
}

/* Whatever is at the path goes, as rm -rf would remove it but never following a link: unlink takes a file or a link
   itself, and only a directory (EISDIR) starts the tree walk, which opens it with O_NOFOLLOW. A missing path is
   success, as with unlink(missing_ok=True). "file/child" is ENOTDIR and stays an error: a link with a trailing
   slash ("link/") gives the same error and must never report ok. When the walk fails inside the tree, the error
   names the entry that failed, not the root. */
static void work_remove(op *o) {
#ifdef _WIN32
  char *failed = NULL;
  int rc = agc_fs_remove_tree(o->path, &failed);
  if (rc == 0) return;
  if (rc == AGC_FS_REMOVE_TOO_DEEP) {
    free(failed);
    fail_op(o, FS_TREE_DEEP, 0);
  } else if (rc == AGC_FS_REMOVE_REFUSED) {
    fail_op(o, FS_REFUSED, 0);
  } else {
    fail_op(o, FS_REMOVE, rc);
    if (failed) {
      free(o->path);
      o->path = failed;
    }
  }
#else
  int rc;
  do {
    rc = unlink(o->path);
  } while (rc != 0 && errno == EINTR);
  if (rc == 0 || errno == ENOENT) return;
  int err = errno;
  bool directory = err == EISDIR;
#ifdef __APPLE__
  agc_fs_info info;
  if (err == EPERM) directory = agc_fs_stat(o->path, &info, false) == 0 && AGC_FS_ISDIR(info.mode);
#endif
  if (!directory) {
    fail_op(o, FS_REMOVE, err);
    return;
  }
  char *failed;
  rc = agc_remove_tree(o->path, &failed);
  if (rc == 0 || rc == ENOENT) return;
  if (rc == AGC_TREE_TOO_DEEP) {
    fail_op(o, FS_TREE_DEEP, 0);
  } else if (rc == AGC_TREE_REFUSED) {
    fail_op(o, FS_REFUSED, 0);
  } else {
    fail_op(o, FS_REMOVE, rc);
    if (failed) {
      free(o->path);
      o->path = failed;
    }
  }
#endif
}

/* Closing the descriptor releases the lock, and children do not inherit it. Unix flock is advisory;
   Windows LockFileEx locks the whole byte range against other handles' I/O too. Remember success so a
   repeated call on this handle stays idempotent (LockFileEx would try to lock the range again). */
static void work_try_lock(op *o) {
  agc_fs_info info;
  if (agc_fs_fstat(o->st->fd, &info) != 0) {
    fail_op(o, FS_LOCK, errno);
    return;
  }
  if (!AGC_FS_ISREG(info.mode)) {
    fail_op(o, FS_NOT_LOCKABLE, 0);
    return;
  }
  if (o->st->locked) {
    o->locked = true;
    return;
  }
#ifdef _WIN32
  if (agc_fs_try_lock(o->st->fd) == 0)
    o->locked = true;
  else if (errno != EAGAIN)
    fail_op(o, FS_LOCK, errno);
#else
  if (flock(o->st->fd, LOCK_EX | LOCK_NB) == 0)
    o->locked = true;
  else if (errno != EWOULDBLOCK)
    fail_op(o, FS_LOCK, errno);
#endif
  if (o->locked) o->st->locked = true;
}

/* One renameat2 with RENAME_NOREPLACE: an existing target is EEXIST and is never overwritten (plain rename
   replaces a file and an empty directory), and a final link is moved as a link, as rename never follows one. A file
   system without RENAME_NOREPLACE answers EINVAL, which is reported, not worked around with a racy check. */
static void work_rename(op *o) {
#ifdef _WIN32
  if (agc_fs_rename_noreplace(o->path, o->to) != 0) fail_op(o, FS_RENAME, errno);
#elif defined(__APPLE__)
  agc_fs_info info;
  if (agc_fs_stat(o->to, &info, false) == 0) {
    fail_op(o, FS_RENAME, EEXIST);
    return;
  }
  if (renameatx_np(AT_FDCWD, o->path, AT_FDCWD, o->to, RENAME_EXCL) != 0) fail_op(o, FS_RENAME, errno);
#else
  if (renameat2(AT_FDCWD, o->path, AT_FDCWD, o->to, RENAME_NOREPLACE) != 0) fail_op(o, FS_RENAME, errno);
#endif
}

static void work_open(op *o) {
  int fd = open_for(o, o->kind == OP_OPEN_READ, o->kind == OP_OPEN_APPEND);
  if (fd < 0) return;
  int err = probe(fd, &o->st->polled);
  if (err) {
    agc_fs_close(fd);
    fail_op(o, FS_OPEN, err);
    return;
  }
  if (!o->st->polled) blocking(fd);
  o->st->fd = fd;
}

static size_t pending(const file_state *st) { return st->end - st->start; }

static void work_read_bytes(op *o) {
  file_state *st = o->st;
  o->out = malloc(o->count);
  if (!o->out) {
    fail_op(o, FS_READ, ENOMEM);
    return;
  }
  size_t have = pending(st) < o->count ? pending(st) : o->count;
  if (have) memcpy(o->out, st->buf + st->start, have);
  st->start += have;
  size_t got = 0;
  if (!read_all(st->fd, o->out + have, o->count - have, &got, &o->err)) o->status = FS_READ;
  o->out_len = have + got;
}

static void compact(file_state *st) {
  if (!st->start) return;
  memmove(st->buf, st->buf + st->start, pending(st));
  st->end -= st->start;
  st->start = 0;
}

static bool read_more(file_state *st, size_t most, int *err, bool *eof) {
  size_t room = st->cap - st->end < most ? st->cap - st->end : most;
  for (;;) {
    int64_t n = agc_fs_read(st->fd, st->buf + st->end, room);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) {
      *err = errno;
      return false;
    }
    *eof = n == 0;
    st->end += (size_t)n;
    return true;
  }
}

static bool fill(file_state *st, int *err, bool *eof) {
  compact(st);
  if (st->end == st->cap) {
    size_t cap = st->cap ? st->cap * 2 : CHUNK;
    uint8_t *bigger = realloc(st->buf, cap);
    if (!bigger) {
      *err = ENOMEM;
      return false;
    }
    st->buf = bigger;
    st->cap = cap;
  }
  return read_more(st, SIZE_MAX, err, eof);
}

static bool take_line(op *o, size_t len, size_t consume) {
  file_state *st = o->st;
  o->out = malloc(len ? len : 1);
  if (!o->out) {
    fail_op(o, FS_READ, ENOMEM);
    return false;
  }
  if (len) memcpy(o->out, st->buf + st->start, len);
  o->out_len = len;
  st->start += consume;
  return true;
}

static line_scan scan_line(const file_state *st, size_t from, size_t window, size_t tail, bool eof) {
  size_t have = pending(st);
  const uint8_t *base = st->buf ? st->buf + st->start : NULL;
  if (window > have) window = have;
  const uint8_t *lf = window > from ? memchr(base + from, '\n', window - from) : NULL;
  if (lf) {
    size_t len = (size_t)(lf - base);
    return (line_scan){LINE_FOUND, len && base[len - 1] == '\r' ? len - 1 : len, len + 1, window};
  }
  if (have > tail) return (line_scan){LINE_LONG, 0, 0, window};
  if (!eof) return (line_scan){LINE_MORE, 0, 0, window};
  if (have == 0) return (line_scan){LINE_END, 0, 0, window};
  return (line_scan){LINE_TAIL, have, have, window};
}

static void work_read_line(op *o) {
  file_state *st = o->st;
  bool eof = false;
  for (;;) {
    line_scan found = scan_line(st, 0, LIMIT + 1, LIMIT, eof);
    switch (found.kind) {
      case LINE_FOUND:
      case LINE_TAIL: take_line(o, found.len, found.consume); return;
      case LINE_LONG:
        st->start += LIMIT + 1;
        fail_op(o, FS_LONG_LINE, 0);
        return;
      case LINE_END: fail_op(o, FS_EOF, 0); return;
      case LINE_MORE:
        if (!fill(st, &o->err, &eof)) {
          o->status = FS_READ;
          return;
        }
        break;
    }
  }
}

static void work_read_block(op *o) {
  file_state *st = o->st;
  if (!st->buf) {
    st->buf = malloc(o->count + 1);
    if (!st->buf) {
      fail_op(o, FS_READ, ENOMEM);
      return;
    }
    st->cap = o->count + 1;
  }
  compact(st);
  if (!read_more(st, o->count, &o->err, &st->eof)) o->status = FS_READ;
}

static void work_write(op *o) {
  if (!write_all(o->st->fd, o->in, o->in_len, &o->err)) o->status = FS_WRITE;
}

static void work_close(op *o) {
  file_state *st = o->st;
  if (st->writable && st->end && !write_all(st->fd, st->buf, st->end, &o->err)) o->status = FS_WRITE;
  st->end = 0;
  agc_fs_close(st->fd);
  st->fd = -1;
}

static void work(void *data) {
  op *o = data;
  switch (o->kind) {
    case OP_READ_TEXT: work_read_text(o); break;
    case OP_WRITE_TEXT:
    case OP_APPEND_TEXT: work_write_text(o); break;
    case OP_STAT:
    case OP_LSTAT: work_stat(o); break;
    case OP_REAL: work_real(o); break;
    case OP_LIST: work_list(o); break;
    case OP_MKDIR: work_mkdir(o); break;
    case OP_MKDIR_PRIVATE: work_mkdir_private(o); break;
    case OP_REMOVE: work_remove(o); break;
    case OP_TRY_LOCK: work_try_lock(o); break;
    case OP_RENAME: work_rename(o); break;
    case OP_OPEN_READ:
    case OP_OPEN_WRITE:
    case OP_OPEN_CREATE:
    case OP_OPEN_APPEND: work_open(o); break;
    case OP_READ_BYTES: work_read_bytes(o); break;
    case OP_READ_LINE: work_read_line(o); break;
    case OP_READ_BLOCK: work_read_block(o); break;
    case OP_WRITE: work_write(o); break;
    case OP_CLOSE: work_close(o); break;
    case OP_SHA256: work_sha256(o); break;
    case OP_ZLIB_FILE: work_zlib_file(o); break;
  }
}

static void drop(void *data) {
  op *o = data;
  /* On the I/O thread, release_state's flush of a regular file is one blocking write of at most WRITE_BUFFER bytes, or
     CHUNK for the handle of a line writer (docs/vm/14-core-invariants.md §14.1, release flush); only a polled
     descriptor is non-blocking (work_open), so its flush never waits. */
  if (o->owns_st && o->st) release_state(o->st);
  if (o->poller)
    agc_poller_close(o->poller);
  else if (o->fd >= 0)
    agc_fs_close(o->fd);
  free_op(o);
}

static bool writes(const op *o) {
  return o->kind != OP_READ_TEXT && o->kind != OP_READ_LINE && o->kind != OP_READ_BYTES && o->kind != OP_READ_BLOCK;
}

static agc_poller *poller_of(const op *o) { return o->st && o->st->poller ? o->st->poller : o->poller; }

static void send_rest(op *o, int fd, const uint8_t *data, size_t len) {
  while (o->sent < len) {
    int64_t n = agc_fs_write(fd, data + o->sent, len - o->sent);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) {
      fail_op(o, FS_WRITE, n < 0 ? errno : EIO);
      return;
    }
    o->sent += (size_t)n;
  }
}

static void step_read_bytes(op *o) {
  file_state *st = o->st;
  bool eof = false;
  while (pending(st) < o->count && !eof)
    if (!fill(st, &o->err, &eof)) {
      o->status = FS_READ;
      return;
    }
  size_t n = pending(st) < o->count ? pending(st) : o->count;
  o->out = malloc(n ? n : 1);
  if (!o->out) {
    fail_op(o, FS_READ, ENOMEM);
    return;
  }
  if (n) memcpy(o->out, st->buf + st->start, n);
  st->start += n;
  o->out_len = n;
}

/* One non-blocking pass of a call on a polled descriptor, on the loop
   thread; false while it must wait for the descriptor. */
static bool step(op *o) {
  switch (o->kind) {
    case OP_READ_TEXT: step_read_text(o); break;
    case OP_READ_LINE: work_read_line(o); break;
    case OP_READ_BLOCK: work_read_block(o); break;
    case OP_READ_BYTES: step_read_bytes(o); break;
    case OP_CLOSE:
      if (o->st->writable) send_rest(o, o->st->fd, o->st->buf, o->st->end);
      break;
    default: send_rest(o, o->st ? o->st->fd : o->fd, o->in, o->in_len); break;
  }
  if (o->status != FS_OK && (o->err == EAGAIN || o->err == EWOULDBLOCK)) {
    o->status = FS_OK;
    o->err = 0;
    return false;
  }
  if (o->kind == OP_CLOSE) o->st->end = 0;
  return true;
}

static void ready(void *data, int status) {
  op *o = data;
  if (!step(o)) {
    if (status >= 0) return;
    fail_op(o, writes(o) ? FS_WRITE : FS_READ, EIO);
  }
  agc_poller_pause(poller_of(o));
  agc_io_ready(o->job);
}

static bool opens(const op *o) {
  return o->kind == OP_OPEN_READ || o->kind == OP_OPEN_WRITE || o->kind == OP_OPEN_CREATE || o->kind == OP_OPEN_APPEND;
}

/* The rest of a whole-file call whose path is a pipe, a FIFO or a device:
   its pool work only opened it, and the job now waits on the loop. For an open whose descriptor is polled, the
   poller is made here, on the I/O thread, since it is a libuv handle. */
static bool more(void *data, agc_io_job *job) {
  op *o = data;
  if (opens(o)) {
    int err = 0;
    if (o->status == FS_OK && o->st->polled && !(o->st->poller = agc_poller_open(o->vm, o->st->fd, &err)))
      fail_op(o, FS_OPEN, err);
    return false;
  }
  if (!o->polled || o->status != FS_OK) return false;
  int err = 0;
  o->poller = agc_poller_open(o->vm, o->fd, &err);
  if (!o->poller) {
    fail_op(o, writes(o) ? FS_WRITE : FS_READ, err);
    return false;
  }
  o->job = job;
  if (step(o)) return false;
  agc_poller_wait(o->poller, writes(o), ready, o);
  return true;
}

/* The `more` step of a polled wait (poll_io): the wait starts on the I/O thread, in the job's START, before its
   deadline is armed. */
static bool begin_wait(void *data, agc_io_job *job) {
  op *o = data;
  o->job = job;
  agc_poller_wait(o->st->poller, writes(o), ready, o);
  return true;
}

/* The kind's `pause`: the deadline of a polled wait passed, and the wait stops on the I/O thread before `expired`
   moves the buffer that its callback writes. */
static void pause_wait(void *data) {
  agc_poller *p = poller_of(data);
  if (p) agc_poller_pause(p);
}

static bool stop(agc_vm *vm, void *data, agc_value context, bool deadline) {
  (void)vm;
  (void)context;
  (void)deadline;
  agc_poller *p = poller_of(data);
  if (!p) return false;
  agc_poller_pause(p);
  return true;
}

static agc_value ok_void(void) { return agc_result_value(true, agc_void()); }

agc_value agc_system_error(agc_vm *vm, const char *what, int err) {
  text t = {0};
  puts_text(&t, what);
  put_system_error(vm, &t, err);
  return error_text(&t);
}

static agc_value common_error(agc_vm *vm, const op *o) {
  size_t path_len = o->path ? strlen(o->path) : 0;
  switch (o->status) {
    case FS_NOT_REGULAR: return error_of(not_regular);
    case FS_TOO_BIG: return error_of("filesystem: file exceeds 1048576 bytes");
    case FS_OPEN:
      if (o->kind == OP_LIST) return os_error(vm, "directory-list: could not open directory", o->path, path_len, o->err);
      if (o->kind == OP_READ_TEXT || o->kind == OP_OPEN_READ || o->kind == OP_SHA256)
        return os_error(vm, "open-input-file: cannot open input file", o->path, path_len, o->err);
      if (o->kind == OP_ZLIB_FILE) {
        if (!o->dst_failed) return os_error(vm, "open-input-file: cannot open input file", o->path, path_len, o->err);
        size_t to_len = o->to ? strlen(o->to) : 0;
        return os_error(vm, "open-output-file: error opening file", o->to, to_len, o->err);
      }
      return os_error(vm, "open-output-file: error opening file", o->path, path_len, o->err);
    case FS_IS_DIR: {
      text t = {0};
      puts_text(&t, "open-output-file: path is a directory\n  path: ");
      put(&t, o->path, path_len);
      puts_text(&t, "\n  system error: path refers to a directory; rkt_err=9");
      return error_text(&t);
    }
    case FS_MISSING: return error_of("filesystem: path does not exist");
    case FS_LINK: return error_of("filesystem: path is not a regular file or directory");
    case FS_EOF: return error_of("filesystem: end of file");
    case FS_LONG_LINE: return error_of("filesystem: line exceeds 1048576 bytes");
    case FS_MKDIR: return os_error(vm, "make-directory: cannot make directory", o->path, o->fail_at, o->err);
    case FS_RESOLVE: return os_error(vm, "filesystem: cannot resolve path", o->path, path_len, o->err);
    case FS_REMOVE: return os_error(vm, "filesystem: cannot remove path", o->path, path_len, o->err);
    case FS_TREE_DEEP: return error_of(too_deep);
    case FS_REFUSED: return error_of(refused_path);
    case FS_LOCK: return agc_system_error(vm, "filesystem: cannot lock file", o->err);
    case FS_NOT_LOCKABLE: return error_of(not_lockable);
    case FS_ZLIB_FORMAT:
      if (o->kind == OP_ZLIB_FILE &&
          (o->zlib_kind == AGC_ZLIB_DEFLATE_FILE || o->zlib_kind == AGC_ZLIB_GZIP_FILE))
        return error_of("zlib: compression failed");
      return error_of("zlib: invalid compressed data");
    case FS_ZLIB_CHECK: return error_of("zlib: checksum mismatch");
    case FS_ZLIB_TRAILING: return error_of("zlib: trailing bytes after stream end");
    case FS_ZLIB_TOO_BIG: return error_of("zlib: output exceeds max_out_bytes");
    case FS_ZLIB_INPUT_BIG:
      if (o->kind == OP_ZLIB_FILE &&
          (o->zlib_kind == AGC_ZLIB_DEFLATE_FILE || o->zlib_kind == AGC_ZLIB_GZIP_FILE))
        return error_of("zlib: input exceeds 1073741824 bytes");
      return error_of("zlib: compressed input exceeds 268435456 bytes");
    case FS_RENAME: {
      text t = {0};
      puts_text(&t, "filesystem: cannot rename path\n  from: ");
      put(&t, o->path, path_len);
      puts_text(&t, "\n  to: ");
      put(&t, o->to, strlen(o->to));
      put_system_error(vm, &t, o->err);
      return error_text(&t);
    }
    default:
      return agc_system_error(vm, o->status == FS_WRITE ? "error writing to stream port" : "error reading from stream port",
                              o->err);
  }
}

static agc_value text_result(const op *o) {
  if (o->out_len > LIMIT) return error_of("filesystem: file exceeds 1048576 bytes");
  size_t chars;
  if (!agc_utf8_chars(o->out, o->out_len, &chars)) return agc_utf8_error(o->out, o->out_len);
  return agc_result_value(true, agc_string_value(agc_make_string((const char *)o->out, o->out_len, chars)));
}

static uint32_t file_info_struct(agc_vm *vm) {
  static const char *const fields[] = {"kind", "size_bytes", "modified_seconds", "mode", "user_id", "group_id"};
  return agc_builtin_struct(vm, "FileInfo", fields, 6);
}

static agc_value stat_result(agc_vm *vm, const op *o) {
  agc_struct *info = agc_new_struct(file_info_struct(vm), 6);
  info->fields[0] = agc_string_value(agc_make_string(o->file_type, strlen(o->file_type), strlen(o->file_type)));
  info->fields[1] = agc_int(o->size);
  info->fields[2] = agc_int(o->mtime);
  info->fields[3] = agc_int(o->mode);
  info->fields[4] = agc_int(o->user_id);
  info->fields[5] = agc_int(o->group_id);
  return agc_result_value(true, agc_struct_value(info));
}

static agc_value list_result(agc_vm *vm, const op *o) {
  agc_list_builder b;
  agc_list_builder_sized(&b, o->count);
  size_t at = 0;
  for (size_t k = 0; k < o->count; k++) {
    size_t len = strlen((const char *)o->out + at);
    agc_list_builder_push(&b, agc_string_value(lossy(o->out + at, len)));
    at += len + 1;
  }
  agc_list *names = agc_list_builder_finish(&b);
  return agc_result_value(true, agc_sort_by_keys(vm, names, names));
}

static agc_value real_result(const op *o) {
  return agc_result_value(true, agc_string_value(lossy(o->out, o->out_len)));
}

static agc_value bytes_result(const op *o) {
  agc_list_builder b;
  agc_list_builder_sized(&b, o->out_len);
  for (size_t k = 0; k < o->out_len; k++) agc_list_builder_push(&b, agc_int(o->out[k]));
  return agc_result_value(true, agc_list_value(agc_list_builder_finish(&b)));
}

static agc_value closed(agc_vm *vm, void *data, agc_value context) {
  op *o = data;
  agc_resource *r = agc_as_handle(vm, context);
  r->context = o->status == FS_OK ? agc_void() : common_error(vm, o);
  agc_task_wake_all(vm, &r->waiters, &r->waiters_tail, "close");
  agc_task *ender = r->ender;
  r->ender = NULL;
  if (ender) agc_task_close_done(vm, ender);
  drop(data);
  return agc_void();
}

/* The end of a file handle: its resource leaves the registry, and the io trace says so. The trace lines file_open
   and file_close let a test see, on every platform, that a file was closed before the next one opened. */
static void forget_file(agc_vm *vm, agc_resource *r) {
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "file_close handle=%" PRIu64, r->id);
  agc_unregister(vm, r);
}

static const agc_io_kind close_io = {work, closed, closed, drop, false, "file", NULL, true, NULL};

static const agc_io_kind poll_close_io = {NULL, closed, closed, drop, true, "file", stop, true, NULL};

/* The close of an ended task's file, or of a file still open when the run
   ends: pending while a job holds it. */
static void close_file(agc_vm *vm, agc_resource *r, agc_task *ender) {
  agc_sync_assert(vm);
  r->closing = true;
  r->next_owner = NULL;
  agc_task_wake_all(vm, &r->waiters, &r->waiters_tail, "close");
  if (!r->native || r->holder) return;
  op *o = new_op(vm, OP_CLOSE);
  o->st = r->native;
  o->owns_st = true;
  r->native = NULL;
  forget_file(vm, r);
  if (!o->st->poller) {
    agc_io_detached(vm, &close_io, o, agc_handle_value(r), AGC_JOB_FLUSH);
    if (ender) {
      r->ender = ender;
      ender->closing++;
    }
  } else if (step(o)) {
    drop(o);
  } else {
    o->job = agc_io_detached(vm, &poll_close_io, o, agc_handle_value(r), AGC_JOB_FLUSH);
    agc_poller_wait(o->st->poller, true, ready, o);
  }
}

static agc_value done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  op *o = data;
  if ((o->kind == OP_STAT || o->kind == OP_LSTAT) && o->status == FS_OK) {
    op info = *o;
    free_op(o);
    return stat_result(vm, &info);
  }
  agc_value result;
  if (o->status != FS_OK) {
    result = common_error(vm, o);
  } else {
    switch (o->kind) {
      case OP_READ_TEXT:
      case OP_READ_LINE: result = text_result(o); break;
      case OP_SHA256: result = bytes_result(o); break;
      case OP_ZLIB_FILE: result = agc_result_value(true, agc_int(o->size)); break;
      case OP_LIST: result = list_result(vm, o); break;
      case OP_REAL: result = real_result(o); break;
      case OP_READ_BYTES: result = bytes_result(o); break;
      case OP_TRY_LOCK: result = agc_result_value(true, agc_bool(o->locked)); break;
      case OP_OPEN_READ:
      case OP_OPEN_WRITE:
      case OP_OPEN_CREATE:
      case OP_OPEN_APPEND: {
        agc_resource *r = agc_register(vm, o->st, release_state);
        agc_own(vm, r, close_file);
        r->pool_close = true;
        AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "file_open handle=%" PRIu64, r->id);
        o->st = NULL;
        result = agc_result_value(true, agc_handle_value(r));
        break;
      }
      default: result = ok_void(); break;
    }
  }
  drop(o);
  return result;
}

static agc_value expired(agc_vm *vm, void *data, agc_value context) {
  op *o = data;
  agc_poller *p = poller_of(o);
  if (p) agc_poller_pause(p);
  if (o->kind == OP_CLOSE && o->sent) {
    memmove(o->st->buf, o->st->buf + o->sent, o->st->end - o->sent);
    o->st->end -= o->sent;
    o->sent = 0;
  }
  if (agc_is(context, AGC_T_HANDLE)) {
    o->owns_st = true;
    agc_resource *r = agc_as_handle(vm, context);
    r->native = NULL;
    forget_file(vm, r);
  }
  return error_of(timed_out);
}

static const agc_io_kind file_io = {work, done, expired, drop, false, "file", stop, false, pause_wait};

static const agc_io_kind poll_io = {NULL, done, expired, drop, true, "file", stop, false, pause_wait};

static void files_on(agc_vm *vm, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-INTERNAL", "file access is off in this run", span);
}

/* --deny-fs: true when the builtin must return error_of(AGC_DENIED_FS) before it opens or allocates anything. */
static bool fs_denied(agc_vm *vm, uint32_t span) {
  files_on(vm, span);
  return vm->rt->deny_fs;
}

/* A write or close of a handle carries bytes that earlier calls already accepted: its pool work runs to its end after
   a timeout, so the end of the run waits for it as a flush, or those bytes would be lost at the exit. */
static agc_value start(agc_vm *vm, op *o, agc_value context, int64_t timeout) {
  o->vm = vm;
  if (!o->st || !o->st->poller) {
    unsigned flags = o->kind == OP_WRITE || o->kind == OP_CLOSE ? AGC_JOB_FLUSH : 0;
    agc_io_start_flags(vm, &file_io, o, context, timeout, more, flags);
    return agc_void();
  }
  if (step(o)) return done(vm, o, context);
  agc_io_start_then(vm, &poll_io, o, context, timeout, begin_wait);
  return agc_void();
}

static agc_value path_op(agc_vm *vm, op_kind kind, const agc_string *path, int64_t timeout, const char *who,
                         const char *expected) {
  if (timeout <= 0) return error_of(bad_timeout);
  if (!path_string(path)) return contract_error(who, expected, path);
  op *o = new_op(vm, kind);
  o->path = agc_host_path(vm, path);
  return start(vm, o, agc_void(), timeout);
}

static agc_value builtin_read_text(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  return path_op(vm, OP_READ_TEXT, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), complete_who,
                 complete_expected);
}

static agc_value write_text(agc_vm *vm, agc_value *args, uint32_t span, op_kind kind) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  const agc_string *path = agc_as_string(vm, args[0]);
  const agc_string *content = agc_as_string(vm, args[1]);
  int64_t timeout = agc_as_int(vm, args[2]);
  if (content->bytes > LIMIT) return error_of("filesystem: text exceeds 1048576 bytes");
  if (timeout <= 0) return error_of(bad_timeout);
  if (!path_string(path)) return contract_error(complete_who, complete_expected, path);
  op *o = new_op(vm, kind);
  o->in = malloc(content->bytes ? content->bytes : 1);
  if (!o->in) agc_out_of_memory();
  if (content->bytes) memcpy(o->in, content->data, content->bytes);
  o->in_len = content->bytes;
  o->path = agc_host_path(vm, path);
  return start(vm, o, agc_void(), timeout);
}

static agc_value builtin_write_text(agc_vm *vm, agc_value *args, uint32_t span) {
  return write_text(vm, args, span, OP_WRITE_TEXT);
}

static agc_value builtin_append_text(agc_vm *vm, agc_value *args, uint32_t span) {
  return write_text(vm, args, span, OP_APPEND_TEXT);
}

static agc_value builtin_stat(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  return path_op(vm, OP_STAT, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), complete_who, complete_expected);
}

static agc_value builtin_sha256(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  return path_op(vm, OP_SHA256, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), complete_who,
                 complete_expected);
}

/* The file jobs behind the Zlib.*_file builtins (declared in services.h):
   the whole-file call shape of the other file calls (the File global timer,
   Result[Int] counting the bytes written, the partial kept on error), over
   the shared codec kernel of zlib_codec.h. */
agc_value agc_zlib_file(agc_vm *vm, agc_zlib_file_kind kind, const agc_string *src, const agc_string *dst,
                        int64_t level, int64_t max_out, int64_t timeout, uint32_t span) {
  files_on(vm, span);
  if (vm->rt->deny_fs) return error_of(AGC_DENIED_FS);
  bool compress = kind == AGC_ZLIB_DEFLATE_FILE || kind == AGC_ZLIB_GZIP_FILE;
  if (compress && (level < 0 || level > 9)) return error_of("zlib: level must be between 0 and 9");
  if (max_out < 1 || max_out > ZLIB_FILE_MAX_OUT)
    return error_of("zlib: max_out_bytes must be between 1 and 1073741824");
  if (timeout <= 0) return error_of(bad_timeout);
  if (!path_string(src)) return contract_error(complete_who, complete_expected, src);
  if (!path_string(dst)) return contract_error(complete_who, complete_expected, dst);
  op *o = new_op(vm, OP_ZLIB_FILE);
  o->path = agc_host_path(vm, src);
  o->to = agc_host_path(vm, dst);
  o->count = (size_t)max_out;
  o->zlib_kind = (int)kind;
  o->zlib_level = level;
  return start(vm, o, agc_void(), timeout);
}

static agc_value builtin_lstat(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  return path_op(vm, OP_LSTAT, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), complete_who, complete_expected);
}

static agc_value builtin_dir_list(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  return path_op(vm, OP_LIST, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), "directory-list", "path-string?");
}

static agc_value builtin_dir_mkdir(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  return path_op(vm, OP_MKDIR, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), "make-directory*",
                 "path-string?");
}

static agc_value builtin_dir_mkdir_private(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  return path_op(vm, OP_MKDIR_PRIVATE, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), "make-directory",
                 "path-string?");
}

static agc_value builtin_remove(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  const agc_string *path = agc_as_string(vm, args[0]);
#ifdef _WIN32
  if (path_string(path) && !windows_remove_input_valid(path)) return error_of(refused_windows_path);
#endif
  return path_op(vm, OP_REMOVE, path, agc_as_int(vm, args[1]), "delete-directory/files", "path-string?");
}

static agc_value builtin_rename(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  const agc_string *from = agc_as_string(vm, args[0]);
  const agc_string *to = agc_as_string(vm, args[1]);
  int64_t timeout = agc_as_int(vm, args[2]);
  if (timeout <= 0) return error_of(bad_timeout);
  if (!path_string(from)) return contract_error(rename_who, "path-string?", from);
  if (!path_string(to)) return contract_error(rename_who, "path-string?", to);
  op *o = new_op(vm, OP_RENAME);
  o->path = agc_host_path(vm, from);
  o->to = agc_host_path(vm, to);
  return start(vm, o, agc_void(), timeout);
}

static op *open_op(agc_vm *vm, op_kind kind, const agc_string *path) {
  op *o = new_op(vm, kind);
  o->path = agc_host_path(vm, path);
  o->st = new_state(kind == OP_OPEN_READ, kind != OP_OPEN_READ);
  o->owns_st = true;
  return o;
}

static agc_value close_handle(agc_vm *vm, agc_resource *r, agc_value handle, int64_t timeout) {
  op *o = new_op(vm, OP_CLOSE);
  o->st = r->native;
  o->owns_st = true;
  r->native = NULL;
  forget_file(vm, r);
  return start(vm, o, handle, timeout);
}

static agc_value builtin_open(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  const agc_string *path = agc_as_string(vm, args[0]);
  const agc_string *mode = agc_as_string(vm, args[1]);
  int64_t timeout = agc_as_int(vm, args[2]);
  if (timeout <= 0) return error_of(bad_timeout);
  op_kind kind;
  if (same_text(mode->data, mode->bytes, "read")) {
    kind = OP_OPEN_READ;
  } else if (same_text(mode->data, mode->bytes, "write")) {
    kind = OP_OPEN_WRITE;
  } else if (same_text(mode->data, mode->bytes, "append")) {
    kind = OP_OPEN_APPEND;
  } else if (same_text(mode->data, mode->bytes, "create_private")) {
    kind = OP_OPEN_CREATE;
  } else {
    return error_of("filesystem: mode must be read, write, append, or create_private");
  }
  if (!path_string(path)) return contract_error(complete_who, complete_expected, path);
  return start(vm, open_op(vm, kind, path), agc_void(), timeout);
}

static bool blocked(agc_vm *vm, agc_value handle, int64_t *timeout, agc_value *result) {
  if (*timeout <= 0) {
    *result = error_of(bad_timeout);
    return true;
  }
  if (agc_as_handle(vm, handle)->close != close_file) {
    *result = error_of(not_file);
    return true;
  }
  switch (agc_handle_wait(vm, agc_as_handle(vm, handle), timeout)) {
    case AGC_LOCK_TAKEN: return false;
    case AGC_LOCK_WAIT: *result = agc_void(); return true;
    case AGC_LOCK_TIMEOUT: break;
  }
  *result = error_of(timed_out);
  return true;
}

static file_state *open_state(agc_vm *vm, agc_value handle, agc_value *failure) {
  const agc_resource *r = agc_as_handle(vm, handle);
  if (r->close != close_file) {
    *failure = error_of(not_file);
    return NULL;
  }
  if (r->native && !r->closing) return r->native;
  *failure = error_of("filesystem: file handle is closed");
  return NULL;
}

/* The state of an open handle once the task has the handle's lock; NULL with the call's result in *failure. */
static file_state *held_state(agc_vm *vm, agc_value handle, int64_t *timeout, agc_value *failure) {
  if (blocked(vm, handle, timeout, failure)) return NULL;
  return open_state(vm, handle, failure);
}

static file_state *usable(agc_vm *vm, agc_value handle, bool reading, agc_value *failure) {
  file_state *st = open_state(vm, handle, failure);
  if (!st) return NULL;
  if (reading && !st->readable) {
    *failure = error_of("filesystem: file handle is not open for reading");
  } else if (!reading && !st->writable) {
    *failure = error_of("filesystem: file handle is not open for writing");
  } else {
    return st;
  }
  return NULL;
}

static agc_value read_op(agc_vm *vm, agc_value handle, op_kind kind, size_t count, int64_t timeout) {
  agc_value failure;
  if (blocked(vm, handle, &timeout, &failure)) return failure;
  file_state *st = usable(vm, handle, true, &failure);
  if (!st) return failure;
  op *o = new_op(vm, kind);
  o->st = st;
  o->count = count;
  return start(vm, o, handle, timeout);
}

static agc_value builtin_read_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  int64_t count = agc_as_int(vm, args[1]);
  if (count < 1 || (uint64_t)count > LIMIT) return error_of("filesystem: max_bytes must be between 1 and 1048576");
  return read_op(vm, args[0], OP_READ_BYTES, (size_t)count, agc_as_int(vm, args[2]));
}

static agc_value builtin_read_line(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  return read_op(vm, args[0], OP_READ_LINE, 0, agc_as_int(vm, args[1]));
}

/* The buffered output, then `len` bytes of data and an LF when `newline`, in one write job. */
static agc_value write_out(agc_vm *vm, agc_value handle, file_state *st, const uint8_t *data, size_t len, bool newline,
                           int64_t timeout) {
  op *o = new_op(vm, OP_WRITE);
  o->st = st;
  o->in_len = st->end + len + (newline ? 1 : 0);
  o->in = malloc(o->in_len ? o->in_len : 1);
  if (!o->in) agc_out_of_memory();
  if (st->end) memcpy(o->in, st->buf, st->end);
  if (len) memcpy(o->in + st->end, data, len);
  if (newline) o->in[o->in_len - 1] = '\n';
  st->end = 0;
  return start(vm, o, handle, timeout);
}

static agc_value write_bytes(agc_vm *vm, agc_value handle, const uint8_t *data, size_t len, int64_t timeout) {
  agc_value failure;
  if (blocked(vm, handle, &timeout, &failure)) return failure;
  file_state *st = usable(vm, handle, false, &failure);
  if (!st) return failure;
  if (st->end + len > WRITE_BUFFER) return write_out(vm, handle, st, data, len, false, timeout);
  if (!st->buf) {
    st->buf = malloc(WRITE_BUFFER);
    if (!st->buf) agc_out_of_memory();
    st->cap = WRITE_BUFFER;
  }
  if (len) memcpy(st->buf + st->end, data, len);
  st->end += len;
  return ok_void();
}

static agc_value builtin_write(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  const agc_string *content = agc_as_string(vm, args[1]);
  if (content->bytes > LIMIT) return error_of("filesystem: text exceeds 1048576 bytes");
  return write_bytes(vm, args[0], (const uint8_t *)content->data, content->bytes, agc_as_int(vm, args[2]));
}

static agc_value builtin_write_list(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  const agc_list *values = agc_as_list(vm, args[1]);
  const uint8_t *data = agc_byte_list(vm, values, LIMIT);
  if (!data) return error_of("network: bytes must be 0..255 and at most 1048576 per call");
  return write_bytes(vm, args[0], data, agc_list_len(values), agc_as_int(vm, args[2]));
}

static agc_value builtin_flush(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  agc_value failure;
  int64_t timeout = agc_as_int(vm, args[1]);
  if (blocked(vm, args[0], &timeout, &failure)) return failure;
  file_state *st = usable(vm, args[0], false, &failure);
  if (!st) return failure;
  if (!st->end) return ok_void();
  return write_out(vm, args[0], st, NULL, 0, false, timeout);
}

static agc_value builtin_close(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  agc_resource *r = agc_as_handle(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  agc_value failure;
  if (blocked(vm, args[0], &timeout, &failure)) return failure;
  if (r->closing) return agc_is(r->context, AGC_T_RESULT) ? r->context : ok_void();
  if (!r->native) return ok_void();
  return close_handle(vm, r, args[0], timeout);
}

static agc_value builtin_try_lock(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  agc_value failure;
  int64_t timeout = agc_as_int(vm, args[1]);
  file_state *st = held_state(vm, args[0], &timeout, &failure);
  if (!st) return failure;
  /* A pipe or FIFO waits on the loop, which this one-shot job does not; any other kind that is not a regular file
     (a device that never waits) is refused in the job, after fstat. */
  if (st->poller) return error_of(not_lockable);
  op *o = new_op(vm, OP_TRY_LOCK);
  o->st = st;
  return start(vm, o, args[0], timeout);
}

static file_state *lines_file(agc_vm *vm, const agc_line_reader *r) {
  const agc_resource *res = agc_as_handle(vm, r->handle);
  return res->closing ? NULL : res->native;
}

static bool lines_take(agc_vm *vm, agc_line_reader *r, file_state *st, size_t len, size_t consume, agc_value *line) {
  const uint8_t *data = st->buf + st->start;
  size_t chars;
  agc_charge_bytes(vm, consume);
  bool valid = agc_utf8_chars(data, len, &chars);
  if (valid)
    *line = agc_string_value(agc_small_string(vm, (const char *)data, len, chars));
  else
    r->outcome = agc_utf8_error(data, len);
  st->start += consume;
  st->scan = 0;
  return valid;
}

/* The errors a reader gives before it opens anything, or Void. */
static agc_value lines_refused(agc_vm *vm, const agc_string *path, int64_t timeout) {
  if (vm->rt->deny_fs) return error_of(AGC_DENIED_FS);
  if (timeout <= 0) return error_of(bad_timeout);
  if (!path_string(path)) return contract_error(complete_who, complete_expected, path);
  return agc_void();
}

static void lines_init(agc_line_reader *r, agc_value path, size_t limit, int64_t timeout) {
  r->phase = LINES_START;
  r->path = path;
  r->handle = agc_void();
  r->outcome = ok_void();
  r->limit = limit;
  r->timeout = timeout;
}

bool agc_lines_buffer_ok(int64_t buffer_bytes) {
  return buffer_bytes >= MIN_LINE_BUFFER && buffer_bytes <= MAX_LINE_BUFFER;
}

agc_line_reader *agc_lines_new(agc_vm *vm, agc_value path, int64_t buffer_bytes, int64_t timeout, uint32_t span) {
  files_on(vm, span);
  agc_as_string(vm, path);
  if (!agc_lines_buffer_ok(buffer_bytes))
    agc_fail(vm, "RUNTIME-INTERNAL", "a line reader with an unchecked buffer", span);
  agc_line_reader *r = agc_alloc(sizeof(agc_line_reader));
  lines_init(r, path, (size_t)buffer_bytes, timeout);
  return r;
}

/* The phases run in order: open, then scan the buffer for a line and read a block when it holds none, then close.
   Every path that opened the file goes through LINES_CLOSE, so the file is closed before END, whatever the outcome. A
   phase that started a job and parked returns WAIT; the job's result comes back as `last`. */
agc_lines_status agc_lines_next(agc_vm *vm, agc_line_reader *r, agc_value last, agc_value *out) {
  for (;;) {
    switch (r->phase) {
      case LINES_START: {
        const agc_string *path = agc_as_string(vm, r->path);
        agc_value refused = lines_refused(vm, path, r->timeout);
        if (!agc_is(refused, AGC_T_VOID)) {
          r->outcome = refused;
          r->phase = LINES_CLOSED;
          break;
        }
        r->phase = LINES_OPENED;
        last = start(vm, open_op(vm, OP_OPEN_READ, path), agc_void(), r->timeout);
        if (vm->task->parking) return AGC_LINES_WAIT;
        break;
      }
      case LINES_OPENED: {
        const agc_result *opened = agc_as_result(vm, last);
        if (!opened->ok) {
          r->outcome = last;
          r->phase = LINES_CLOSED;
          break;
        }
        r->handle = opened->value;
        r->phase = LINES_SCAN;
        break;
      }
      case LINES_SCAN: {
        file_state *st = lines_file(vm, r);
        if (!st) {
          r->outcome = error_of("filesystem: file handle is closed");
          r->phase = LINES_CLOSED;
          break;
        }
        line_scan found = scan_line(st, st->scan, r->limit, r->limit, st->eof);
        if (found.kind == LINE_MORE) {
          st->scan = found.scanned;
          op *o = new_op(vm, OP_READ_BLOCK);
          o->st = st;
          o->count = r->limit;
          r->phase = LINES_READ;
          last = start(vm, o, r->handle, r->timeout);
          if (vm->task->parking) return AGC_LINES_WAIT;
          break;
        }
        r->phase = LINES_CLOSE;
        if (found.kind == LINE_LONG) {
          r->outcome = error_of(line_too_long);
        } else if (found.kind == LINE_END) {
          r->outcome = ok_void();
        } else if (lines_take(vm, r, st, found.len, found.consume, out)) {
          r->phase = LINES_SCAN;
          return AGC_LINES_LINE;
        }
        break;
      }
      case LINES_READ:
        r->phase = LINES_SCAN;
        if (!agc_as_result(vm, last)->ok) agc_lines_stop(r, last);
        break;
      case LINES_CLOSE: {
        agc_resource *res = agc_as_handle(vm, r->handle);
        r->phase = LINES_CLOSED;
        if (!res->native || res->closing) break;
        /* The close's own result is not the outcome: a read-only file has nothing left to lose. */
        close_handle(vm, res, r->handle, r->timeout);
        if (vm->task->parking) return AGC_LINES_WAIT;
        break;
      }
      case LINES_CLOSED: *out = r->outcome; return AGC_LINES_END;
    }
  }
}

/* Called between two lines (or before the first): a reader that never opened its file ends at once. */
void agc_lines_stop(agc_line_reader *r, agc_value outcome) {
  r->outcome = outcome;
  if (r->phase == LINES_SCAN) r->phase = LINES_CLOSE;
  if (r->phase == LINES_START) r->phase = LINES_CLOSED;
}

static agc_step lines_step(agc_vm *vm, agc_stepper *self, agc_value last) {
  lines *s = (lines *)self;
  if (s->in_block) {
    s->in_block = false;
    if (!agc_as_result(vm, last)->ok) agc_lines_stop(&s->reader, last);
  }
  agc_value out = agc_void();
  switch (agc_lines_next(vm, &s->reader, last, &out)) {
    case AGC_LINES_LINE: s->in_block = true; return (agc_step){.kind = AGC_STEP_CALL, .value = out};
    case AGC_LINES_WAIT: return (agc_step){.kind = AGC_STEP_WAIT};
    case AGC_LINES_END: break;
  }
  return (agc_step){.kind = AGC_STEP_END, .value = out};
}

static agc_value builtin_each_line(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  const agc_string *path = agc_as_string(vm, args[0]);
  int64_t limit = agc_as_int(vm, args[1]);
  int64_t timeout = agc_as_int(vm, args[2]);
  if (!agc_lines_buffer_ok(limit))
    agc_fail(vm, "RUNTIME-INVALID-COUNT", "buffer_bytes must be between 1024 and 16777216", span + 2);
  agc_value refused = lines_refused(vm, path, timeout);
  if (!agc_is(refused, AGC_T_VOID)) return refused;
  lines *s = agc_alloc(sizeof(lines));
  s->stepper.step = lines_step;
  lines_init(&s->reader, args[0], (size_t)limit, timeout);
  agc_task_stepper(vm, &s->stepper);
  return agc_void();
}

agc_line_writer *agc_writer_new(agc_vm *vm, agc_value path, int64_t timeout, uint32_t span) {
  files_on(vm, span);
  agc_as_string(vm, path);
  agc_line_writer *w = agc_alloc(sizeof(agc_line_writer));
  w->phase = WRITER_START;
  w->path = path;
  w->handle = agc_void();
  w->outcome = ok_void();
  w->timeout = timeout;
  return w;
}

/* One line and its LF into the handle's buffer, which the writer sizes to CHUNK; a line that does not fit goes out
   with the buffer in one write job. A line over 1 MiB is refused, as File.write refuses such a text. */
static agc_value writer_put(agc_vm *vm, agc_line_writer *w, file_state *st, const agc_string *line) {
  if (line->bytes > LIMIT) return error_of("filesystem: line exceeds 1048576 bytes");
  agc_charge_bytes(vm, line->bytes + 1);
  if (!st->buf) {
    st->buf = malloc(CHUNK);
    if (!st->buf) agc_out_of_memory();
    st->cap = CHUNK;
  }
  if (st->end + line->bytes + 1 > st->cap)
    return write_out(vm, w->handle, st, (const uint8_t *)line->data, line->bytes, true, w->timeout);
  memcpy(st->buf + st->end, line->data, line->bytes);
  st->buf[st->end + line->bytes] = '\n';
  st->end += line->bytes + 1;
  return ok_void();
}

/* The phases run in order: open (create or truncate), then one line per call while READY, then flush and close.
   Every path that opened the file goes through WRITER_CLOSE, so it is closed before END. The close flushes what is
   buffered, and its error is the outcome when nothing failed before, since a write error may show up only there. */
agc_writer_status agc_writer_next(agc_vm *vm, agc_line_writer *w, agc_value last, agc_value line, agc_value *out) {
  for (;;) {
    switch (w->phase) {
      case WRITER_START: {
        const agc_string *path = agc_as_string(vm, w->path);
        agc_value refused = lines_refused(vm, path, w->timeout);
        if (!agc_is(refused, AGC_T_VOID)) {
          w->outcome = refused;
          w->phase = WRITER_CLOSED;
          break;
        }
        w->phase = WRITER_OPENED;
        last = start(vm, open_op(vm, OP_OPEN_WRITE, path), agc_void(), w->timeout);
        if (vm->task->parking) return AGC_WRITER_WAIT;
        break;
      }
      case WRITER_OPENED:
        if (!agc_as_result(vm, last)->ok) {
          w->outcome = last;
          w->phase = WRITER_CLOSED;
          break;
        }
        w->handle = agc_as_result(vm, last)->value;
        w->phase = WRITER_READY;
        break;
      case WRITER_READY: {
        if (agc_is(line, AGC_T_VOID)) return AGC_WRITER_READY;
        const agc_resource *res = agc_as_handle(vm, w->handle);
        if (!res->native || res->closing) {
          agc_writer_stop(w, error_of("filesystem: file handle is closed"));
          break;
        }
        w->phase = WRITER_WROTE;
        last = writer_put(vm, w, res->native, agc_as_string(vm, line));
        line = agc_void();
        if (vm->task->parking) return AGC_WRITER_WAIT;
        break;
      }
      case WRITER_WROTE:
        w->phase = WRITER_READY;
        if (!agc_as_result(vm, last)->ok) agc_writer_stop(w, last);
        break;
      case WRITER_CLOSE: {
        agc_resource *res = agc_as_handle(vm, w->handle);
        w->phase = WRITER_CLOSED;
        if (!res->native || res->closing) {
          /* The handle went away under the writer (a write job that timed out takes it, and nothing else can reach
             it), so what it buffered is lost: never an ok outcome. */
          if (agc_as_result(vm, w->outcome)->ok) w->outcome = error_of("filesystem: file handle is closed");
          break;
        }
        w->phase = WRITER_CLOSING;
        last = close_handle(vm, res, w->handle, w->timeout);
        if (vm->task->parking) return AGC_WRITER_WAIT;
        break;
      }
      case WRITER_CLOSING:
        w->phase = WRITER_CLOSED;
        if (agc_as_result(vm, w->outcome)->ok && !agc_as_result(vm, last)->ok) w->outcome = last;
        break;
      case WRITER_CLOSED: *out = w->outcome; return AGC_WRITER_END;
    }
  }
}

/* Called while the writer waits for a line (or before it opened): the next call closes the file. */
void agc_writer_stop(agc_line_writer *w, agc_value outcome) {
  if (w->phase == WRITER_READY) {
    w->outcome = outcome;
    w->phase = WRITER_CLOSE;
  } else if (w->phase == WRITER_START) {
    w->outcome = outcome;
    w->phase = WRITER_CLOSED;
  }
}

static agc_value builtin_real(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  const agc_string *path = agc_as_string(vm, args[0]);
  if (!path_string(path)) return contract_error(complete_who, complete_expected, path);
  op *o = new_op(vm, OP_REAL);
  o->path = agc_host_path(vm, path);
  return start(vm, o, agc_void(), NO_DEADLINE);
}

static agc_value builtin_cwd(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  const agc_string *cwd = cwd_of(vm);
  return agc_result_value(true, agc_string_value(lossy(cwd->data, cwd->bytes)));
}

static bool collapse_leading(const text *t) {
#ifdef _WIN32
  (void)t;
  return false;
#else
  if (t->len < 3 || t->data[0] != '/' || t->data[1] != '/' || t->data[2] == '/') return false;
  for (size_t k = 3; k < t->len; k++)
    if (t->data[k] == '/') return k + 1 == t->len || t->data[k + 1] != '/';
  return true;
#endif
}

static agc_value builtin_join(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_list *parts = agc_as_list(vm, args[0]);
  if (agc_list_len(parts) == 0) return error_of("filesystem: Path.join needs at least one part");
  agc_list_cursor cursor;
  agc_value item;
  agc_list_cursor_begin(&cursor, parts, 0);
  while (agc_list_cursor_next(&cursor, &item)) {
    const agc_string *part = agc_as_string(vm, item);
    if (!path_string(part))
      return contract_error("build-path", "(or/c path-string? path-for-some-system? 'up 'same)", part);
  }
  agc_list_cursor_begin(&cursor, parts, 1);
  while (agc_list_cursor_next(&cursor, &item)) {
    const agc_string *part = agc_as_string(vm, item);
    if (agc_fs_rooted(part->data, part->bytes)) {
      text t = {0};
      puts_text(&t, "build-path: absolute path cannot be added to a path\n  absolute path: ");
      put_form(&t, part);
      return error_text(&t);
    }
  }
  text t = {0};
  agc_list_cursor_begin(&cursor, parts, 0);
  for (size_t k = 0; agc_list_cursor_next(&cursor, &item); k++) {
    const agc_string *part = agc_as_string(vm, item);
    if (k > 0) {
      if (collapse_leading(&t)) {
        memmove(t.data, t.data + 1, t.len - 1);
        t.len--;
      }
      if (t.data[t.len - 1] != '/'
#ifdef _WIN32
          && t.data[t.len - 1] != '\\'
#endif
      ) puts_text(&t, "/");
    }
    put(&t, part->data, part->bytes);
  }
#ifdef _WIN32
  for (size_t k = 0; k < t.len; k++) if (t.data[k] == '\\') t.data[k] = '/';
#endif
  return agc_result_value(true, agc_string_value(lossy(t.data, t.len)));
}

static agc_value builtin_resolve(agc_vm *vm, agc_value *args, uint32_t span) {
  if (fs_denied(vm, span)) return error_of(AGC_DENIED_FS);
  const agc_string *path = agc_as_string(vm, args[0]);
  if (!path_string(path)) return contract_error(complete_who, complete_expected, path);
#ifdef _WIN32
  char *given = agc_cstr(path);
  char *resolved = agc_fs_absolute(given);
  int err = errno;
  free(given);
  if (!resolved) return os_error(vm, "filesystem: cannot resolve path", path->data, path->bytes, err);
  agc_value result = agc_result_value(true, agc_string_value(lossy(resolved, strlen(resolved))));
  free(resolved);
  return result;
#else
  text full = {0};
  if (path->data[0] != '/') {
    const agc_string *cwd = cwd_of(vm);
    put(&full, cwd->data, cwd->bytes);
  }
  put(&full, path->data, path->bytes);
  size_t *starts = agc_alloc_atomic(agc_size_mul(full.len, sizeof(size_t)));
  size_t *lens = agc_alloc_atomic(agc_size_mul(full.len, sizeof(size_t)));
  size_t depth = 0;
  bool dir_form = full.data[full.len - 1] == '/';
  for (size_t at = 0; at < full.len;) {
    if (full.data[at] == '/') {
      at++;
      continue;
    }
    size_t end = at;
    while (end < full.len && full.data[end] != '/') end++;
    const char *name = full.data + at;
    size_t len = end - at;
    bool last = end == full.len;
    if (same_text(name, len, ".") || same_text(name, len, "..")) {
      if (len == 2 && depth > 0) depth--;
      if (last) dir_form = true;
    } else {
      starts[depth] = at;
      lens[depth] = len;
      depth++;
    }
    at = end;
  }
  text out = {0};
  puts_text(&out, "/");
  for (size_t k = 0; k < depth; k++) {
    if (k > 0) puts_text(&out, "/");
    put(&out, full.data + starts[k], lens[k]);
  }
  if (dir_form && depth > 0) puts_text(&out, "/");
  return agc_result_value(true, agc_string_value(lossy(out.data, out.len)));
#endif
}

const agc_builtin agc_file_builtins[] = {
  {"File.open", 3, builtin_open, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"File.read_bytes", 3, builtin_read_bytes, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"File.read_line", 2, builtin_read_line, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"File.write", 3, builtin_write, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"File.write_bytes", 3, builtin_write_list, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"File.flush", 2, builtin_flush, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"File.close", 2, builtin_close, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"File.each_line", 4, builtin_each_line, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"File.read_text", 2, builtin_read_text, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"File.write_text", 3, builtin_write_text, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"File.append_text", 3, builtin_append_text, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"File.stat", 2, builtin_stat, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"File.lstat", 2, builtin_lstat, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"File.try_lock", 2, builtin_try_lock, AGC_NATIVE_NONE, AGC_COST_NONE, true, false},
  {"Dir.list", 2, builtin_dir_list, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Dir.mkdir", 2, builtin_dir_mkdir, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Dir.mkdir_private", 2, builtin_dir_mkdir_private, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Path.cwd", 0, builtin_cwd, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Path.join", 1, builtin_join, AGC_NATIVE_NONE, AGC_COST_SIZE, false, false},
  {"Path.resolve", 1, builtin_resolve, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Path.real", 1, builtin_real, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Path.remove", 2, builtin_remove, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  {"Path.rename", 3, builtin_rename, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
  /* New rows go last: a C test may index a table by position. */
  {"File.sha256", 2, builtin_sha256, AGC_NATIVE_NONE, AGC_COST_NONE, false, false},
};

const size_t agc_file_builtin_count = sizeof agc_file_builtins / sizeof agc_file_builtins[0];
#else
void agc_files_init(agc_vm *vm) { (void)vm; }

agc_file_ids agc_files_inherited(void) { return (agc_file_ids){0}; }

void agc_files_forget(agc_file_ids *ids, int fd) {
  (void)ids;
  (void)fd;
}

void agc_files_close(agc_vm *vm) { (void)vm; }

bool agc_lines_buffer_ok(int64_t buffer_bytes) {
  return buffer_bytes >= MIN_LINE_BUFFER && buffer_bytes <= MAX_LINE_BUFFER;
}

agc_line_reader *agc_lines_new(agc_vm *vm, agc_value path, int64_t buffer_bytes, int64_t timeout, uint32_t span) {
  (void)path;
  (void)buffer_bytes;
  (void)timeout;
  agc_fail(vm, "RUNTIME-INTERNAL", "file access is off in this run", span);
}

agc_lines_status agc_lines_next(agc_vm *vm, agc_line_reader *r, agc_value last, agc_value *out) {
  (void)r;
  (void)last;
  (void)out;
  agc_fail(vm, "RUNTIME-INTERNAL", "file access is off in this run", 0);
}

void agc_lines_stop(agc_line_reader *r, agc_value outcome) {
  (void)r;
  (void)outcome;
}

agc_line_writer *agc_writer_new(agc_vm *vm, agc_value path, int64_t timeout, uint32_t span) {
  (void)path;
  (void)timeout;
  agc_fail(vm, "RUNTIME-INTERNAL", "file access is off in this run", span);
}

agc_writer_status agc_writer_next(agc_vm *vm, agc_line_writer *w, agc_value last, agc_value line, agc_value *out) {
  (void)w;
  (void)last;
  (void)line;
  (void)out;
  agc_fail(vm, "RUNTIME-INTERNAL", "file access is off in this run", 0);
}

void agc_writer_stop(agc_line_writer *w, agc_value outcome) {
  (void)w;
  (void)outcome;
}

agc_value agc_zlib_file(agc_vm *vm, agc_zlib_file_kind kind, const agc_string *src, const agc_string *dst,
                        int64_t level, int64_t max_out, int64_t timeout, uint32_t span) {
  (void)kind;
  (void)src;
  (void)dst;
  (void)level;
  (void)max_out;
  (void)timeout;
  agc_fail(vm, "RUNTIME-INTERNAL", "file access is off in this run", span);
}

const agc_builtin agc_file_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE, false, false}};

const size_t agc_file_builtin_count = 0;
#endif

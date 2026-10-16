/*
 * The File, Dir and Path builtins (Linux only): the argument checks, host
 * paths, and file handles with their read and write buffers, including the
 * owner-only creates, lstat, the handle lock, the removals and the no-replace
 * rename. Work runs on the libuv pool. Service layer. Design:
 * docs/vm/02-reference-behavior.md §2.8.
 */
/* glibc declares renameat2 and RENAME_NOREPLACE only for _GNU_SOURCE. */
#define _GNU_SOURCE
#include "services.h"

#ifdef __linux__
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/magic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <unistd.h>

#define LIMIT ((size_t)1048576)
#define FORM_WIDTH 256
#define CHUNK ((size_t)65536)
#define WRITE_BUFFER ((size_t)4096)
#define MIN_LINE_BUFFER ((int64_t)1024)
#define MAX_LINE_BUFFER ((int64_t)16777216)
#define NO_DEADLINE ((int64_t)-1)

typedef enum {
  FS_OK, FS_NOT_REGULAR, FS_TOO_BIG, FS_OPEN, FS_IS_DIR, FS_READ, FS_WRITE, FS_MISSING, FS_LINK, FS_EOF, FS_LONG_LINE,
  FS_MKDIR, FS_RESOLVE, FS_REMOVE, FS_TREE_DEEP, FS_REFUSED, FS_LOCK, FS_NOT_LOCKABLE, FS_RENAME
} fs_status;

typedef enum {
  OP_READ_TEXT, OP_WRITE_TEXT, OP_APPEND_TEXT, OP_STAT, OP_LIST, OP_MKDIR, OP_OPEN_READ, OP_OPEN_WRITE,
  OP_OPEN_APPEND, OP_READ_BYTES, OP_READ_LINE, OP_READ_BLOCK, OP_WRITE, OP_CLOSE, OP_REAL, OP_LSTAT,
  OP_OPEN_CREATE, OP_MKDIR_PRIVATE, OP_REMOVE, OP_TRY_LOCK, OP_RENAME
} op_kind;

typedef struct {
  int fd;
  bool readable, writable, polled, eof;
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
  bool owns_st, polled, locked;
  const char *file_type;
  agc_vm *vm;
  agc_poller *poller;
  agc_io_job *job;
  size_t sent;
  int64_t size, mtime, mode, user_id, group_id;
} op;

typedef struct {
  struct stat pipe;
  int fd;
  bool found;
} pipe_search;

typedef enum { LINES_START, LINES_OPENED, LINES_SCAN, LINES_RESUME, LINES_CLOSE, LINES_CLOSED } lines_phase;

typedef struct {
  agc_stepper stepper;
  lines_phase phase;
  agc_value path, handle, outcome;
  size_t limit;
  int64_t timeout;
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
static const char timed_out[] = "filesystem: operation timed out";
static const char line_too_long[] = "filesystem: line exceeds buffer_bytes";
static const char bad_timeout[] = "filesystem: timeout must be positive milliseconds";
static const char too_deep[] = "filesystem: directory tree is deeper than 128 levels";
static const char refused_path[] = "filesystem: refusing to remove /, . or ..";
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
  locale_t messages = vm->rt->messages_locale;
  return messages ? strerror_l(err, messages) : strerror(err);
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

static size_t byte_escape(const uint8_t *data, size_t len, size_t at, char out[5]) {
  static const char named[] = "abtnvfr";
  uint8_t b = data[at];
  if (b == '"' || b == '\\') {
    out[0] = '\\';
    out[1] = (char)b;
    return 2;
  }
  if (b >= 32 && b < 127) {
    out[0] = (char)b;
    return 1;
  }
  out[0] = '\\';
  if (b >= 7 && b <= 13) {
    out[1] = named[b - 7];
    return 2;
  }
  if (b == 27) {
    out[1] = 'e';
    return 2;
  }
  bool pad = at + 1 < len && data[at + 1] >= '0' && data[at + 1] <= '7';
  int n = snprintf(out + 1, 4, pad ? "%03o" : "%o", (unsigned)b);
  return 1 + (size_t)n;
}

agc_value agc_utf8_error(const uint8_t *data, size_t len) {
  text t = {0};
  text form = {0};
  puts_text(&t, "bytes->string/utf-8: byte string is not a well-formed UTF-8 encoding\n  byte string: ");
  puts_text(&form, "#\"");
  for (size_t at = 0; at < len && form.len <= FORM_WIDTH; at++) {
    char piece[5];
    put(&form, piece, byte_escape(data, len, at, piece));
  }
  puts_text(&form, "\"");
  if (form.len > FORM_WIDTH) {
    put(&t, form.data, FORM_WIDTH - 3);
    puts_text(&t, "...");
  } else {
    put(&t, form.data, form.len);
  }
  return error_text(&t);
}

static bool same_text(const char *data, size_t len, const char *word) {
  return len == strlen(word) && memcmp(data, word, len) == 0;
}

static bool path_string(const agc_string *s) { return s->bytes > 0 && !memchr(s->data, 0, s->bytes); }

void agc_files_init(agc_vm *vm) {
  size_t cap = 256;
  char *buf = NULL;
  for (;;) {
    buf = agc_alloc_atomic(cap);
    if (getcwd(buf, cap)) break;
    if (errno != ERANGE) {
      buf[0] = '/';
      buf[1] = '\0';
      break;
    }
    cap = agc_size_mul(cap, 2);
  }
  size_t len = strlen(buf);
  text t = {0};
  put(&t, buf, len);
  if (len == 0 || buf[len - 1] != '/') puts_text(&t, "/");
  vm->rt->cwd = agc_make_string(t.data, t.len, 0);
  if (!vm->rt->messages_locale) vm->rt->messages_locale = newlocale(LC_MESSAGES_MASK | LC_CTYPE_MASK, "", (locale_t)0);
}

void agc_files_close(agc_vm *vm) {
  if (vm->rt->messages_locale) freelocale(vm->rt->messages_locale);
  vm->rt->messages_locale = (locale_t)0;
}

static const agc_string *cwd_of(agc_vm *vm) {
  if (!vm->rt->cwd) agc_files_init(vm);
  return vm->rt->cwd;
}

char *agc_host_path(agc_vm *vm, const agc_string *s) {
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
    close(st->fd);
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
  struct stat info;
  *polled = false;
  if (fstat(fd, &info) != 0) return errno;
  if (S_ISREG(info.st_mode) || S_ISBLK(info.st_mode) || S_ISDIR(info.st_mode)) return 0;
  int ep = epoll_create1(EPOLL_CLOEXEC);
  if (ep < 0) return errno;
  struct epoll_event event = {.events = EPOLLIN};
  int err = epoll_ctl(ep, EPOLL_CTL_ADD, fd, &event) == 0 ? 0 : errno;
  close(ep);
  *polled = err == 0;
  return err == EPERM ? 0 : err;
}

static void blocking(int fd) {
  int flags = fcntl(fd, F_GETFL);
  if (flags >= 0) fcntl(fd, F_SETFL, flags & ~O_NONBLOCK);
}

static bool read_all(int fd, uint8_t *buf, size_t want, size_t *got, int *err) {
  size_t done = 0;
  while (done < want) {
    ssize_t n = read(fd, buf + done, want - done);
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
    ssize_t n = write(fd, data + done, len - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) {
      *err = n < 0 ? errno : EIO;
      return false;
    }
    done += (size_t)n;
  }
  return true;
}

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
  struct stat info;
  if (stat(path, &info) == 0) return !S_ISDIR(info.st_mode);
  return errno != ELOOP;
}

bool agc_each_fd(bool (*visit)(int fd, void *data), void *data) {
  DIR *dir = opendir("/proc/self/fd");
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

static bool same_file(int fd, const struct stat *file) {
  struct stat info;
  return fstat(fd, &info) == 0 && info.st_dev == file->st_dev && info.st_ino == file->st_ino;
}

static bool pipe_info(int fd, struct stat *info) {
  struct statfs fs;
  return fstat(fd, info) == 0 && S_ISFIFO(info->st_mode) && fstatfs(fd, &fs) == 0 && fs.f_type == PIPEFS_MAGIC;
}

static bool same_pipe(int fd, void *data) {
  pipe_search *s = data;
  s->found = fd > 2 && fd != s->fd && same_file(fd, &s->pipe);
  return s->found;
}

static bool note_pipe(int fd, void *data) {
  agc_file_ids *ids = data;
  struct stat info;
  if (!pipe_info(fd, &info)) return false;
  if (ids->count == ids->cap) {
    size_t cap = ids->cap ? agc_size_mul(ids->cap, 2) : 8;
    agc_file_id *grown = agc_alloc_atomic(agc_size_mul(cap, sizeof *grown));
    if (ids->count) memcpy(grown, ids->ids, ids->count * sizeof *grown);
    ids->ids = grown;
    ids->cap = cap;
  }
  ids->ids[ids->count++] = (agc_file_id){(uint64_t)info.st_dev, (uint64_t)info.st_ino};
  return false;
}

agc_file_ids agc_files_inherited(void) {
  agc_file_ids ids = {0};
  agc_each_fd(note_pipe, &ids);
  return ids;
}

void agc_files_forget(agc_file_ids *ids, int fd) {
  struct stat info;
  if (!pipe_info(fd, &info)) return;
  for (size_t k = ids->count; k-- > 0;)
    if (ids->ids[k].dev == (uint64_t)info.st_dev && ids->ids[k].ino == (uint64_t)info.st_ino)
      ids->ids[k] = ids->ids[--ids->count];
}

static bool inherited(const agc_file_ids *ids, const struct stat *info) {
  for (size_t k = 0; k < ids->count; k++)
    if (ids->ids[k].dev == (uint64_t)info->st_dev && ids->ids[k].ino == (uint64_t)info->st_ino) return true;
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

static int checked(op *o, int fd) {
  if (fd < 0 || !private_pipe(o->rt, fd)) return fd;
  close(fd);
  fail_op(o, FS_NOT_REGULAR, 0);
  return -1;
}

static bool same_directory(const struct stat *info, const char *path) {
  struct stat other;
  return stat(path, &other) == 0 && other.st_dev == info->st_dev && other.st_ino == info->st_ino;
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
  struct stat info;
  if (stat(slash ? (len ? copy : "/") : ".", &info) != 0) return false;
  return same_directory(&info, "/proc/self/fd") || same_directory(&info, "/proc/thread-self/fd");
}

static int open_for(op *o, bool reading, bool append) {
  if (o->kind == OP_OPEN_CREATE) {
    /* O_EXCL fails on any existing entry, a dangling link included, and never follows one. */
    int fd = open(o->path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
    if (fd < 0) fail_op(o, FS_OPEN, errno);
    return fd;
  }
  if (names_output_fd(o)) {
    fail_op(o, FS_NOT_REGULAR, 0);
    return -1;
  }
  if (reading) {
    struct stat info;
    if (stat(o->path, &info) != 0 || S_ISDIR(info.st_mode)) {
      fail_op(o, FS_NOT_REGULAR, 0);
      return -1;
    }
    if (o->kind == OP_READ_TEXT) {
      if ((uint64_t)info.st_size > LIMIT) {
        fail_op(o, FS_TOO_BIG, 0);
        return -1;
      }
      o->count = (size_t)info.st_size + 1;
    }
    int fd = open(o->path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
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
  int fd = open(o->path, O_WRONLY | O_CREAT | O_NONBLOCK | O_CLOEXEC | (append ? O_APPEND : O_TRUNC), 0666);
  if (fd < 0) fail_op(o, errno == EISDIR ? FS_IS_DIR : FS_OPEN, errno);
  return checked(o, fd);
}

static bool on_loop(op *o, int fd) {
  bool polled;
  int err = probe(fd, &polled);
  if (err) {
    close(fd);
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
    ssize_t n = read(o->fd, o->out + o->out_len, o->out_cap - o->out_len);
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
  struct stat info;
  if (o->count == 1 && fstat(fd, &info) == 0 && S_ISREG(info.st_mode)) {
    o->fd = fd;
    step_read_text(o);
    o->fd = -1;
    close(fd);
    return;
  }
  o->out = malloc(o->count);
  if (!o->out) {
    fail_op(o, FS_READ, ENOMEM);
  } else if (!read_all(fd, o->out, o->count, &o->out_len, &o->err)) {
    o->status = FS_READ;
  }
  close(fd);
}

static void work_write_text(op *o) {
  int fd = open_for(o, false, o->kind == OP_APPEND_TEXT);
  if (fd < 0 || on_loop(o, fd)) return;
  blocking(fd);
  if (!write_all(fd, o->in, o->in_len, &o->err)) o->status = FS_WRITE;
  close(fd);
}

static void work_stat(op *o) {
  struct stat info;
  if ((o->kind == OP_LSTAT ? lstat(o->path, &info) : stat(o->path, &info)) != 0) {
    fail_op(o, errno == ELOOP ? FS_LINK : FS_MISSING, 0);
    return;
  }
  bool dir = S_ISDIR(info.st_mode);
  o->file_type = dir ? "directory" : S_ISLNK(info.st_mode) ? "link" : "file";
  o->size = dir ? 0 : (int64_t)info.st_size;
  o->mtime = (int64_t)info.st_mtim.tv_sec;
  o->mode = (int64_t)(info.st_mode & 07777);
  o->user_id = (int64_t)info.st_uid;
  o->group_id = (int64_t)info.st_gid;
}

static void work_list(op *o) {
  int fd = open(o->path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0) {
    fail_op(o, FS_OPEN, errno);
    return;
  }
  DIR *dir = fdopendir(fd);
  if (!dir) {
    fail_op(o, FS_OPEN, errno);
    close(fd);
    return;
  }
  for (;;) {
    errno = 0;
    const struct dirent *entry = readdir(dir);
    if (!entry) {
      if (errno) fail_op(o, FS_READ, errno);
      break;
    }
    const char *name = entry->d_name;
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
    size_t len = strlen(name) + 1;
    if (!grow_out(o, len)) {
      fail_op(o, FS_READ, ENOMEM);
      break;
    }
    memcpy(o->out + o->out_len, name, len);
    o->out_len += len;
    o->count++;
  }
  closedir(dir);
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
  struct stat info;
  bool dir = stat(path, &info) == 0 && S_ISDIR(info.st_mode);
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
    int failed = mkdir(o->path, 0777);
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
  int err = 0;
  char *resolved = agc_real_path(o->path, &err);
  if (!resolved) {
    fail_op(o, FS_RESOLVE, err);
    return;
  }
  o->out = (uint8_t *)resolved;
  o->out_len = strlen(resolved);
}

/* Exactly one directory, owner only: an existing path is the caller's error, never a success. */
static void work_mkdir_private(op *o) {
  if (mkdir(o->path, 0700) == 0) return;
  fail_op(o, FS_MKDIR, errno);
  o->fail_at = strlen(o->path);
}

/* Whatever is at the path goes, as rm -rf would remove it but never following a link: unlink takes a file or a link
   itself, and only a directory (EISDIR) starts the tree walk, which opens it with O_NOFOLLOW. A missing path is
   success, as with unlink(missing_ok=True). "file/child" is ENOTDIR and stays an error: a link with a trailing
   slash ("link/") gives the same error and must never report ok. When the walk fails inside the tree, the error
   names the entry that failed, not the root. */
static void work_remove(op *o) {
  int rc;
  do {
    rc = unlink(o->path);
  } while (rc != 0 && errno == EINTR);
  if (rc == 0 || errno == ENOENT) return;
  if (errno != EISDIR) {
    fail_op(o, FS_REMOVE, errno);
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
}

/* flock ties the lock to the open file description, which is the handle's descriptor: closing the handle
   or ending the process releases it, and descriptors are close-on-exec, so no child keeps it. Only a regular
   file locks: a device or a pipe would take the lock too (or fail in ways that say little), and nothing could
   contend for it. LOCK_NB never blocks, so it is never interrupted. */
static void work_try_lock(op *o) {
  struct stat info;
  if (fstat(o->st->fd, &info) != 0) {
    fail_op(o, FS_LOCK, errno);
    return;
  }
  if (!S_ISREG(info.st_mode)) {
    fail_op(o, FS_NOT_LOCKABLE, 0);
    return;
  }
  if (flock(o->st->fd, LOCK_EX | LOCK_NB) == 0)
    o->locked = true;
  else if (errno != EWOULDBLOCK)
    fail_op(o, FS_LOCK, errno);
}

/* One renameat2 with RENAME_NOREPLACE: an existing target is EEXIST and is never overwritten (plain rename
   replaces a file and an empty directory), and a final link is moved as a link, as rename never follows one. A file
   system without RENAME_NOREPLACE answers EINVAL, which is reported, not worked around with a racy check. */
static void work_rename(op *o) {
  if (renameat2(AT_FDCWD, o->path, AT_FDCWD, o->to, RENAME_NOREPLACE) != 0) fail_op(o, FS_RENAME, errno);
}

static void work_open(op *o) {
  int fd = open_for(o, o->kind == OP_OPEN_READ, o->kind == OP_OPEN_APPEND);
  if (fd < 0) return;
  int err = probe(fd, &o->st->polled);
  if (err) {
    close(fd);
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
    ssize_t n = read(st->fd, st->buf + st->end, room);
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
  close(st->fd);
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
  }
}

static void drop(void *data) {
  op *o = data;
  if (o->owns_st && o->st) release_state(o->st);
  if (o->poller)
    agc_poller_close(o->poller);
  else if (o->fd >= 0)
    close(o->fd);
  free_op(o);
}

static bool writes(const op *o) {
  return o->kind != OP_READ_TEXT && o->kind != OP_READ_LINE && o->kind != OP_READ_BYTES && o->kind != OP_READ_BLOCK;
}

static agc_poller *poller_of(const op *o) { return o->st && o->st->poller ? o->st->poller : o->poller; }

static void send_rest(op *o, int fd, const uint8_t *data, size_t len) {
  while (o->sent < len) {
    ssize_t n = write(fd, data + o->sent, len - o->sent);
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

/* The rest of a whole-file call whose path is a pipe, a FIFO or a device:
   its pool work only opened it, and the job now waits on the loop. */
static bool more(void *data, agc_io_job *job) {
  op *o = data;
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
      if (o->kind == OP_READ_TEXT || o->kind == OP_OPEN_READ)
        return os_error(vm, "open-input-file: cannot open input file", o->path, path_len, o->err);
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

static const agc_io_kind close_io = {work, closed, closed, drop, false, "file", NULL};

static const agc_io_kind poll_close_io = {NULL, closed, closed, drop, true, "file", stop};

/* The close of an ended task's file, or of a file still open when the run
   ends: pending while a job holds it. */
static void close_file(agc_vm *vm, agc_resource *r, agc_task *ender) {
  r->closing = true;
  r->next_owner = NULL;
  agc_task_wake_all(vm, &r->waiters, &r->waiters_tail, "close");
  if (!r->native || r->holder) return;
  op *o = new_op(vm, OP_CLOSE);
  o->st = r->native;
  o->owns_st = true;
  r->native = NULL;
  agc_unregister(vm, r);
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
      case OP_LIST: result = list_result(vm, o); break;
      case OP_REAL: result = real_result(o); break;
      case OP_READ_BYTES: result = bytes_result(o); break;
      case OP_TRY_LOCK: result = agc_result_value(true, agc_bool(o->locked)); break;
      case OP_OPEN_READ:
      case OP_OPEN_WRITE:
      case OP_OPEN_CREATE:
      case OP_OPEN_APPEND: {
        int err = 0;
        if (o->st->polled && !(o->st->poller = agc_poller_open(vm, o->st->fd, &err))) {
          fail_op(o, FS_OPEN, err);
          result = common_error(vm, o);
          o->owns_st = true;
          break;
        }
        agc_resource *r = agc_register(vm, o->st, release_state);
        agc_own(vm, r, close_file);
        r->pool_close = true;
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
    agc_unregister(vm, r);
  }
  return error_of(timed_out);
}

static const agc_io_kind file_io = {work, done, expired, drop, false, "file", stop};

static const agc_io_kind poll_io = {NULL, done, expired, drop, true, "file", stop};

static void files_on(agc_vm *vm, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-INTERNAL", "file access is off in this run", span);
}

static agc_value start(agc_vm *vm, op *o, agc_value context, int64_t timeout) {
  o->vm = vm;
  if (!o->st || !o->st->poller) {
    agc_io_start_then(vm, &file_io, o, context, timeout, more);
    return agc_void();
  }
  if (step(o)) return done(vm, o, context);
  o->job = agc_io_start(vm, &poll_io, o, context, timeout);
  agc_poller_wait(o->st->poller, writes(o), ready, o);
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
  files_on(vm, span);
  return path_op(vm, OP_READ_TEXT, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), complete_who,
                 complete_expected);
}

static agc_value write_text(agc_vm *vm, agc_value *args, uint32_t span, op_kind kind) {
  files_on(vm, span);
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
  files_on(vm, span);
  return path_op(vm, OP_STAT, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), complete_who, complete_expected);
}

static agc_value builtin_lstat(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  return path_op(vm, OP_LSTAT, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), complete_who, complete_expected);
}

static agc_value builtin_dir_list(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  return path_op(vm, OP_LIST, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), "directory-list", "path-string?");
}

static agc_value builtin_dir_mkdir(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  return path_op(vm, OP_MKDIR, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), "make-directory*",
                 "path-string?");
}

static agc_value builtin_dir_mkdir_private(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  return path_op(vm, OP_MKDIR_PRIVATE, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), "make-directory",
                 "path-string?");
}

static agc_value builtin_remove(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  return path_op(vm, OP_REMOVE, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), "delete-directory/files",
                 "path-string?");
}

static agc_value builtin_rename(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
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
  agc_unregister(vm, r);
  return start(vm, o, handle, timeout);
}

static agc_value builtin_open(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
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
  files_on(vm, span);
  int64_t count = agc_as_int(vm, args[1]);
  if (count < 1 || (uint64_t)count > LIMIT) return error_of("filesystem: max_bytes must be between 1 and 1048576");
  return read_op(vm, args[0], OP_READ_BYTES, (size_t)count, agc_as_int(vm, args[2]));
}

static agc_value builtin_read_line(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  return read_op(vm, args[0], OP_READ_LINE, 0, agc_as_int(vm, args[1]));
}

static agc_value write_out(agc_vm *vm, agc_value handle, file_state *st, const uint8_t *data, size_t len,
                           int64_t timeout) {
  op *o = new_op(vm, OP_WRITE);
  o->st = st;
  o->in_len = st->end + len;
  o->in = malloc(o->in_len ? o->in_len : 1);
  if (!o->in) agc_out_of_memory();
  if (st->end) memcpy(o->in, st->buf, st->end);
  if (len) memcpy(o->in + st->end, data, len);
  st->end = 0;
  return start(vm, o, handle, timeout);
}

static agc_value write_bytes(agc_vm *vm, agc_value handle, const uint8_t *data, size_t len, int64_t timeout) {
  agc_value failure;
  if (blocked(vm, handle, &timeout, &failure)) return failure;
  file_state *st = usable(vm, handle, false, &failure);
  if (!st) return failure;
  if (st->end + len > WRITE_BUFFER) return write_out(vm, handle, st, data, len, timeout);
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
  files_on(vm, span);
  const agc_string *content = agc_as_string(vm, args[1]);
  if (content->bytes > LIMIT) return error_of("filesystem: text exceeds 1048576 bytes");
  return write_bytes(vm, args[0], (const uint8_t *)content->data, content->bytes, agc_as_int(vm, args[2]));
}

static agc_value builtin_write_list(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  const agc_list *values = agc_as_list(vm, args[1]);
  const uint8_t *data = agc_byte_list(vm, values, LIMIT);
  if (!data) return error_of("network: bytes must be 0..255 and at most 1048576 per call");
  return write_bytes(vm, args[0], data, agc_list_len(values), agc_as_int(vm, args[2]));
}

static agc_value builtin_flush(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  agc_value failure;
  int64_t timeout = agc_as_int(vm, args[1]);
  if (blocked(vm, args[0], &timeout, &failure)) return failure;
  file_state *st = usable(vm, args[0], false, &failure);
  if (!st) return failure;
  if (!st->end) return ok_void();
  return write_out(vm, args[0], st, NULL, 0, timeout);
}

static agc_value builtin_close(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  agc_resource *r = agc_as_handle(vm, args[0]);
  int64_t timeout = agc_as_int(vm, args[1]);
  agc_value failure;
  if (blocked(vm, args[0], &timeout, &failure)) return failure;
  if (r->closing) return agc_is(r->context, AGC_T_RESULT) ? r->context : ok_void();
  if (!r->native) return ok_void();
  return close_handle(vm, r, args[0], timeout);
}

static agc_value builtin_try_lock(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
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

static agc_step lines_wait(void) { return (agc_step){AGC_STEP_WAIT, agc_void()}; }

static agc_step lines_end(agc_value result) { return (agc_step){AGC_STEP_END, result}; }

static file_state *lines_file(agc_vm *vm, const lines *s) {
  const agc_resource *r = agc_as_handle(vm, s->handle);
  return r->closing ? NULL : r->native;
}

static bool lines_take(agc_vm *vm, lines *s, file_state *st, size_t len, size_t consume, agc_value *line) {
  const uint8_t *data = st->buf + st->start;
  size_t chars;
  agc_charge_bytes(vm, consume);
  bool valid = agc_utf8_chars(data, len, &chars);
  if (valid)
    *line = agc_string_value(agc_small_string(vm, (const char *)data, len, chars));
  else
    s->outcome = agc_utf8_error(data, len);
  st->start += consume;
  st->scan = 0;
  return valid;
}

static agc_step lines_step(agc_vm *vm, agc_stepper *self, agc_value last) {
  lines *s = (lines *)self;
  for (;;) {
    switch (s->phase) {
      case LINES_START:
        s->phase = LINES_OPENED;
        last = start(vm, open_op(vm, OP_OPEN_READ, agc_as_string(vm, s->path)), agc_void(), s->timeout);
        if (vm->task->parking) return lines_wait();
        break;
      case LINES_OPENED: {
        const agc_result *opened = agc_as_result(vm, last);
        if (!opened->ok) return lines_end(last);
        s->handle = opened->value;
        s->phase = LINES_SCAN;
        break;
      }
      case LINES_SCAN: {
        file_state *st = lines_file(vm, s);
        if (!st) return lines_end(error_of("filesystem: file handle is closed"));
        line_scan found = scan_line(st, st->scan, s->limit, s->limit, st->eof);
        if (found.kind == LINE_MORE) {
          st->scan = found.scanned;
          op *o = new_op(vm, OP_READ_BLOCK);
          o->st = st;
          o->count = s->limit;
          s->phase = LINES_RESUME;
          last = start(vm, o, s->handle, s->timeout);
          if (vm->task->parking) return lines_wait();
          break;
        }
        s->phase = LINES_CLOSE;
        if (found.kind == LINE_LONG) {
          s->outcome = error_of(line_too_long);
        } else if (found.kind == LINE_END) {
          s->outcome = ok_void();
        } else {
          agc_value line = agc_void();
          if (lines_take(vm, s, st, found.len, found.consume, &line)) {
            s->phase = LINES_RESUME;
            return (agc_step){AGC_STEP_CALL, line};
          }
        }
        break;
      }
      case LINES_RESUME:
        s->phase = LINES_SCAN;
        if (!agc_as_result(vm, last)->ok) {
          s->outcome = last;
          s->phase = LINES_CLOSE;
        }
        break;
      case LINES_CLOSE: {
        agc_resource *r = agc_as_handle(vm, s->handle);
        if (!r->native || r->closing) return lines_end(s->outcome);
        s->phase = LINES_CLOSED;
        last = close_handle(vm, r, s->handle, s->timeout);
        if (vm->task->parking) return lines_wait();
        break;
      }
      case LINES_CLOSED: return lines_end(s->outcome);
    }
  }
}

static agc_value builtin_each_line(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  const agc_string *path = agc_as_string(vm, args[0]);
  int64_t limit = agc_as_int(vm, args[1]);
  int64_t timeout = agc_as_int(vm, args[2]);
  if (limit < MIN_LINE_BUFFER || limit > MAX_LINE_BUFFER)
    agc_fail(vm, "RUNTIME-INVALID-COUNT", "buffer_bytes must be between 1024 and 16777216", span + 2);
  if (timeout <= 0) return error_of(bad_timeout);
  if (!path_string(path)) return contract_error(complete_who, complete_expected, path);
  lines *s = agc_alloc(sizeof(lines));
  s->stepper.step = lines_step;
  s->path = args[0];
  s->handle = agc_void();
  s->outcome = ok_void();
  s->limit = (size_t)limit;
  s->timeout = timeout;
  agc_task_stepper(vm, &s->stepper);
  return agc_void();
}

static agc_value builtin_real(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  const agc_string *path = agc_as_string(vm, args[0]);
  if (!path_string(path)) return contract_error(complete_who, complete_expected, path);
  op *o = new_op(vm, OP_REAL);
  o->path = agc_host_path(vm, path);
  return start(vm, o, agc_void(), NO_DEADLINE);
}

static agc_value builtin_cwd(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  files_on(vm, span);
  const agc_string *cwd = cwd_of(vm);
  return agc_result_value(true, agc_string_value(lossy(cwd->data, cwd->bytes)));
}

static bool collapse_leading(const text *t) {
  if (t->len < 3 || t->data[0] != '/' || t->data[1] != '/' || t->data[2] == '/') return false;
  for (size_t k = 3; k < t->len; k++)
    if (t->data[k] == '/') return k + 1 == t->len || t->data[k + 1] != '/';
  return true;
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
    if (part->data[0] == '/') {
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
      if (t.data[t.len - 1] != '/') puts_text(&t, "/");
    }
    put(&t, part->data, part->bytes);
  }
  return agc_result_value(true, agc_string_value(lossy(t.data, t.len)));
}

static agc_value builtin_resolve(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  const agc_string *path = agc_as_string(vm, args[0]);
  if (!path_string(path)) return contract_error(complete_who, complete_expected, path);
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
}

const agc_builtin agc_file_builtins[] = {
  {"File.open", 3, builtin_open, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.read_bytes", 3, builtin_read_bytes, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.read_line", 2, builtin_read_line, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.write", 3, builtin_write, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.write_bytes", 3, builtin_write_list, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.flush", 2, builtin_flush, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.close", 2, builtin_close, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.each_line", 4, builtin_each_line, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.read_text", 2, builtin_read_text, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.write_text", 3, builtin_write_text, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.append_text", 3, builtin_append_text, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.stat", 2, builtin_stat, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.lstat", 2, builtin_lstat, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.try_lock", 2, builtin_try_lock, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Dir.list", 2, builtin_dir_list, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Dir.mkdir", 2, builtin_dir_mkdir, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Dir.mkdir_private", 2, builtin_dir_mkdir_private, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Path.cwd", 0, builtin_cwd, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Path.join", 1, builtin_join, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"Path.resolve", 1, builtin_resolve, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Path.real", 1, builtin_real, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Path.remove", 2, builtin_remove, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Path.rename", 3, builtin_rename, AGC_NATIVE_NONE, AGC_COST_NONE},
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

const agc_builtin agc_file_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE}};

const size_t agc_file_builtin_count = 0;
#endif

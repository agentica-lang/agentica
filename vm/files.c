#include "agc.h"

#ifdef __linux__
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define LIMIT ((size_t)1048576)
#define FORM_WIDTH 256
#define CHUNK ((size_t)65536)
#define WRITE_BUFFER ((size_t)4096)

typedef enum {
  FS_OK, FS_NOT_REGULAR, FS_TOO_BIG, FS_OPEN, FS_IS_DIR, FS_READ, FS_WRITE, FS_MISSING, FS_LINK, FS_EOF, FS_LONG_LINE,
  FS_MKDIR
} fs_status;

typedef enum {
  OP_READ_TEXT, OP_WRITE_TEXT, OP_APPEND_TEXT, OP_STAT, OP_LIST, OP_MKDIR, OP_OPEN_READ, OP_OPEN_WRITE,
  OP_OPEN_APPEND, OP_READ_BYTES, OP_READ_LINE, OP_WRITE, OP_CLOSE
} op_kind;

typedef struct {
  int fd;
  bool readable, writable;
  uint8_t *buf;
  size_t start, end, cap;
} file_state;

typedef struct {
  op_kind kind;
  char *path;
  file_state *st;
  uint8_t *in;
  size_t in_len;
  uint8_t *out;
  size_t out_len, out_cap, count, fail_at;
  fs_status status;
  int err;
  bool dir, owns_st;
  int64_t size, mtime;
} op;

typedef struct {
  char *data;
  size_t len, cap;
} text;

static const char not_regular[] = "filesystem: path does not refer to a regular file";
static const char timed_out[] = "filesystem: operation timed out";
static const char bad_timeout[] = "network: timeout must be positive milliseconds";
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

static op *new_op(op_kind kind) {
  op *o = calloc(1, sizeof(op));
  if (!o) agc_out_of_memory();
  o->kind = kind;
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
  if (st->fd >= 0) close(st->fd);
  free(st->buf);
  free(st);
}

static void free_op(op *o) {
  free(o->path);
  free(o->in);
  free(o->out);
  free(o);
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

static int open_for(op *o, bool reading, bool append) {
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
    return fd;
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
  return fd;
}

static void work_read_text(op *o) {
  int fd = open_for(o, true, false);
  if (fd < 0) return;
  blocking(fd);
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
  if (fd < 0) return;
  blocking(fd);
  if (!write_all(fd, o->in, o->in_len, &o->err)) o->status = FS_WRITE;
  close(fd);
}

static void work_stat(op *o) {
  struct stat info;
  if (stat(o->path, &info) != 0) {
    fail_op(o, errno == ELOOP ? FS_LINK : FS_MISSING, 0);
    return;
  }
  o->dir = S_ISDIR(info.st_mode);
  o->size = o->dir ? 0 : (int64_t)info.st_size;
  o->mtime = (int64_t)info.st_mtim.tv_sec;
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

static void work_open(op *o) {
  int fd = open_for(o, o->kind == OP_OPEN_READ, o->kind == OP_OPEN_APPEND);
  if (fd < 0) return;
  blocking(fd);
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

static bool fill(file_state *st, int *err, bool *eof) {
  if (st->start) {
    memmove(st->buf, st->buf + st->start, pending(st));
    st->end -= st->start;
    st->start = 0;
  }
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
  for (;;) {
    ssize_t n = read(st->fd, st->buf + st->end, st->cap - st->end);
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

static void work_read_line(op *o) {
  file_state *st = o->st;
  bool eof = false;
  for (;;) {
    size_t have = pending(st);
    size_t window = have < LIMIT + 1 ? have : LIMIT + 1;
    const uint8_t *lf = window ? memchr(st->buf + st->start, '\n', window) : NULL;
    if (lf) {
      size_t len = (size_t)(lf - (st->buf + st->start));
      size_t keep = len && st->buf[st->start + len - 1] == '\r' ? len - 1 : len;
      take_line(o, keep, len + 1);
      return;
    }
    if (have > LIMIT) {
      st->start += LIMIT + 1;
      fail_op(o, FS_LONG_LINE, 0);
      return;
    }
    if (eof) {
      if (have == 0) {
        fail_op(o, FS_EOF, 0);
        return;
      }
      take_line(o, have, have);
      return;
    }
    if (!fill(st, &o->err, &eof)) {
      o->status = FS_READ;
      return;
    }
  }
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
    case OP_STAT: work_stat(o); break;
    case OP_LIST: work_list(o); break;
    case OP_MKDIR: work_mkdir(o); break;
    case OP_OPEN_READ:
    case OP_OPEN_WRITE:
    case OP_OPEN_APPEND: work_open(o); break;
    case OP_READ_BYTES: work_read_bytes(o); break;
    case OP_READ_LINE: work_read_line(o); break;
    case OP_WRITE: work_write(o); break;
    case OP_CLOSE: work_close(o); break;
  }
}

static void drop(void *data) {
  op *o = data;
  if (o->owns_st) free_state(o->st);
  free_op(o);
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
  static const char *const fields[] = {"kind", "size_bytes", "modified_seconds"};
  return agc_builtin_struct(vm, "FileInfo", fields, 3);
}

static agc_value stat_result(agc_vm *vm, const op *o) {
  agc_struct *info = agc_new_struct(file_info_struct(vm), 3);
  const char *kind = o->dir ? "directory" : "file";
  info->fields[0] = agc_string_value(agc_make_string(kind, strlen(kind), strlen(kind)));
  info->fields[1] = agc_int(o->size);
  info->fields[2] = agc_int(o->mtime);
  return agc_result_value(true, agc_struct_value(info));
}

static agc_value list_result(agc_vm *vm, const op *o) {
  agc_list *names = agc_new_list(o->count);
  size_t at = 0;
  for (size_t k = 0; k < o->count; k++) {
    size_t len = strlen((const char *)o->out + at);
    names->items[k] = agc_string_value(lossy(o->out + at, len));
    at += len + 1;
  }
  return agc_result_value(true, agc_sort_by_keys(vm, names, names));
}

static agc_value bytes_result(const op *o) {
  agc_list *l = agc_new_list(o->out_len);
  for (size_t k = 0; k < o->out_len; k++) l->items[k] = agc_int(o->out[k]);
  return agc_result_value(true, agc_list_value(l));
}

static agc_value closed(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)context;
  drop(data);
  return agc_void();
}

static const agc_io_kind close_io = {work, closed, closed, drop, false, "file", NULL};

/* The close of a crashed task's file: pending while a job holds it. */
static void close_file(agc_vm *vm, agc_resource *r) {
  r->closing = true;
  r->next_owner = NULL;
  agc_task_wake_all(vm, &r->waiters, &r->waiters_tail, "close");
  if (!r->native || r->holder) return;
  op *o = new_op(OP_CLOSE);
  o->st = r->native;
  o->owns_st = true;
  r->native = NULL;
  agc_unregister(vm, r);
  agc_io_detached(vm, &close_io, o);
}

static agc_value done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  op *o = data;
  if (o->kind == OP_STAT && o->status == FS_OK) {
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
      case OP_READ_BYTES: result = bytes_result(o); break;
      case OP_OPEN_READ:
      case OP_OPEN_WRITE:
      case OP_OPEN_APPEND: {
        agc_resource *r = agc_register(vm, o->st, release_state);
        agc_own(vm, r, close_file);
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
  if (agc_is(context, AGC_T_HANDLE)) {
    o->owns_st = true;
    agc_resource *r = agc_as_handle(vm, context);
    r->native = NULL;
    agc_unregister(vm, r);
  }
  return error_of(timed_out);
}

static const agc_io_kind file_io = {work, done, expired, drop, false, "file", NULL};

static void files_on(agc_vm *vm, uint32_t span) {
  if (vm->rt->no_files) agc_fail(vm, "RUNTIME-INTERNAL", "file access is off in this run", span);
}

static agc_value start(agc_vm *vm, op *o, agc_value context, int64_t timeout) {
  agc_io_start(vm, &file_io, o, context, timeout);
  return agc_void();
}

static agc_value path_op(agc_vm *vm, op_kind kind, const agc_string *path, int64_t timeout, const char *who,
                         const char *expected) {
  if (timeout <= 0) return error_of(bad_timeout);
  if (!path_string(path)) return contract_error(who, expected, path);
  op *o = new_op(kind);
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
  op *o = new_op(kind);
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

static agc_value builtin_dir_list(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  return path_op(vm, OP_LIST, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), "directory-list", "path-string?");
}

static agc_value builtin_dir_mkdir(agc_vm *vm, agc_value *args, uint32_t span) {
  files_on(vm, span);
  return path_op(vm, OP_MKDIR, agc_as_string(vm, args[0]), agc_as_int(vm, args[1]), "make-directory*",
                 "path-string?");
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
  } else {
    return error_of("filesystem: mode must be read, write, or append");
  }
  if (!path_string(path)) return contract_error(complete_who, complete_expected, path);
  op *o = new_op(kind);
  o->path = agc_host_path(vm, path);
  o->st = new_state(kind == OP_OPEN_READ, kind != OP_OPEN_READ);
  o->owns_st = true;
  return start(vm, o, agc_void(), timeout);
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

static file_state *usable(agc_vm *vm, agc_value handle, bool reading, agc_value *failure) {
  const agc_resource *r = agc_as_handle(vm, handle);
  file_state *st = r->native;
  if (!st || r->closing) {
    *failure = error_of("filesystem: file handle is closed");
  } else if (reading && !st->readable) {
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
  op *o = new_op(kind);
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
  op *o = new_op(OP_WRITE);
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
  return write_bytes(vm, args[0], data, values->len, agc_as_int(vm, args[2]));
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
  if (!r->native || r->closing) return ok_void();
  op *o = new_op(OP_CLOSE);
  o->st = r->native;
  o->owns_st = true;
  r->native = NULL;
  agc_unregister(vm, r);
  return start(vm, o, args[0], timeout);
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
  if (parts->len == 0) return error_of("filesystem: Path.join needs at least one part");
  for (size_t k = 0; k < parts->len; k++) {
    const agc_string *part = agc_as_string(vm, parts->items[k]);
    if (!path_string(part))
      return contract_error("build-path", "(or/c path-string? path-for-some-system? 'up 'same)", part);
  }
  for (size_t k = 1; k < parts->len; k++) {
    const agc_string *part = agc_as_string(vm, parts->items[k]);
    if (part->data[0] == '/') {
      text t = {0};
      puts_text(&t, "build-path: absolute path cannot be added to a path\n  absolute path: ");
      put_form(&t, part);
      return error_text(&t);
    }
  }
  text t = {0};
  for (size_t k = 0; k < parts->len; k++) {
    const agc_string *part = agc_as_string(vm, parts->items[k]);
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
  {"File.read_text", 2, builtin_read_text, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.write_text", 3, builtin_write_text, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.append_text", 3, builtin_append_text, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"File.stat", 2, builtin_stat, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Dir.list", 2, builtin_dir_list, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Dir.mkdir", 2, builtin_dir_mkdir, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Path.cwd", 0, builtin_cwd, AGC_NATIVE_NONE, AGC_COST_NONE},
  {"Path.join", 1, builtin_join, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"Path.resolve", 1, builtin_resolve, AGC_NATIVE_NONE, AGC_COST_NONE},
};

const size_t agc_file_builtin_count = sizeof agc_file_builtins / sizeof agc_file_builtins[0];
#else
void agc_files_init(agc_vm *vm) { (void)vm; }

void agc_files_close(agc_vm *vm) { (void)vm; }

const agc_builtin agc_file_builtins[] = {{"", 0, NULL, AGC_NATIVE_NONE, AGC_COST_NONE}};

const size_t agc_file_builtin_count = 0;
#endif

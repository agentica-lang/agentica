/*
 * The Windows side of the standard output and error streams. vm/output.c owns the ring, the queue of writers and the
 * notices; this file decides how a handle is written (a file or a console by a pool thread, a pipe by a libuv stream),
 * whether two descriptors are one target, does the writes, makes the in-memory stream of a notice, reads stdin on a
 * thread of its own, and at the exit shuts down the sending side of a socket. The Linux and macOS side is
 * vm/stdio_posix.c. Core layer. Design: docs/vm/10-io-scheduler.md §10.2.2.
 */
#ifdef _WIN32
#include "core.h"

#include <errno.h>
#include <fcntl.h>
#include <io.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>
#include <windows.h>
#include <winternl.h>

/* The most that one WriteConsoleW call takes, in UTF-16 units, as libuv's own console writer uses (older Windows fails
   for a larger one). A byte of UTF-8 makes at most one unit, so a slice of that many bytes always fits. */
#define CONSOLE_UNITS 8192
/* How many times the close of the stdin reader tries to cancel a read that has not ended. The tries are uv_sleep(1)
   apart, which is Sleep(1): about one timer tick (some 15.6 ms), so the close waits at most about 150 ms. */
#define CANCEL_TRIES 10

/* A pipe that libuv writes, one request at a time. libuv writes a pipe that was not opened for overlapped I/O on a
   Windows worker thread and an overlapped one with I/O completion ports; no write waits for a reader on the loop. */
typedef struct {
  union {
    uv_handle_t handle;
    uv_stream_t stream;
    uv_pipe_t pipe;
  } io;
  uv_write_t req;
  void (*done)(void *data, int status);
  void *data;
} pipe_stream;

typedef BOOL(WINAPI *compare_handles_fn)(HANDLE first, HANDLE second);

struct agc_stdio {
  pipe_stream *stream;
  bool socket;
};

/* Windows has no open_memstream: a thread reads the other end of a pipe into memory as it is written. */
struct agc_memstream {
  HANDLE read;
  uv_thread_t thread;
  char *text;
  size_t len, cap;
  bool lost;
};

/* The stdin reader. The loop side (the async handle, `job`, `buf` and the start) is used on the I/O thread; the thread
   waits for `want`, reads into `buf` with `lock` released (`in_read` while it is in _read), and wakes the loop unless
   `closed`. `buf` grows to the largest read asked for and is kept for the whole run; the done half of a read takes it
   while the thread waits for the next `want`. The thread and the loop side each hold a reference: the thread may stay
   in a read after the close, until input or EOF comes. A handle that is not overlapped serializes its I/O, so while
   the thread is in a read of a socket that is also stdout (inetd), the writes of stdout wait for that read.
   A console is read as UTF-16 (ReadConsoleW) into `units` and handed on as UTF-8: `high` keeps a high surrogate whose
   low half is still in the console, and `spill` the UTF-8 bytes of a console read that did not fit the room asked for.
   Only the thread uses them. */
struct agc_stdin_reader {
  uv_async_t wake;
  uv_mutex_t lock;
  uv_cond_t asked;
  uv_thread_t thread;
  int fd;
  bool started, want, in_read, closed;
  agc_loop *loop;
  agc_io_job *job;
  size_t room, cap;
  int64_t got;
  uint8_t *buf;
  wchar_t high, *units;
  size_t units_cap;
  uint8_t *spill;
  size_t spill_at, spill_len, spill_cap;
  atomic_int refs;
};

/* How many of the N bytes at DATA end at a character boundary: a UTF-8 sequence cut by the end is left out. */
static size_t whole_characters(const uint8_t *data, size_t n) {
  for (size_t back = 1; back <= 3 && back <= n; back++) {
    uint8_t byte = data[n - back];
    if ((byte & 0xC0) == 0x80) continue;
    size_t need = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1;
    return need > back ? n - back : n;
  }
  return n;
}

/* A console takes UTF-16 whatever its code page is, so WriteConsoleW writes it and the pool thread converts. The bytes
   of a character that DATA cuts off wait in CUT for the next write; the call counts them as written. Returns N, or -1
   with errno. */
static ssize_t console_write(HANDLE console, const uint8_t *data, size_t n, agc_utf8_cut *cut) {
  size_t total = cut->length + n;
  uint8_t *joined = malloc(total ? total : 1);
  if (!joined) {
    errno = ENOMEM;
    return -1;
  }
  memcpy(joined, cut->bytes, cut->length);
  memcpy(joined + cut->length, data, n);
  size_t whole = whole_characters(joined, total);
  bool failed = false;
  wchar_t units[CONSOLE_UNITS];
  for (size_t at = 0; at < whole && !failed;) {
    size_t take = whole - at < CONSOLE_UNITS ? whole - at : CONSOLE_UNITS;
    while (take > 1 && at + take < whole && (joined[at + take] & 0xC0) == 0x80) take--;
    int count = MultiByteToWideChar(CP_UTF8, 0, (const char *)joined + at, (int)take, units, CONSOLE_UNITS);
    for (int sent = 0; sent < count && !failed;) {
      DWORD done = 0;
      if (!WriteConsoleW(console, units + sent, (DWORD)(count - sent), &done, NULL) || done == 0)
        failed = true;
      else
        sent += (int)done;
    }
    at += take;
  }
  cut->length = total - whole;
  memcpy(cut->bytes, joined + whole, cut->length);
  free(joined);
  if (failed) errno = EIO;
  return failed ? -1 : (ssize_t)n;
}

ssize_t agc_stdio_write(int fd, const uint8_t *data, size_t n, agc_utf8_cut *cut) {
  DWORD mode;
  HANDLE handle = (HANDLE)_get_osfhandle(fd);
  if (handle != INVALID_HANDLE_VALUE && GetConsoleMode(handle, &mode)) return console_write(handle, data, n, cut);
  return _write(fd, data, (unsigned)n);
}

static void pipe_closed(uv_handle_t *handle) { free(handle->data); }

static void pipe_written(uv_write_t *req, int status) {
  pipe_stream *w = (pipe_stream *)((char *)req - offsetof(pipe_stream, req));
  if (w->done) w->done(w->data, status);
}

/* libuv closes a descriptor above 2 when its handle closes, and copies one of 0 to 2. The handle gets a private copy
   either way, so the process's own stream and the descriptors of its tests stay open. NULL when libuv does not take
   the handle (a socket, a pipe nobody can write to). */
static pipe_stream *pipe_open(agc_vm *vm, int fd) {
  int own = _dup(fd);
  if (own < 0) return NULL;
  /* _dup makes an inheritable handle, and a child process must not keep our copy of the pipe open. */
  SetHandleInformation((HANDLE)_get_osfhandle(own), HANDLE_FLAG_INHERIT, 0);
  pipe_stream *w = calloc(1, sizeof *w);
  if (!w) agc_out_of_memory();
  if (uv_pipe_init(agc_io_uv(vm), &w->io.pipe, 0) != 0) {
    free(w);
    _close(own);
    return NULL;
  }
  w->io.handle.data = w;
  if (uv_pipe_open(&w->io.pipe, own) != 0) {
    uv_close(&w->io.handle, pipe_closed);
    _close(own);
    return NULL;
  }
  if (own <= 2) _close(own);
  if (!uv_is_writable(&w->io.stream)) {
    uv_close(&w->io.handle, pipe_closed);
    return NULL;
  }
  return w;
}

/* Cancels a request in flight and forgets its callback: the owner may free what the request pointed to. Closing the
   handle does not cancel the request while another handle to the same pipe stays open (the process's own stdout does),
   so it is cancelled by name, and the close finishes when libuv has seen the request end. The ring that the request
   reads is not freed meanwhile: output.c keeps it while a request is held (close_stream). */
static void pipe_close(pipe_stream *w) {
  uv_os_fd_t os = INVALID_HANDLE_VALUE;
  w->done = NULL;
  w->data = NULL;
  if (uv_fileno(&w->io.handle, &os) == 0) CancelIoEx((HANDLE)os, NULL);
  uv_close(&w->io.handle, pipe_closed);
}

/* Asked when the stream opens, while no write of ours is in flight: on a handle that is not overlapped, a query waits
   for a write that is. libuv has started Winsock with the loop. */
static bool is_socket(int fd) {
  int type = 0, length = (int)sizeof type;
  return getsockopt((SOCKET)_get_osfhandle(fd), SOL_SOCKET, SO_TYPE, (char *)&type, &length) == 0;
}

bool agc_stdio_open(agc_vm *vm, agc_output *out, int fd) {
  pipe_stream *stream = NULL;
  bool on_socket = false;
  agc_write_mode mode;
  switch (uv_guess_handle(fd)) {
    case UV_FILE: mode = AGC_WRITE_DISK; break;
    /* A console is written by a pool thread, not by uv_tty_t: libuv's console write runs on the loop thread, and a
       console that is paused (a selection, Ctrl+S) would stop every task and the stop signals. */
    case UV_TTY: mode = AGC_WRITE_THREAD; break;
    case UV_NAMED_PIPE:
      stream = pipe_open(vm, fd);
      /* A handle that libuv refuses is still written off the loop, by a pool thread that may wait for the reader. */
      mode = stream ? AGC_WRITE_STREAM : AGC_WRITE_THREAD;
      on_socket = !stream && is_socket(fd);
      break;
    default: return false;
  }
  agc_stdio *io = calloc(1, sizeof *io);
  if (!io) agc_out_of_memory();
  io->stream = stream;
  io->socket = on_socket;
  out->fd = fd;
  out->io = io;
  out->mode = mode;
  return true;
}

/* stdout and stderr given as one pipe, file or console (2>&1) are two handles to one kernel object, which is what
   CompareObjectHandles asks (Windows 10 and later). Two separate opens of one file are two objects, so unlike Unix
   (device and inode) they count as two targets; without the function every pair does. */
static bool same_object(HANDLE a, HANDLE b) {
  if (a == INVALID_HANDLE_VALUE || b == INVALID_HANDLE_VALUE) return false;
  if (a == b) return true;
  /* NULL is no handle, and -2 is the CRT's mark of a descriptor that has none. */
  if (!a || !b || a == (HANDLE)-2 || b == (HANDLE)-2) return false;
  HMODULE base = GetModuleHandleW(L"kernelbase.dll");
  FARPROC found = base ? GetProcAddress(base, "CompareObjectHandles") : NULL;
  if (!found) return false;
  compare_handles_fn compare = (compare_handles_fn)(void (*)(void))found;
  return compare(a, b) != FALSE;
}

bool agc_stdio_same(const agc_output *first, int fd) {
  return same_object((HANDLE)_get_osfhandle(first->fd), (HANDLE)_get_osfhandle(fd));
}

/* The standard handle of FD 0, 1 or 2, from the process (not the CRT, whose lookup of a closed descriptor calls the
   invalid parameter handler). */
static HANDLE std_handle(int fd) {
  return GetStdHandle(fd == 0 ? STD_INPUT_HANDLE : fd == 1 ? STD_OUTPUT_HANDLE : STD_ERROR_HANDLE);
}

/* Windows resets a socket whose last handle closes with the process, and its reader loses what it has not read yet.
   After shutdown the bytes already sent stay readable and then the reader sees the end; shutdown does not wait for the
   reader. A socket that another process still holds (a parent, a child, a second writer) is left open for it: it is
   shut down only when this process's stdin, stdout and stderr handles are all the handles to it. Two of them are
   counted as one socket through CompareObjectHandles, which Windows 10 before 1607 lacks: there a socket given as two
   standard streams is left open (and reset). A socket that is also stdin (inetd) is shut down only while the stdin
   reader is not in a read of it, under the reader's lock: on a handle that is not overlapped, shutdown would wait for
   that read. */
void agc_stdio_end(agc_output *out, agc_input *in) {
  if (!out->io->socket) return;
  HANDLE handle = (HANDLE)_get_osfhandle(out->fd);
  ULONG ours = 1;
  bool is_stdin = false;
  for (int fd = 0; fd <= 2; fd++) {
    if (fd == out->fd) continue;
    HANDLE other = std_handle(fd);
    if (!same_object(handle, other)) continue;
    if (other != handle) ours++;
    if (fd == 0) is_stdin = true;
  }
  PUBLIC_OBJECT_BASIC_INFORMATION info;
  if (NtQueryObject(handle, ObjectBasicInformation, &info, sizeof info, NULL) != 0 || info.HandleCount > ours) return;
  agc_stdin_reader *r = is_stdin ? in->reader : NULL;
  if (r) uv_mutex_lock(&r->lock);
  if (!r || !r->in_read) (void)shutdown((SOCKET)handle, SD_SEND);
  if (r) uv_mutex_unlock(&r->lock);
}

bool agc_stdio_try_first(const agc_output *s) {
  (void)s;
  return false;
}

ssize_t agc_stdio_try(agc_output *s, const uint8_t *data, size_t n) { return _write(s->fd, data, (unsigned)n); }

/* Writes the bytes of two ranges (a ring that wrapped) as one request. They must stay unchanged until done runs, with
   the status of libuv: 0 when all went out. done also runs at once when libuv refuses the request. */
void agc_stdio_start(agc_output *s, const uint8_t *first, size_t first_len, const uint8_t *second, size_t second_len,
                     void (*done)(void *data, int status), void *data) {
  pipe_stream *w = s->io->stream;
  uv_buf_t bufs[2];
  unsigned count = 0;
  if (first_len) bufs[count++] = uv_buf_init((char *)(uintptr_t)first, (unsigned)first_len);
  if (second_len) bufs[count++] = uv_buf_init((char *)(uintptr_t)second, (unsigned)second_len);
  w->done = done;
  w->data = data;
  int rc = uv_write(&w->req, &w->io.stream, bufs, count, pipe_written);
  if (rc != 0) done(data, rc);
}

void agc_stdio_close(agc_stdio *io) {
  if (io->stream) pipe_close(io->stream);
  free(io);
}

static void memstream_collect(void *data) {
  agc_memstream *c = data;
  char sink[4096];
  for (;;) {
    DWORD got = 0;
    if (!c->lost && c->len == c->cap) {
      size_t cap = c->cap ? c->cap * 2 : 4096;
      char *grown = realloc(c->text, cap);
      if (grown) {
        c->text = grown;
        c->cap = cap;
      } else {
        c->lost = true;
      }
    }
    char *into = c->lost ? sink : c->text + c->len;
    DWORD room = c->lost ? (DWORD)sizeof sink : (DWORD)(c->cap - c->len);
    if (!ReadFile(c->read, into, room, &got, NULL) || got == 0) return;
    if (!c->lost) c->len += got;
  }
}

FILE *agc_memstream_open(agc_memstream **ms) {
  agc_memstream *c = calloc(1, sizeof *c);
  if (!c) return NULL;
  HANDLE write;
  if (!CreatePipe(&c->read, &write, NULL, 0)) {
    free(c);
    return NULL;
  }
  int fd = _open_osfhandle((intptr_t)write, _O_WRONLY | _O_BINARY | _O_NOINHERIT);
  FILE *file = fd < 0 ? NULL : _fdopen(fd, "wb");
  if (!file || uv_thread_create(&c->thread, memstream_collect, c) != 0) {
    if (file) {
      fclose(file);
    } else if (fd >= 0) {
      _close(fd);
    } else {
      CloseHandle(write);
    }
    CloseHandle(c->read);
    free(c);
    return NULL;
  }
  *ms = c;
  return file;
}

bool agc_memstream_take(FILE *file, agc_memstream *c, char **text, size_t *len) {
  bool ok = fclose(file) == 0;
  uv_thread_join(&c->thread);
  CloseHandle(c->read);
  *text = c->text;
  *len = c->len;
  ok = ok && !c->lost;
  free(c);
  return ok;
}

agc_stdin_reader *agc_stdin_new(int fd) {
  agc_stdin_reader *r = calloc(1, sizeof *r);
  if (!r) agc_out_of_memory();
  if (uv_mutex_init(&r->lock) != 0 || uv_cond_init(&r->asked) != 0) agc_internal_abort("cannot make the stdin lock");
  r->fd = fd;
  atomic_init(&r->refs, 1);
  return r;
}

static void reader_unref(agc_stdin_reader *r) {
  if (atomic_fetch_sub(&r->refs, 1) != 1) return;
  if (r->started) CloseHandle(r->thread);
  uv_cond_destroy(&r->asked);
  uv_mutex_destroy(&r->lock);
  free(r->buf);
  free(r->units);
  free(r->spill);
  free(r);
}

/* DATA, of *CAP items of SIZE bytes, grown to at least N items (*CAP then says how many); NULL when memory is out,
   with DATA left as it was. */
static void *grow(void *data, size_t *cap, size_t n, size_t size) {
  if (*cap >= n) return data;
  void *grown = realloc(data, n * size);
  if (grown) *cap = n;
  return grown;
}

/* One read of a console: the text typed, in UTF-8 whatever the console's code page is. It asks for ROOM units, as
   _read asked for ROOM bytes: a console in line mode keeps no more of a line than the read asks for (the rest of what
   is typed is dropped), so asking for less would cut long lines. What does not fit ROOM waits in `spill` for the next
   read. As ReadFile does on a console, a read that gives nothing (Ctrl+C) and one that starts with Ctrl+Z are the end
   of input (0). Returns the bytes put in `buf`, or -1 with errno. */
static int console_read(agc_stdin_reader *r, HANDLE console, size_t room) {
  while (r->spill_len == 0) {
    wchar_t *units = grow(r->units, &r->units_cap, room + 1, sizeof(wchar_t));
    if (!units) {
      errno = ENOMEM;
      return -1;
    }
    r->units = units;
    DWORD start = r->high ? 1 : 0, got = 0;
    units[0] = r->high;
    if (!ReadConsoleW(console, units + start, (DWORD)room, &got, NULL)) {
      errno = EIO;
      return -1;
    }
    if (got == 0 || (!start && units[0] == 0x1A)) {
      r->high = 0;
      return 0;
    }
    DWORD total = start + got;
    r->high = IS_HIGH_SURROGATE(units[total - 1]) ? units[--total] : 0;
    if (total == 0) continue;
    int need = WideCharToMultiByte(CP_UTF8, 0, units, (int)total, NULL, 0, NULL, NULL);
    if (need <= 0) {
      errno = EIO;
      return -1;
    }
    uint8_t *spill = grow(r->spill, &r->spill_cap, (size_t)need, 1);
    if (!spill) {
      errno = ENOMEM;
      return -1;
    }
    r->spill = spill;
    r->spill_len = (size_t)WideCharToMultiByte(CP_UTF8, 0, units, (int)total, (char *)r->spill, need, NULL, NULL);
    r->spill_at = 0;
  }
  size_t take = r->spill_len < room ? r->spill_len : room;
  memcpy(r->buf, r->spill + r->spill_at, take);
  r->spill_at += take;
  r->spill_len -= take;
  return (int)take;
}

/* The thread: one blocking read per request. A console is read as text (console_read); anything else (a pipe, a file,
   NUL) with _read in binary mode, as it comes. */
static void reader_main(void *data) {
  agc_stdin_reader *r = data;
  DWORD mode;
  HANDLE handle = (HANDLE)_get_osfhandle(r->fd);
  bool console = handle != INVALID_HANDLE_VALUE && GetConsoleMode(handle, &mode);
  uv_mutex_lock(&r->lock);
  for (;;) {
    while (!r->want && !r->closed) uv_cond_wait(&r->asked, &r->lock);
    if (r->closed) break;
    size_t room = r->room;
    r->in_read = true;
    uv_mutex_unlock(&r->lock);
    int n;
    do {
      n = console ? console_read(r, handle, room) : _read(r->fd, r->buf, (unsigned)room);
    } while (n < 0 && errno == EINTR);
    uv_mutex_lock(&r->lock);
    r->in_read = false;
    r->want = false;
    r->got = n;
    /* The close sets `closed` under the lock before it closes the handle, so a send here never reaches a closed one. */
    if (!r->closed) uv_async_send(&r->wake);
  }
  uv_mutex_unlock(&r->lock);
  reader_unref(r);
}

/* On the I/O thread: the read is in, so its job ends. The handle keeps the loop alive only while a read is out. */
static void reader_woken(uv_async_t *wake) {
  agc_stdin_reader *r = wake->data;
  uv_mutex_lock(&r->lock);
  agc_io_job *job = r->want ? NULL : r->job;
  if (job) r->job = NULL;
  uv_mutex_unlock(&r->lock);
  if (!job) return;
  uv_unref((uv_handle_t *)&r->wake);
  agc_io_ready(job);
}

/* On the I/O thread, posted after the job's start, so the wake that ends the job always comes after that start. The
   thread and its wake are made at the first read; like the lock (agc_stdin_new), they are needed, so a failure to make
   them ends the process. The buffer grows here, while the thread waits. */
static void reader_go(void *data) {
  agc_stdin_reader *r = data;
  if (!r->started) {
    r->wake.data = r;
    if (uv_async_init(agc_loop_uv(r->loop), &r->wake, reader_woken) != 0)
      agc_internal_abort("cannot make the stdin wake");
    uv_unref((uv_handle_t *)&r->wake);
    atomic_fetch_add(&r->refs, 1);
    if (uv_thread_create(&r->thread, reader_main, r) != 0) agc_internal_abort("cannot start the stdin reader");
    r->started = true;
  }
  uv_mutex_lock(&r->lock);
  if (r->cap < r->room) {
    uint8_t *grown = realloc(r->buf, r->room);
    if (!grown) agc_out_of_memory();
    r->buf = grown;
    r->cap = r->room;
  }
  r->want = true;
  uv_cond_signal(&r->asked);
  uv_mutex_unlock(&r->lock);
  uv_ref((uv_handle_t *)&r->wake);
}

void agc_stdin_read(agc_vm *vm, agc_stdin_reader *r, agc_io_job *job, size_t room) {
  uv_mutex_lock(&r->lock);
  r->loop = agc_io_loop(vm);
  r->job = job;
  r->room = room;
  uv_mutex_unlock(&r->lock);
  agc_io_call(vm, reader_go, r);
}

int64_t agc_stdin_take(agc_stdin_reader *r, const uint8_t **data) {
  uv_mutex_lock(&r->lock);
  int64_t got = r->got;
  *data = r->buf;
  uv_mutex_unlock(&r->lock);
  return got;
}

static void reader_closed(uv_handle_t *handle) { reader_unref(handle->data); }

/* The thread is told to end, and a read it is in is cancelled where Windows can (a pipe). A cancel that comes after the
   thread set `in_read` but before it entered _read does nothing, so it is tried a few times, about a timer tick apart,
   while `in_read` stays set.
   What is left: a read that Windows cannot cancel (a console on some versions), or a thread that has not entered _read
   after the tries, stays in _read until input or EOF comes and takes that input; no later runtime in the process may
   read the descriptor. Such a thread touches nothing of the closed loop and frees the reader when it leaves. */
void agc_stdin_close(agc_stdin_reader *r) {
  uv_mutex_lock(&r->lock);
  r->closed = true;
  r->job = NULL;
  uv_cond_signal(&r->asked);
  uv_mutex_unlock(&r->lock);
  if (!r->started) {
    reader_unref(r);
    return;
  }
  for (int attempt = 0; attempt < CANCEL_TRIES; attempt++) {
    uv_mutex_lock(&r->lock);
    bool reading = r->in_read;
    uv_mutex_unlock(&r->lock);
    if (!reading) break;
    CancelSynchronousIo(r->thread);
    uv_sleep(1);
  }
  uv_close((uv_handle_t *)&r->wake, reader_closed);
}
#endif

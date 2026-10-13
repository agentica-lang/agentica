#include "agc.h"

#include <errno.h>
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif

#ifdef __linux__
#include <poll.h>
#endif

#define INPUT_CHUNK ((size_t)64 * 1024)
#define INPUT_SHRINK ((size_t)1024 * 1024)
#define INPUT_READ_MAX ((size_t)1024 * 1024)
#define INPUT_ROOM ((size_t)4096)
#define FILL_WAIT 3

#ifdef __linux__
typedef struct {
  int fd;
  size_t room;
  ssize_t got;
  uint8_t data[];
} read_request;
#endif

void agc_input_open(agc_vm *vm, int fd, bool flush_out) {
  agc_input *in = &vm->rt->in;
  in->fd = fd;
  in->flush_out = flush_out;
  in->pending_eof = false;
  in->reading = false;
  in->got = 0;
}

static _Noreturn void read_failed(agc_vm *vm) {
  agc_fail(vm, "RUNTIME-INTERNAL", "cannot read standard input", 0);
}

static agc_string *decode(const uint8_t *data, size_t len) {
  return agc_utf8_decode(data, len, "\xEF\xBF\xBD", false);
}

static void consume(agc_input *in, size_t to) {
  in->start = to;
  in->scanned = 0;
}

static void reserve(agc_input *in, size_t n) {
  if (in->start == in->end) {
    in->start = in->end = 0;
    if (in->cap > INPUT_SHRINK) {
      in->buf = NULL;
      in->cap = 0;
    }
  }
  if (in->cap - in->end >= n) return;
  size_t used = in->end - in->start;
  size_t need = agc_size_add(used, n);
  if (in->start > 0 && need <= in->cap) {
    memmove(in->buf, in->buf + in->start, used);
  } else {
    size_t cap = in->cap ? agc_size_mul(in->cap, 2) : INPUT_CHUNK;
    while (cap < need) cap = agc_size_mul(cap, 2);
    uint8_t *buf = agc_alloc_atomic(cap);
    if (used) memcpy(buf, in->buf + in->start, used);
    in->buf = buf;
    in->cap = cap;
  }
  in->start = 0;
  in->end = used;
}

static size_t read_room(agc_input *in) {
  reserve(in, INPUT_ROOM);
  size_t room = in->cap - in->end;
  return room > INPUT_READ_MAX ? INPUT_READ_MAX : room;
}

#ifdef __linux__
static bool wait_readable(int fd) {
  struct pollfd p = {.fd = fd, .events = POLLIN};
  for (;;) {
    if (poll(&p, 1, -1) >= 0) return true;
    if (errno != EINTR) return false;
  }
}

static void read_work(void *data) {
  read_request *q = data;
  for (;;) {
    ssize_t n = read(q->fd, q->data, q->room);
    if (n >= 0) {
      q->got = n;
      return;
    }
    if (errno == EINTR) continue;
    if ((errno == EAGAIN || errno == EWOULDBLOCK) && wait_readable(q->fd)) continue;
    q->got = -1;
    return;
  }
}

static agc_value read_done(agc_vm *vm, void *data, agc_value context) {
  (void)context;
  read_request *q = data;
  agc_input *in = &vm->rt->in;
  in->reading = false;
  AGC_TRACE(&vm->rt->trace, AGC_TRACE_IO, "stdin bytes=%" PRId64 " status=%s", q->got > 0 ? (int64_t)q->got : 0,
            q->got > 0 ? "data" : q->got == 0 ? "eof" : "error");
  if (q->got > 0) {
    reserve(in, (size_t)q->got);
    memcpy(in->buf + in->end, q->data, (size_t)q->got);
    in->end += (size_t)q->got;
  } else {
    in->got = q->got == 0 ? 0 : -1;
    in->eof_seq++;
  }
  free(q);
  agc_task_wake_all(vm, &in->waiters, &in->waiters_tail, "stdin");
  return agc_void();
}

static void read_drop(void *data) { free(data); }

static const agc_io_kind read_io = {read_work, read_done, NULL, read_drop, false, "stdin", NULL};

static int start_read(agc_vm *vm, agc_input *in) {
  if (in->reading) {
    agc_task_enqueue(&in->waiters, &in->waiters_tail, vm->task);
    agc_task_park(vm, true);
    return FILL_WAIT;
  }
  size_t room = read_room(in);
  if (in->flush_out) agc_flush(vm);
  read_request *q = malloc(sizeof(read_request) + room);
  if (!q) agc_out_of_memory();
  q->fd = in->fd;
  q->room = room;
  q->got = 0;
  in->reading = true;
  agc_io_start(vm, &read_io, q, agc_void(), -1);
  vm->task->retry = true;
  return FILL_WAIT;
}
#else
static int start_read(agc_vm *vm, agc_input *in) {
  size_t room = read_room(in);
  if (in->flush_out) agc_flush(vm);
  for (;;) {
    ssize_t n = read(in->fd, in->buf + in->end, room);
    if (n > 0) {
      in->end += (size_t)n;
      return 1;
    }
    if (n == 0) return 0;
    if (errno == EINTR) continue;
    return -1;
  }
}
#endif

static int fill(agc_vm *vm) {
  agc_input *in = &vm->rt->in;
  if (in->pending_eof) {
    in->pending_eof = false;
    return 0;
  }
  if (in->fd < 0) return 0;
  if (vm->task->input_seen != in->eof_seq) {
    vm->task->input_seen = in->eof_seq;
    return in->got;
  }
  return start_read(vm, in);
}

agc_input_status agc_input_peek(agc_vm *vm, int *byte) {
  agc_input *in = &vm->rt->in;
  if (in->start == in->end) {
    int r = fill(vm);
    if (r == FILL_WAIT) return AGC_INPUT_WAIT;
    if (r < 0) read_failed(vm);
    if (r == 0) {
      in->pending_eof = true;
      *byte = -1;
      return AGC_INPUT_EOF;
    }
  }
  *byte = in->buf[in->start];
  return AGC_INPUT_OK;
}

agc_input_status agc_input_line(agc_vm *vm, agc_string **line) {
  agc_input *in = &vm->rt->in;
  for (;;) {
    bool rescan = false;
    for (size_t k = in->start + in->scanned; k < in->end; k++) {
      uint8_t c = in->buf[k];
      if (c != '\n' && c != '\r') continue;
      if (c == '\r' && k + 1 == in->end) {
        in->scanned = k - in->start;
        int r = fill(vm);
        if (r == FILL_WAIT) return AGC_INPUT_WAIT;
        if (r < 0) read_failed(vm);
        if (r > 0) {
          rescan = true;
          break;
        }
        in->pending_eof = true;
      }
      *line = decode(in->buf + in->start, k - in->start);
      size_t next = k + 1;
      if (c == '\r' && next < in->end && in->buf[next] == '\n') next++;
      consume(in, next);
      return AGC_INPUT_OK;
    }
    if (rescan) continue;
    in->scanned = in->end - in->start;
    int r = fill(vm);
    if (r == FILL_WAIT) return AGC_INPUT_WAIT;
    if (r < 0) read_failed(vm);
    if (r == 0) {
      size_t seen = in->end - in->start;
      if (seen == 0) return AGC_INPUT_EOF;
      *line = decode(in->buf + in->start, seen);
      consume(in, in->end);
      return AGC_INPUT_OK;
    }
  }
}

agc_input_status agc_input_all(agc_vm *vm, agc_string **text) {
  agc_input *in = &vm->rt->in;
  for (;;) {
    int r = fill(vm);
    if (r == FILL_WAIT) return AGC_INPUT_WAIT;
    if (r < 0) read_failed(vm);
    if (r == 0) break;
  }
  if (!in->buf) {
    *text = agc_new_string(0, 0);
    return AGC_INPUT_OK;
  }
  *text = decode(in->buf + in->start, in->end - in->start);
  consume(in, in->end);
  return AGC_INPUT_OK;
}

agc_input_status agc_input_bytes(agc_vm *vm, size_t count, agc_list **out) {
  agc_input *in = &vm->rt->in;
  while (in->end - in->start < count) {
    int r = fill(vm);
    if (r == FILL_WAIT) return AGC_INPUT_WAIT;
    if (r < 0) return AGC_INPUT_FAILED;
    if (r == 0) break;
  }
  size_t n = in->end - in->start < count ? in->end - in->start : count;
  agc_list *l = agc_new_list(n);
  for (size_t k = 0; k < n; k++) l->items[k] = agc_int(in->buf[in->start + k]);
  consume(in, in->start + n);
  *out = l;
  return AGC_INPUT_OK;
}

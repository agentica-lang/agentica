#include "agc.h"

#include <errno.h>
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
#define INPUT_READ_MAX ((size_t)1 << 30)

void agc_input_open(agc_vm *vm, int fd, bool flush_out) {
  vm->in.fd = fd;
  vm->in.flush_out = flush_out;
  vm->in.pending_eof = false;
}

static _Noreturn void read_failed(agc_vm *vm) {
  agc_fail(vm, "RUNTIME-INTERNAL", "cannot read standard input", 0);
}

static agc_string *decode(const uint8_t *data, size_t len) {
  return agc_utf8_decode(data, len, "\xEF\xBF\xBD", false);
}

static void make_room(agc_input *in) {
  if (in->start == in->end) {
    in->start = in->end = 0;
    if (in->cap > INPUT_SHRINK) {
      in->buf = NULL;
      in->cap = 0;
    }
  }
  if (in->end < in->cap) return;
  size_t used = in->end - in->start;
  if (in->start > 0 && used <= in->cap / 2) {
    memmove(in->buf, in->buf + in->start, used);
  } else {
    size_t cap = in->cap ? agc_size_mul(in->cap, 2) : INPUT_CHUNK;
    uint8_t *buf = agc_alloc_atomic(cap);
    if (used) memcpy(buf, in->buf + in->start, used);
    in->buf = buf;
    in->cap = cap;
  }
  in->start = 0;
  in->end = used;
}

#ifdef __linux__
static bool wait_readable(int fd) {
  struct pollfd p = {.fd = fd, .events = POLLIN};
  for (;;) {
    if (poll(&p, 1, -1) >= 0) return true;
    if (errno != EINTR) return false;
  }
}
#endif

static int fill(agc_vm *vm) {
  agc_input *in = &vm->in;
  if (in->pending_eof) {
    in->pending_eof = false;
    return 0;
  }
  if (in->fd < 0) return 0;
  make_room(in);
  if (in->flush_out) agc_flush(vm);
  size_t room = in->cap - in->end;
  if (room > INPUT_READ_MAX) room = INPUT_READ_MAX;
  for (;;) {
    ssize_t n = read(in->fd, in->buf + in->end, room);
    if (n > 0) {
      in->end += (size_t)n;
      return 1;
    }
    if (n == 0) return 0;
    if (errno == EINTR) continue;
#ifdef __linux__
    if ((errno == EAGAIN || errno == EWOULDBLOCK) && wait_readable(in->fd)) continue;
#endif
    return -1;
  }
}

int agc_input_peek(agc_vm *vm) {
  agc_input *in = &vm->in;
  if (in->start == in->end) {
    int r = fill(vm);
    if (r < 0) read_failed(vm);
    if (r == 0) {
      in->pending_eof = true;
      return -1;
    }
  }
  return in->buf[in->start];
}

agc_string *agc_input_line(agc_vm *vm) {
  agc_input *in = &vm->in;
  size_t seen = 0;
  for (;;) {
    for (size_t k = in->start + seen; k < in->end; k++) {
      uint8_t c = in->buf[k];
      if (c == '\n' || c == '\r') {
        agc_string *line = decode(in->buf + in->start, k - in->start);
        in->start = k + 1;
        if (c == '\r' && agc_input_peek(vm) == '\n') in->start++;
        return line;
      }
    }
    seen = in->end - in->start;
    int r = fill(vm);
    if (r < 0) read_failed(vm);
    if (r == 0) {
      if (seen == 0) return NULL;
      agc_string *line = decode(in->buf + in->start, seen);
      in->start = in->end;
      return line;
    }
  }
}

agc_string *agc_input_all(agc_vm *vm) {
  agc_input *in = &vm->in;
  for (;;) {
    int r = fill(vm);
    if (r < 0) read_failed(vm);
    if (r == 0) break;
  }
  if (!in->buf) return agc_new_string(0, 0);
  agc_string *text = decode(in->buf + in->start, in->end - in->start);
  in->start = in->end;
  return text;
}

bool agc_input_bytes(agc_vm *vm, size_t count, agc_list **out) {
  agc_input *in = &vm->in;
  while (in->end - in->start < count) {
    int r = fill(vm);
    if (r < 0) return false;
    if (r == 0) break;
  }
  size_t n = in->end - in->start < count ? in->end - in->start : count;
  agc_list *l = agc_new_list(n);
  for (size_t k = 0; k < n; k++) l->items[k] = agc_int(in->buf[in->start + k]);
  in->start += n;
  *out = l;
  return true;
}

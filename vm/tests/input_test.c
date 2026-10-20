/*
 * vm/input.c with hand-made tasks and a pipe as stdin, with one pool thread: a waiting read leaves the pool free,
 * readers share the read in flight, EOF reaches each task once, and the loop closes with a read still waiting.
 */
#include "../core.h"

#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#else
#include <unistd.h>
#endif

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)

#ifdef _WIN32
#define close _close
#define write _write
#endif

static agc_vm vm;
static int pipe_fds[2];
static uint64_t ids;

static void open_pipe(void) {
#ifdef _WIN32
  assert(_pipe(pipe_fds, 4096, _O_BINARY) == 0);
#else
  assert(pipe(pipe_fds) == 0);
#endif
}

static void put(const char *text) { assert(write(pipe_fds[1], text, (unsigned)strlen(text)) == (int)strlen(text)); }

static void fresh(void) {
  open_pipe();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  agc_input_open(&vm, pipe_fds[0], false);
}

static agc_task *make_task(void) {
  agc_task *t = agc_alloc(sizeof(agc_task));
  t->id = ++ids;
  t->state = AGC_TASK_RUNNING;
  return t;
}

/* One call of gets by T: OK, EOF, or WAIT with the task parked as a scheduler would leave it. */
static agc_input_status gets_as(agc_task *t, agc_string **line) {
  vm.task = t;
  t->state = AGC_TASK_RUNNING;
  if (t->parked) {
    vm.in_turn = true;
    agc_io_finish(&vm, t);
    vm.in_turn = false;
  }
  t->parking = t->retry = false;
  while (agc_runq_pop(vm.rt->runq)) {}
  agc_input_status status = agc_input_line(&vm, line);
  assert((status == AGC_INPUT_WAIT) == t->parking);
  if (t->parking) {
    assert(t->retry);
    t->parking = false;
    t->state = AGC_TASK_PARKED;
  }
  return status;
}

static void expect_line(agc_task *t, const char *text) {
  agc_string *line = NULL;
  assert(gets_as(t, &line) == AGC_INPUT_OK);
  assert(line->bytes == strlen(text) && memcmp(line->data, text, line->bytes) == 0);
}

static void pump_until_ready(agc_task *t) {
  for (int round = 0; round < 10000 && t->state == AGC_TASK_PARKED; round++) {
    (void)agc_io_poll(&vm, false);
    uv_sleep(1);
  }
  assert(t->state == AGC_TASK_READY);
}

static void pool_work(uv_work_t *req) { (void)req; }

static void pool_after(uv_work_t *req, int status) {
  assert(status == 0);
  *(bool *)req->data = true;
}

/* A file call needs the pool: with one pool thread, it runs only if no stdin read keeps that thread. */
static void expect_the_pool_free(void) {
  bool ran = false;
  uv_work_t work = {.data = &ran};
  assert(agc_io_queue_work(agc_io_uv(&vm), &work, pool_work, pool_after) == 0);
  for (int round = 0; round < 5000 && !ran; round++) {
    (void)agc_io_poll(&vm, false);
    uv_sleep(1);
  }
  assert(ran);
}

static void test_readers_share_a_read_that_leaves_the_pool_free_and_each_gets_eof_once(void) {
  fresh();
  agc_task *a = make_task(), *b = make_task(), *c = make_task();
  agc_string *line;
  assert(gets_as(a, &line) == AGC_INPUT_WAIT);
  assert(gets_as(b, &line) == AGC_INPUT_WAIT);
  assert(b->parked == NULL);
  expect_the_pool_free();
  put("one\ntwo\n");
  /* The read is a's job: its end, taken when a resumes, wakes b. */
  pump_until_ready(a);
  expect_line(a, "one");
  assert(b->state == AGC_TASK_READY);
  expect_line(b, "two");
  assert(gets_as(a, &line) == AGC_INPUT_WAIT);
  assert(gets_as(b, &line) == AGC_INPUT_WAIT);
  close(pipe_fds[1]);
  pump_until_ready(a);
  assert(gets_as(a, &line) == AGC_INPUT_EOF);
  assert(b->state == AGC_TASK_READY);
  assert(gets_as(b, &line) == AGC_INPUT_EOF);
  /* A task that comes after the EOF reads again and gets its own EOF. */
  agc_input_status status = gets_as(c, &line);
  if (status == AGC_INPUT_WAIT) {
    pump_until_ready(c);
    status = gets_as(c, &line);
  }
  assert(status == AGC_INPUT_EOF);
  assert(agc_io_close(&vm));
  close(pipe_fds[0]);
}

static void test_the_loop_closes_while_a_read_waits(void) {
  fresh();
  agc_task *a = make_task();
  agc_string *line;
  assert(gets_as(a, &line) == AGC_INPUT_WAIT);
  for (int round = 0; round < 20; round++) (void)agc_io_poll(&vm, false);
  bool closed = false;
  for (int attempt = 0; attempt < 500 && !closed; attempt++) closed = agc_io_close(&vm);
  assert(closed && vm.rt->loop == NULL);
  /* The reader, if it is still in its read, ends with this input; it touches nothing of the closed loop. */
  put("late\n");
  close(pipe_fds[1]);
  uv_sleep(50);
}

int main(void) {
#ifdef _WIN32
  _putenv("UV_THREADPOOL_SIZE=1");
#else
  setenv("UV_THREADPOOL_SIZE", "1", 1);
#endif
  agc_init();
  agc_gc_allow_threads();
  agc_io_init();
  test_readers_share_a_read_that_leaves_the_pool_free_and_each_gets_eof_once();
  test_the_loop_closes_while_a_read_waits();
  puts("input tests passed");
  return 0;
}
#else
int main(void) {
  puts("input tests passed");
  return 0;
}
#endif

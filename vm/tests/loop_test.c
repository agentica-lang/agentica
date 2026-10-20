/*
 * The loop registry: slots after removals, a completed job, a timed-out job,
 * and agc_io_close, which frees the loop or refuses while a job is stuck. Also the stop-signal watch across
 * two VMs of one process, as the single binary runs them.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "../core.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <time.h>
#include <uv.h>

#if defined(__linux__) || defined(__APPLE__)
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
typedef struct {
  long sleep_ms;
  int value;
} task_data;

#if defined(__linux__) || defined(__APPLE__)
typedef struct {
  agc_poller *poller;
  int fd, calls, bytes;
  bool eof;
} read_probe;

#endif

static int dropped;
/* Pool workers that have finished their work; a worker thread adds to it, the test thread reads it. */
static atomic_int worked;

static void pause_ms(long ms) {
  uv_sleep((unsigned)ms);
}

static void slow_work(void *data) {
  task_data *t = data;
  pause_ms(t->sleep_ms);
  t->value = 7;
  atomic_fetch_add(&worked, 1);
}

static agc_value finished(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  task_data *t = data;
  int value = t->value + (int)agc_as_int(vm, context);
  free(t);
  return agc_int(value);
}

static agc_value expired(agc_vm *vm, void *data, agc_value context) {
  (void)vm;
  (void)data;
  (void)context;
  return agc_int(-1);
}

static void drop(void *data) {
  task_data *t = data;
  assert(t->value == 7);
  free(t);
  dropped++;
}

static const agc_io_kind kind = {slow_work, finished, expired, drop, false, "test", NULL, false, NULL};

static int64_t run_one(agc_vm *vm, long sleep_ms, int64_t timeout_ms) {
  task_data *t = calloc(1, sizeof(task_data));
  assert(t);
  t->sleep_ms = sleep_ms;
  agc_task *task = vm->task;
  agc_io_start(vm, &kind, t, agc_int(100), timeout_ms);
  assert(task->parked && task->parking);
  task->parking = false;
  task->state = AGC_TASK_PARKED;
  while (task->state == AGC_TASK_PARKED) assert(agc_io_poll(vm, true));
  while (agc_runq_pop(vm->rt->runq)) {}
  agc_value result = agc_io_finish(vm, task);
  assert(!task->parked);
  task->state = AGC_TASK_RUNNING;
  return agc_as_int(vm, result);
}

/* Waits, for about MS milliseconds at most, until COUNT pool workers have finished. The wait is bounded on the work,
   not a fixed pause: a loaded runner can take well over a job's sleep to finish it (#366). */
static bool work_done_within(int count, long ms) {
  for (long waited = 0;; waited += 10) {
    if (atomic_load(&worked) >= count) return true;
    if (waited >= ms) return false;
    pause_ms(10);
  }
}

/* Closes VM, trying for about MS milliseconds. A close refuses while a job's pool work is not over on the loop: a
   worker that still runs, or one that finished but whose after-work callback has not run yet (the worker wakes the
   loop after it returns). Each try runs the loop, so a later one sees the callback and the job is dropped. */
static bool close_within(agc_vm *vm, long ms) {
  for (long waited = 0;; waited += 10) {
    if (agc_io_close(vm)) return true;
    if (waited >= ms) return false;
    pause_ms(10);
  }
}
#endif

#if defined(__linux__) || defined(__APPLE__)
static void test_reopen_preserves_flags_and_offsets(void) {
  char path[] = "/tmp/agentica-reopen-XXXXXX";
  int fd = mkstemp(path);
  assert(fd >= 0 && write(fd, "abc", 3) == 3);
  assert(lseek(fd, 1, SEEK_SET) == 1);
  int flags = fcntl(fd, F_GETFL);
  int reopened = agc_fd_reopen(fd, O_RDONLY);
  assert(reopened >= 0 && (fcntl(reopened, F_GETFD) & FD_CLOEXEC));
  char byte;
  assert(read(reopened, &byte, 1) == 1 && byte == 'a');
  assert(lseek(fd, 0, SEEK_CUR) == 1 && fcntl(fd, F_GETFL) == flags);
  close(reopened);
  close(fd);
  assert(unlink(path) == 0);
  int fds[2];
  assert(pipe(fds) == 0);
  flags = fcntl(fds[0], F_GETFL);
  assert(agc_fd_reopen(fds[0], O_WRONLY) == -1 && errno == EBADF);
  reopened = agc_fd_reopen(fds[0], O_RDONLY);
  assert(reopened >= 0 && (fcntl(reopened, F_GETFD) & FD_CLOEXEC));
  assert(fcntl(fds[0], F_GETFL) == flags);
  assert(write(fds[1], "x", 1) == 1 && read(reopened, &byte, 1) == 1 && byte == 'x');
  close(reopened);
  close(fds[0]);
  close(fds[1]);
}

static void probe_read(void *data, int status) {
  read_probe *probe = data;
  assert(status == 0);
  probe->calls++;
  char byte;
  ssize_t n = read(probe->fd, &byte, 1);
  if (n == 1) {
    assert(byte == 'x');
    probe->bytes++;
  } else if (n == 0) {
    probe->eof = true;
    agc_poller_pause(probe->poller);
  } else {
    assert(errno == EAGAIN || errno == EWOULDBLOCK);
  }
}

static void test_pipe_readiness_and_eof(bool named) {
  agc_vm vm;
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  char directory[] = "/tmp/agentica-poller-XXXXXX";
  char path[128];
  int fds[2];
  if (named) {
    assert(mkdtemp(directory));
    assert(snprintf(path, sizeof path, "%s/fifo", directory) > 0);
    assert(mkfifo(path, 0600) == 0);
    fds[0] = open(path, O_RDONLY | O_NONBLOCK);
    assert(fds[0] >= 0);
    fds[1] = open(path, O_WRONLY | O_NONBLOCK);
    assert(fds[1] >= 0);
  } else {
    assert(pipe(fds) == 0);
    assert(fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0);
  }
  int err = 0;
  read_probe probe = {.fd = fds[0]};
  probe.poller = agc_poller_open(&vm, fds[0], &err);
  assert(probe.poller && err == 0);
  agc_poller_wait(probe.poller, false, probe_read, &probe);
  for (int k = 0; k < 20; k++) {
    agc_io_poll(&vm, false);
    pause_ms(1);
  }
  assert(!probe.eof && probe.bytes == 0);
  if (!named) assert(probe.calls == 0);
  assert(write(fds[1], "x", 1) == 1);
  for (int k = 0; k < 1000 && probe.bytes == 0; k++) {
    agc_io_poll(&vm, false);
    pause_ms(1);
  }
  assert(probe.bytes == 1 && !probe.eof);
  close(fds[1]);
  for (int k = 0; k < 1000 && !probe.eof; k++) {
    agc_io_poll(&vm, false);
    pause_ms(1);
  }
  assert(probe.eof && probe.bytes == 1);
  agc_poller_close(probe.poller);
  assert(agc_io_close(&vm));
  if (named) {
    assert(unlink(path) == 0);
    assert(rmdir(directory) == 0);
  }
}
#endif

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
static void native_close(uv_timer_t *timer) {
  *(bool *)timer->data = true;
  uv_close((uv_handle_t *)timer, NULL);
}

static void test_deferred_native_close(void) {
  agc_vm vm;
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  uv_timer_t timer;
  bool done = false;
  assert(uv_timer_init(agc_io_uv(&vm), &timer) == 0);
  timer.data = &done;
  assert(uv_timer_start(&timer, native_close, 50, 0) == 0);
  assert(agc_io_close(&vm));
  assert(done && vm.rt->loop == NULL);
}

/* The idle step of a scheduler with a timer waits for the deadline even when nothing else is alive in the loop: it
   returns only once the time has passed, not at once (a NOWAIT run would spin the scheduler). With alive_required the
   same empty loop is not run at all. The margin allows for the loop's millisecond clock. */
static void test_idle_wait_blocks_until_the_deadline(void) {
  agc_vm vm;
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  assert(!agc_io_run_for(&vm, 50, true));
  uint64_t start = agc_clock_ms();
  assert(agc_io_run_for(&vm, 50, false));
  assert(agc_clock_ms() - start >= 45);
  assert(agc_io_close(&vm));
}
#endif

static int released;

static void release_count(void *native) { (*(int *)native)++; }

int main(void) {
  agc_init();
  agc_vm vm;
  agc_io_init();
#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
  test_deferred_native_close();
  test_idle_wait_blocks_until_the_deadline();
#endif
#if defined(__linux__) || defined(__APPLE__)
  test_reopen_preserves_flags_and_offsets();
  test_pipe_readiness_and_eof(false);
  test_pipe_readiness_and_eof(true);
#endif
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);

  agc_resource *items[1000];
  for (int k = 0; k < 1000; k++) items[k] = agc_register(&vm, &released, release_count);
  for (int k = 0; k < 1000; k += 2) agc_unregister(&vm, items[k]);
  agc_unregister(&vm, items[0]);
  for (int k = 0; k < 1000; k++) assert((k % 2 == 0) == (items[k]->slot == SIZE_MAX));

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
  assert(agc_uv_version());
  assert(run_one(&vm, 0, 5000) == 107);
  assert(run_one(&vm, 300, 20) == -1);
  assert(dropped == 0);
  assert(run_one(&vm, 0, 5000) == 107);
  /* The close comes after the timed-out job's worker has finished (three workers so far), and drops its result. */
  assert(work_done_within(3, 5000));
  assert(close_within(&vm, 5000));
  assert(dropped == 1);
  assert(released == 500);
  assert(vm.rt->loop == NULL);
  agc_resource *again = agc_register(&vm, &released, release_count);
  assert(again->slot == 0);
  agc_unregister(&vm, again);
  assert(run_one(&vm, 0, 5000) == 107);
  assert(run_one(&vm, 2000, 20) == -1);
  assert(!agc_io_close(&vm));
  assert(close_within(&vm, 5000));
  assert(vm.rt->loop == NULL);
  /* The single binary runs two VMs in one process, one after the other: the second watches the stop signals with a
     wake handle of its own once the first is closed, and both closes settle. */
  agc_vm second;
  agc_vm_init(&second, NULL, stdout, stderr, INT64_MAX);
  agc_io_watch_stop(&vm, (int64_t)uv_os_getpid());
  assert(agc_io_close(&vm));
  assert(vm.rt->loop == NULL);
  agc_io_watch_stop(&second, (int64_t)uv_os_getpid());
  assert(agc_io_close(&second));
  assert(second.rt->loop == NULL);
  agc_io_watch_stop(&vm, (int64_t)uv_os_getpid());
  assert(agc_io_close(&vm));
  assert(agc_io_stop_signal() == 0);
#endif
  puts("loop tests passed");
  return 0;
}

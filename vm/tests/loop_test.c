/*
 * The loop registry: slots after removals, a completed job, a timed-out job,
 * and agc_io_close, which frees the loop or refuses while a job is stuck. Also the stop-signal watch across
 * two VMs of one process, as the single binary runs them.
 */
#include "../core.h"

#include <assert.h>
#include <stdlib.h>
#include <time.h>

typedef struct {
  long sleep_ms;
  int value;
} task_data;

static int dropped;
static int released;

static void pause_ms(long ms) {
  struct timespec delay = {ms / 1000, (ms % 1000) * 1000000};
  while (nanosleep(&delay, &delay) != 0) {}
}

static void slow_work(void *data) {
  task_data *t = data;
  pause_ms(t->sleep_ms);
  t->value = 7;
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

static const agc_io_kind kind = {slow_work, finished, expired, drop, false, "test", NULL};

#ifdef __linux__
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
  vm->ready = vm->ready_tail = NULL;
  agc_value result = agc_io_finish(vm, task);
  assert(!task->parked);
  task->state = AGC_TASK_RUNNING;
  return agc_as_int(vm, result);
}
#endif

static void release_count(void *native) { (*(int *)native)++; }

int main(void) {
  agc_init();
  agc_vm vm;
  agc_io_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);

  agc_resource *items[1000];
  for (int k = 0; k < 1000; k++) items[k] = agc_register(&vm, &released, release_count);
  for (int k = 0; k < 1000; k += 2) agc_unregister(&vm, items[k]);
  agc_unregister(&vm, items[0]);
  for (int k = 0; k < 1000; k++) assert((k % 2 == 0) == (items[k]->slot == SIZE_MAX));

#ifdef __linux__
  assert(agc_uv_version());
  assert(run_one(&vm, 0, 5000) == 107);
  assert(run_one(&vm, 300, 20) == -1);
  assert(dropped == 0);
  assert(run_one(&vm, 0, 5000) == 107);
  pause_ms(400);
  assert(agc_io_close(&vm));
  assert(dropped == 1);
  assert(released == 500);
  assert(vm.loop == NULL);
  agc_resource *again = agc_register(&vm, &released, release_count);
  assert(again->slot == 0);
  agc_unregister(&vm, again);
  assert(run_one(&vm, 0, 5000) == 107);
  assert(run_one(&vm, 2000, 20) == -1);
  assert(!agc_io_close(&vm));
  pause_ms(2100);
  assert(agc_io_close(&vm));
  assert(vm.loop == NULL);
  /* The single binary runs two VMs in one process, one after the other: the second watches the stop signals with a
     wake handle of its own once the first is closed, and both closes settle. */
  agc_vm second;
  agc_vm_init(&second, NULL, stdout, stderr, INT64_MAX);
  agc_io_watch_stop(&vm, 0);
  assert(agc_io_close(&vm));
  assert(vm.loop == NULL);
  agc_io_watch_stop(&second, 0);
  assert(agc_io_close(&second));
  assert(second.loop == NULL);
  agc_io_watch_stop(&vm, 0);
  assert(agc_io_close(&vm));
  assert(agc_io_stop_signal() == 0);
#endif
  puts("loop tests passed");
  return 0;
}

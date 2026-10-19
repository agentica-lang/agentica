/*
 * The File.each_line stepper paths that bytecode cannot reach, driven by hand:
 * buffer argument errors and a FIFO read that times out.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "../core.h"
#include "../services.h"

#include <assert.h>
#include <string.h>

#if defined(__linux__) || defined(__APPLE__)
#include <dirent.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
  const char *path;
  size_t found;
} open_path;

static agc_vm vm;
static uint64_t ids;
static const agc_builtin *each_line;
static char dir[4096];

static agc_task *make_task(void) {
  agc_task *t = agc_alloc(sizeof(agc_task));
  t->id = ++ids;
  t->state = AGC_TASK_RUNNING;
  return t;
}

static bool count_one(int fd, void *data) {
  (void)fd;
  (*(size_t *)data)++;
  return false;
}

static size_t descriptors(void) {
  size_t count = 0;
  agc_io_poll(&vm, false);
  agc_io_poll(&vm, false);
  assert(agc_each_fd(count_one, &count));
  return count;
}

static bool match_path(int fd, void *data) {
  open_path *search = data;
  struct stat info, wanted;
  if (fstat(fd, &info) == 0 && stat(search->path, &wanted) == 0 &&
      info.st_dev == wanted.st_dev && info.st_ino == wanted.st_ino)
    search->found++;
  return false;
}

static size_t opened(const char *path) {
  open_path search = {path, 0};
  assert(agc_each_fd(match_path, &search));
  return search.found;
}

static char *path_of(const char *name) {
  char *path = malloc(strlen(dir) + strlen(name) + 2);
  assert(path);
  sprintf(path, "%s/%s", dir, name);
  return path;
}

static agc_value string_of(const char *text) { return agc_string_value(agc_make_string(text, strlen(text), strlen(text))); }

static bool is_error(agc_value result, const char *text) {
  const agc_result *r = agc_as_result(&vm, result);
  if (r->ok) return false;
  const agc_string *s = agc_as_string(&vm, r->value);
  return strlen(text) == s->bytes && !memcmp(text, s->data, s->bytes);
}

static void install(agc_task *t, const char *path, int64_t buffer, int64_t timeout) {
  agc_value args[4] = {string_of(path), agc_int(buffer), agc_int(timeout), agc_void()};
  vm.task = t;
  t->state = AGC_TASK_RUNNING;
  agc_value result = each_line->fn(&vm, args, 0);
  assert(agc_is(result, AGC_T_VOID));
}

static void park(agc_task *t) {
  assert(t->parking && t->parked);
  t->parking = false;
  t->state = AGC_TASK_PARKED;
}

static agc_value finish_wait(agc_task *t) {
  park(t);
  while (t->state == AGC_TASK_PARKED) assert(agc_io_poll(&vm, true));
  while (agc_runq_pop(vm.rt->runq)) {}
  vm.task = t;
  t->state = AGC_TASK_RUNNING;
  vm.in_turn = true;
  agc_value result = agc_io_finish(&vm, t);
  vm.in_turn = false;
  assert(!t->retry);
  return result;
}

static agc_step advance(agc_task *t, agc_value last) {
  vm.task = t;
  assert(t->stepper);
  return t->stepper->step(&vm, t->stepper, last);
}

static agc_value drive(agc_task *t) {
  agc_value last = agc_void();
  for (;;) {
    agc_step step = advance(t, last);
    if (step.kind == AGC_STEP_END) return step.value;
    last = step.kind == AGC_STEP_WAIT ? finish_wait(t) : agc_result_value(true, agc_void());
  }
}

static void warm_up(void) {
  char *path = path_of("warm.txt");
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  assert(fd >= 0 && write(fd, "w\n", 2) == 2);
  close(fd);
  agc_task *t = make_task();
  install(t, path, 1024, 5000);
  const agc_result *r = agc_as_result(&vm, drive(t));
  assert(r->ok);
  free(path);
}

static void test_arguments(void) {
  int64_t bad[] = {-1, 0, 1023, 16777217};
  for (size_t k = 0; k < sizeof bad / sizeof bad[0]; k++) {
    agc_task *t = make_task();
    vm.task = t;
    agc_value args[4] = {string_of("never-opened"), agc_int(bad[k]), agc_int(100), agc_void()};
    if (setjmp(vm.fail) == 0) {
      each_line->fn(&vm, args, 40);
      assert(0);
    }
    assert(vm.rt->outcome.kind == AGC_FAILED && strcmp(vm.rt->outcome.code, "RUNTIME-INVALID-COUNT") == 0);
    assert(vm.rt->outcome.span == 42 && !t->stepper);
  }
}

static agc_task *park_on_fifo(const char *name, int64_t timeout, int *holder, char **path) {
  *path = path_of(name);
  assert(mkfifo(*path, 0600) == 0);
  *holder = open(*path, O_RDWR);
  assert(*holder >= 0);
  agc_task *t = make_task();
  install(t, *path, 1024, timeout);
  agc_step step = advance(t, agc_void());
  assert(step.kind == AGC_STEP_WAIT);
  step = advance(t, finish_wait(t));
  assert(step.kind == AGC_STEP_WAIT);
  return t;
}

static void test_fifo_timeout(void) {
  int holder;
  char *path;
  size_t base = descriptors();
  agc_task *t = park_on_fifo("timeout.fifo", 30, &holder, &path);
  assert(descriptors() == base + 2);
  agc_step step = advance(t, finish_wait(t));
  assert(step.kind == AGC_STEP_END && is_error(step.value, "filesystem: operation timed out"));
  assert(descriptors() == base + 1);
  close(holder);
  free(path);
  assert(descriptors() == base);
}

static void test_cancelled_reader(void) {
  int holder;
  char *path;
  size_t base = descriptors();
  agc_task *t = park_on_fifo("cancel.fifo", 60000, &holder, &path);
  park(t);
  vm.task = make_task();
  agc_task_cancel(&vm, t);
  assert(t->state == AGC_TASK_DONE && !t->parked && !t->owned);
  assert(descriptors() == base + 1 && opened(path) == 1);
  close(holder);
  assert(opened(path) == 0);
  assert(agc_io_close(&vm));
  free(path);
}

static void remove_directory(void) {
  DIR *d = opendir(dir);
  assert(d);
  for (struct dirent *e = readdir(d); e; e = readdir(d)) {
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
    char *path = path_of(e->d_name);
    assert(unlink(path) == 0);
    free(path);
  }
  closedir(d);
  assert(rmdir(dir) == 0);
}

int main(void) {
  agc_init();
  agc_io_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  agc_files_init(&vm);
  const char *temporary = getenv("TMPDIR");
  snprintf(dir, sizeof dir, "%s/agentica-each-line-XXXXXX", temporary && *temporary ? temporary : "/tmp");
  assert(mkdtemp(dir));
  each_line = agc_find_builtin((const uint8_t *)"File.each_line", 14, 4);
  assert(each_line && each_line->arity == 4);
  warm_up();
  test_arguments();
  test_fifo_timeout();
  test_cancelled_reader();
  remove_directory();
  puts("each_line tests passed");
  return 0;
}
#else
int main(void) {
  puts("each_line tests passed");
  return 0;
}
#endif

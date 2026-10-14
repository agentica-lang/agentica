#include "../core.h"
#include "../services.h"

#include <assert.h>
#include <string.h>

#ifdef __linux__
#include <dirent.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_LINES 4096

typedef struct {
  char *lines[MAX_LINES];
  size_t count, waits;
  agc_value outcome;
} trace;

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
  char link[64], target[4096];
  snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
  ssize_t n = readlink(link, target, sizeof target - 1);
  if (n > 0 && (size_t)n == strlen(search->path) && memcmp(target, search->path, (size_t)n) == 0) search->found++;
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

static char *write_file(const char *name, const void *data, size_t len) {
  char *path = path_of(name);
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  assert(fd >= 0 && write(fd, data, len) == (ssize_t)len);
  close(fd);
  return path;
}

static agc_value string_of(const char *text) { return agc_string_value(agc_make_string(text, strlen(text), strlen(text))); }

static bool is_error(agc_value result, const char *text) {
  const agc_result *r = agc_as_result(&vm, result);
  if (r->ok) return false;
  const agc_string *s = agc_as_string(&vm, r->value);
  return strlen(text) == s->bytes && !memcmp(text, s->data, s->bytes);
}

static bool is_ok(agc_value result) {
  const agc_result *r = agc_as_result(&vm, result);
  return r->ok && agc_is(r->value, AGC_T_VOID);
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
  vm.ready = vm.ready_tail = NULL;
  vm.task = t;
  t->state = AGC_TASK_RUNNING;
  agc_value result = agc_io_finish(&vm, t);
  assert(!t->retry);
  return result;
}

static agc_step advance(agc_task *t, agc_value last) {
  vm.task = t;
  assert(t->stepper);
  return t->stepper(&vm, t->stepper_state, last);
}

static void run(agc_task *t, trace *seen, size_t stop_after, agc_value stop_with) {
  agc_value last = agc_void();
  for (;;) {
    agc_step step = advance(t, last);
    if (step.kind == AGC_STEP_END) {
      seen->outcome = step.value;
      return;
    }
    if (step.kind == AGC_STEP_WAIT) {
      seen->waits++;
      last = finish_wait(t);
      continue;
    }
    const agc_string *line = agc_as_string(&vm, step.value);
    assert(seen->count < MAX_LINES);
    seen->lines[seen->count] = strndup(line->data, line->bytes);
    seen->count++;
    last = seen->count == stop_after ? stop_with : agc_result_value(true, agc_void());
  }
}

static void free_trace(trace *seen) {
  for (size_t k = 0; k < seen->count; k++) free(seen->lines[k]);
}

static void test_lines_across_reads(void) {
  size_t before = descriptors();
  char *text = malloc(40000), *at = text;
  for (int k = 0; k < 3000; k++) at += sprintf(at, "line %d%s", k, k % 7 == 0 ? "\r\n" : "\n");
  char *path = write_file("many.txt", text, (size_t)(at - text));
  agc_task *t = make_task();
  install(t, path, 1024, 5000);
  trace seen = {0};
  run(t, &seen, 0, agc_void());
  assert(is_ok(seen.outcome) && seen.count == 3000);
  for (int k = 0; k < 3000; k++) {
    char expected[32];
    sprintf(expected, "line %d", k);
    assert(strcmp(seen.lines[k], expected) == 0);
  }
  size_t bytes = (size_t)(at - text);
  assert(seen.waits >= bytes / 1025 && seen.waits <= bytes / 1000 + 4);
  assert(descriptors() == before);
  free_trace(&seen);
  free(text);
  free(path);
}

static void test_ends(void) {
  size_t before = descriptors();
  char *path = write_file("three.txt", "a\nb\r\nc", 6);
  agc_task *t = make_task();
  install(t, path, 1024, 5000);
  trace seen = {0};
  run(t, &seen, 2, agc_result_value(false, string_of("stop here")));
  assert(seen.count == 2 && strcmp(seen.lines[1], "b") == 0);
  assert(is_error(seen.outcome, "stop here") && descriptors() == before);
  free_trace(&seen);

  t = make_task();
  install(t, path, 1024, 5000);
  trace whole = {0};
  run(t, &whole, 0, agc_void());
  assert(whole.count == 3 && strcmp(whole.lines[2], "c") == 0 && is_ok(whole.outcome));
  free_trace(&whole);
  free(path);

  char big[1500];
  memset(big, 'x', sizeof big);
  path = write_file("long.txt", big, sizeof big);
  t = make_task();
  install(t, path, 1024, 5000);
  trace long_line = {0};
  run(t, &long_line, 0, agc_void());
  assert(long_line.count == 0 && is_error(long_line.outcome, "filesystem: line exceeds buffer_bytes"));
  free(path);

  path = write_file("bad.bin", "ok\n\xff\n", 5);
  t = make_task();
  install(t, path, 1024, 5000);
  trace bad = {0};
  run(t, &bad, 0, agc_void());
  assert(bad.count == 1 && !agc_as_result(&vm, bad.outcome)->ok);
  free_trace(&bad);
  free(path);

  path = path_of("missing.txt");
  t = make_task();
  install(t, path, 1024, 5000);
  trace missing = {0};
  run(t, &missing, 0, agc_void());
  assert(missing.count == 0 && is_error(missing.outcome, "filesystem: path does not refer to a regular file"));
  free(path);
  assert(descriptors() == before);
}

static void test_arguments(void) {
  char *path = write_file("args.txt", "a\n", 2);
  int64_t bad[] = {-1, 0, 1023, 16777217};
  for (size_t k = 0; k < sizeof bad / sizeof bad[0]; k++) {
    agc_task *t = make_task();
    vm.task = t;
    agc_value args[4] = {string_of(path), agc_int(bad[k]), agc_int(100), agc_void()};
    if (setjmp(vm.fail) == 0) {
      each_line->fn(&vm, args, 40);
      assert(0);
    }
    assert(vm.rt->outcome.kind == AGC_FAILED && strcmp(vm.rt->outcome.code, "RUNTIME-INVALID-COUNT") == 0);
    assert(vm.rt->outcome.span == 42 && !t->stepper);
  }
  int64_t good[] = {1024, 16777216};
  for (size_t k = 0; k < sizeof good / sizeof good[0]; k++) {
    agc_task *t = make_task();
    install(t, path, good[k], 100);
    trace seen = {0};
    run(t, &seen, 0, agc_void());
    assert(seen.count == 1 && is_ok(seen.outcome));
    free_trace(&seen);
  }
  agc_task *t = make_task();
  vm.task = t;
  agc_value args[4] = {string_of(path), agc_int(1024), agc_int(0), agc_void()};
  assert(is_error(each_line->fn(&vm, args, 0), "network: timeout must be positive milliseconds") && !t->stepper);
  agc_value empty[4] = {string_of(""), agc_int(1024), agc_int(10), agc_void()};
  const agc_result *r = agc_as_result(&vm, each_line->fn(&vm, empty, 0));
  assert(!r->ok && !t->stepper);
  free(path);
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
  assert(t->state == AGC_TASK_DONE && !t->parked);
  assert(descriptors() == base + 2 && opened(path) == 2);
  close(holder);
  assert(opened(path) == 1);
  assert(agc_io_close(&vm));
  assert(opened(path) == 0);
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
  char *warm = write_file("warm.txt", "w\n", 2);
  agc_task *first = make_task();
  install(first, warm, 1024, 5000);
  trace once = {0};
  run(first, &once, 0, agc_void());
  assert(once.count == 1);
  free_trace(&once);
  free(warm);
  test_lines_across_reads();
  test_ends();
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

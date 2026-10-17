/* Native child processes: literal arguments, inherited environment, pipes, private channel and guard cleanup. */
#include "../core.h"
#include "../services.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

static agc_vm vm;
static agc_task *task;

static agc_value text(const char *s) {
  return agc_string_value(agc_make_string(s, strlen(s), 0));
}

static agc_value call(const char *name, agc_value *args) {
  const agc_builtin *builtin = NULL;
  for (size_t k = 0; k < agc_process_builtin_count; k++)
    if (strcmp(agc_process_builtins[k].name, name) == 0) builtin = &agc_process_builtins[k];
  for (size_t k = 0; k < agc_duplex_builtin_count; k++)
    if (strcmp(agc_duplex_builtins[k].name, name) == 0) builtin = &agc_duplex_builtins[k];
  assert(builtin);
  task->state = AGC_TASK_RUNNING;
  task->parking = false;
  vm.task = task;
  agc_value result = builtin->fn(&vm, args, 0);
  if (!task->parking) return result;
  task->parking = false;
  task->state = AGC_TASK_PARKED;
  while (task->state == AGC_TASK_PARKED) assert(agc_io_poll(&vm, true));
  vm.ready = vm.ready_tail = NULL;
  task->state = AGC_TASK_RUNNING;
  return agc_io_finish(&vm, task);
}

static agc_value ok(agc_value result) {
  const agc_result *r = agc_as_result(&vm, result);
  if (!r->ok) {
    const agc_string *error = agc_as_string(&vm, r->value);
    fprintf(stderr, "%.*s\n", (int)error->bytes, error->data);
  }
  assert(r->ok);
  return r->value;
}

static void equal(agc_value value, const char *expected) {
  const agc_string *s = agc_as_string(&vm, value);
  assert(s->bytes == strlen(expected) && memcmp(s->data, expected, s->bytes) == 0);
}

static void init(void) {
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  vm.rt->allow_run = true;
  task = agc_alloc(sizeof(agc_task));
  vm.task = task;
  vm.in_turn = true;
}

static int child(int argc, char **argv) {
#ifdef _WIN32
  _setmode(0, _O_BINARY);
  _setmode(1, _O_BINARY);
  _setmode(2, _O_BINARY);
#endif
  if (strcmp(argv[1], "--wait") == 0) { uv_sleep(30000); return 0; }
  if (strcmp(argv[1], "--channel") == 0) {
    init();
    agc_parent_take(&vm);
    assert(agc_parent_open(&vm));
    agc_value args[] = {agc_int(5000), agc_void()};
    const agc_string *line = agc_as_string(&vm, ok(call("Process.parent_read_line", args)));
    agc_string *reply = agc_new_string(agc_size_add(line->bytes, 1), 0);
    memcpy(reply->data, line->data, line->bytes);
    reply->data[line->bytes] = '\n';
    args[0] = agc_string_value(reply);
    args[1] = agc_int(5000);
    ok(call("Process.parent_send", args));
    assert(agc_io_close(&vm));
    return 0;
  }
  assert(argc == 4 && strcmp(argv[2], "space \"quoted\"") == 0 && argv[3][0] == '\0');
  char environment[256];
  size_t size = sizeof environment;
  assert(uv_os_getenv("AGENTICA_PROCESS_TEST", environment, &size) == 0);
  assert(strcmp(environment, "\xC3\xB1\xF0\x9F\x99\x82") == 0);
  size = sizeof environment;
  assert(uv_os_getenv(AGC_CHANNEL_ENV, environment, &size) == UV_ENOENT);
  uint8_t bytes[1024];
  size_t n;
  while ((n = fread(bytes, 1, sizeof bytes, stdin)) != 0) assert(fwrite(bytes, 1, n, stdout) == n);
  return fflush(stdout) == 0 ? 0 : 1;
}

int main(int argc, char **argv) {
  agc_init();
  agc_io_init();
  if (argc > 1) return child(argc, argv);
  char self[32768];
  size_t size = sizeof self;
  assert(uv_exepath(self, &size) == 0);
  init();
  agc_resource *spare = agc_register(&vm, NULL, NULL);
  agc_value rest[] = {text("--wait")};
  agc_value args[] = {text(self), agc_list_value(agc_list_from_array(rest, 1)), agc_int(5000), agc_int(5000)};
  ok(call("Process.spawn", args));
  agc_unregister(&vm, spare);
  bool closed = agc_io_close(&vm);
  if (!closed) uv_print_all_handles(agc_io_uv(&vm), stderr);
  assert(closed && vm.loop == NULL);
  init();
  assert(uv_os_setenv("AGENTICA_PROCESS_TEST", "\xC3\xB1\xF0\x9F\x99\x82") == 0);
  assert(uv_os_setenv(AGC_CHANNEL_ENV, "private") == 0);
  agc_value words[] = {text("--echo"), text("space \"quoted\""), text("")};
  args[0] = text(self);
  args[1] = agc_list_value(agc_list_from_array(words, 3));
  args[2] = text(".");
  agc_value handle = ok(call("Process.spawn_captured", args));
  args[0] = handle;
  args[1] = text("hello\r\n\xC3\xB1\xF0\x9F\x99\x82\n");
  args[2] = agc_int(5000);
  ok(call("Process.send", args));
  args[1] = agc_int(5000);
  ok(call("Process.close_stdin", args));
  assert(agc_as_int(&vm, ok(call("Process.wait", args))) == 0);
  equal(ok(call("Process.read_available", args)), "hello\r\n\xC3\xB1\xF0\x9F\x99\x82\n");
  call("Process.close", args);
  rest[0] = text("--channel");
  args[0] = text(self);
  args[1] = agc_list_value(agc_list_from_array(rest, 1));
  args[2] = text(".");
  handle = ok(call("Process.spawn_channel", args));
  args[0] = handle;
  args[1] = text("private \xC3\xB1\xF0\x9F\x99\x82\n");
  args[2] = agc_int(5000);
  ok(call("Process.channel_send", args));
  args[1] = agc_int(5000);
  equal(ok(call("Process.channel_read_line", args)), "private \xC3\xB1\xF0\x9F\x99\x82");
  assert(agc_as_int(&vm, ok(call("Process.wait", args))) == 0);
  call("Process.close", args);
  assert(uv_os_unsetenv("AGENTICA_PROCESS_TEST") == 0);
  assert(uv_os_unsetenv(AGC_CHANNEL_ENV) == 0);
  assert(agc_io_close(&vm));
  puts("process tests passed");
  return 0;
}

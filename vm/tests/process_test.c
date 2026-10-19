/* Native child processes: literal arguments, inherited environment, pipes, private channel and guard cleanup. */
#include "builtin_test.h"
#include "../services.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#else
#include <sys/wait.h>
#include <unistd.h>
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
  return agc_test_call(&vm, task, builtin, args);
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

/* True once the process has ended, whether or not anyone has collected its status (a POSIX zombie counts as ended,
   and WNOWAIT leaves it for libuv). */
static bool ended(long pid) {
#ifdef _WIN32
  HANDLE h = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pid);
  if (!h) return true;
  bool done = WaitForSingleObject(h, 0) == WAIT_OBJECT_0;
  CloseHandle(h);
  return done;
#else
  siginfo_t info;
  memset(&info, 0, sizeof info);
  return waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) != 0 || info.si_pid == pid;
#endif
}

/* Closes the process in args[0]. A failed close longjmps out of the builtin (the VM is in a turn), so the jump is
   caught here and turned into an assert, not left to jump through a dead frame. */
static void close_must_not_fail(agc_value *args) {
  if (setjmp(vm.turn) == 0)
    call("Process.close", args);
  else
    assert(!"Process.close failed");
}

/* Waits, for at most five seconds, for the child that wrote its pid to `path` to be gone. */
static void wait_ended(const char *path) {
  long pid = 0;
  for (int k = 0; k < 500 && pid == 0; k++) {
    FILE *f = fopen(path, "rb");
    if (f) {
      char line[32] = "";
      if (fgets(line, sizeof line, f) && strchr(line, '\n')) pid = atol(line);
      fclose(f);
    }
    if (pid == 0) uv_sleep(10);
  }
  assert(pid > 0);
  for (int k = 0; k < 500 && !ended(pid); k++) uv_sleep(10);
  assert(ended(pid));
}

static int child(int argc, char **argv) {
#ifdef _WIN32
  _setmode(0, _O_BINARY);
  _setmode(1, _O_BINARY);
  _setmode(2, _O_BINARY);
#endif
  if (strcmp(argv[1], "--wait") == 0) { uv_sleep(30000); return 0; }
  if (strcmp(argv[1], "--exit") == 0) {
    /* Say who we are, then end: the parent waits for this pid to be gone without running its loop. */
    FILE *f = argc > 2 ? fopen(argv[2], "wb") : NULL;
    if (f) {
#ifdef _WIN32
      fprintf(f, "%lu\n", (unsigned long)GetCurrentProcessId());
#else
      fprintf(f, "%ld\n", (long)getpid());
#endif
      fclose(f);
    }
    return 3;
  }
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
  /* The child has ended, but the loop has not run, so its exit callback is still to come: stopping it must not fail.
     Only Windows exercises the ESRCH path here (TerminateProcess on an exited process gives UV_ESRCH); on POSIX the
     zombie still accepts the signal. */
  char base[4096], pid_file[4200];
  size_t base_size = sizeof base;
  assert(uv_os_tmpdir(base, &base_size) == 0);
  snprintf(pid_file, sizeof pid_file, "%s/agc-exit-%ld.txt", base, (long)uv_os_getpid());
  agc_value exit_words[] = {text("--exit"), text(pid_file)};
  args[0] = text(self);
  args[1] = agc_list_value(agc_list_from_array(exit_words, 2));
  args[2] = text(".");
  args[3] = agc_int(5000);
  handle = ok(call("Process.spawn_captured", args));
  wait_ended(pid_file);
  remove(pid_file);
  args[0] = handle;
  close_must_not_fail(args);
  /* A close that failed would have ended the run; this one left the handle closed. */
  args[1] = agc_int(5000);
  assert(!agc_as_result(&vm, call("Process.wait", args))->ok);
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

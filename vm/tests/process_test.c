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
#include <errno.h>
#include <fcntl.h>
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

/* Starts `command` as a captured child that exits with 3 and returns its status, or -1 when it does not start. */
static int64_t status_of(const char *command) {
  agc_value rest[] = {text("--exit")};
  agc_value args[] = {text(command), agc_list_value(agc_list_from_array(rest, 1)), text("."), agc_int(5000)};
  const agc_builtin *spawn = NULL;
  for (size_t k = 0; k < agc_process_builtin_count; k++)
    if (strcmp(agc_process_builtins[k].name, "Process.spawn_captured") == 0) spawn = &agc_process_builtins[k];
  const agc_result *r = agc_as_result(&vm, agc_test_call(&vm, task, spawn, args));
  if (!r->ok) return -1;
  agc_value handle[] = {r->value, agc_int(5000)};
  int64_t status = agc_as_int(&vm, ok(call("Process.wait", handle)));
  call("Process.close", handle);
  return status;
}

static void copy_file(const char *from, const char *to) {
  uv_fs_t req;
  assert(uv_fs_copyfile(NULL, &req, from, to, 0, NULL) == 0);
  uv_fs_req_cleanup(&req);
}

static void set_path(const char *head, const char *tail) {
  char joined[32768];
  snprintf(joined, sizeof joined, "%s%s", head, tail);
  assert(uv_os_setenv("PATH", joined) == 0);
}

/* The command search of docs/vm/10-io-processes.md 10.4, with a copy of this program as the only candidate. */
static void search_tests(const char *self) {
  char base[4096], dir[4200], file[4400];
  size_t size = sizeof base;
  assert(uv_os_tmpdir(base, &size) == 0);
  snprintf(dir, sizeof dir, "%s/agc-search-XXXXXX", base);
  uv_fs_t req;
  assert(uv_fs_mkdtemp(NULL, &req, dir, NULL) == 0);
  snprintf(dir, sizeof dir, "%s", req.path);
  uv_fs_req_cleanup(&req);
  char old[32768];
  size = sizeof old;
  assert(uv_os_getenv("PATH", old, &size) == 0);
#ifdef _WIN32
  const char sep = ';';
  const char *peer = "agc-peer.exe";
#else
  const char sep = ':';
  const char *peer = "agc-peer";
#endif
  snprintf(file, sizeof file, "%s/%s", dir, peer);
  copy_file(self, file);

  /* The directory comes after an empty entry, and the rest of PATH stays, so the copy still finds its libraries. */
  char head[4400];
#ifdef _WIN32
  snprintf(head, sizeof head, "%c\"%s\"%c", sep, dir, sep);
#else
  snprintf(head, sizeof head, "%c%s%c", sep, dir, sep);
#endif
  set_path(head, old);
  assert(status_of("agc-peer") == 3);
  assert(status_of("agc-peer.") == -1 && status_of("agc-peer ") == -1 && status_of("agc-pee") == -1);
  assert(status_of(file) == 3);
  assert(status_of("agc-peer/") == -1);
#ifdef _WIN32
  /* Case does not matter, `.com` runs, `.cmd` and `.bat` never do (that needs cmd.exe), and a stream name is refused. */
  assert(status_of("AGC-PEER") == 3 && status_of("agc-peer.EXE") == 3);
  char com[4400], script[4400];
  snprintf(com, sizeof com, "%s/agc-com.com", dir);
  copy_file(self, com);
  assert(status_of("agc-com") == 3 && status_of("agc-com.com") == 3);
  snprintf(script, sizeof script, "%s/agc-script.cmd", dir);
  FILE *f = fopen(script, "wb");
  assert(f && fputs("@exit 3\r\n", f) >= 0 && fclose(f) == 0);
  assert(status_of("agc-script") == -1 && status_of("agc-script.cmd") == -1 && status_of(script) == -1);
  snprintf(script, sizeof script, "%s:stream", file);
  assert(status_of(script) == -1);
#endif

  /* The working directory is not searched: only PATH is. */
  set_path("", old);
  char here[4096];
  size = sizeof here;
  assert(uv_cwd(here, &size) == 0);
  assert(uv_chdir(dir) == 0);
  assert(status_of("agc-peer") == -1);
  assert(uv_chdir(here) == 0);

  assert(uv_os_setenv("PATH", old) == 0);
  assert(uv_fs_unlink(NULL, &req, file, NULL) == 0);
  uv_fs_req_cleanup(&req);
#ifdef _WIN32
  assert(uv_fs_unlink(NULL, &req, com, NULL) == 0);
  uv_fs_req_cleanup(&req);
  snprintf(script, sizeof script, "%s/agc-script.cmd", dir);
  assert(uv_fs_unlink(NULL, &req, script, NULL) == 0);
  uv_fs_req_cleanup(&req);
#endif
  assert(uv_fs_rmdir(NULL, &req, dir, NULL) == 0);
  uv_fs_req_cleanup(&req);
}

/* A descriptor or handle that the parent made inheritable before its first spawn; its number reaches the child as a word. */
static long long inheritable(void) {
#ifdef _WIN32
  SECURITY_ATTRIBUTES attributes = {sizeof attributes, NULL, TRUE};
  HANDLE h = CreateFileA("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &attributes, OPEN_EXISTING, 0, NULL);
  assert(h != INVALID_HANDLE_VALUE);
  return (long long)(intptr_t)h;
#else
  int fd = open("/dev/null", O_RDONLY);
  assert(fd >= 0);
  int high = fcntl(fd, F_DUPFD, 100);
  assert(high >= 100);
  close(fd);
  return high;
#endif
}

/* The child's check, made before any set-up of its own: true when the parent's descriptor or handle did not arrive. */
static bool absent(long long number) {
#ifdef _WIN32
  HANDLE h = (HANDLE)(intptr_t)number;
  DWORD flags;
  return !(GetHandleInformation(h, &flags) && GetFileType(h) == FILE_TYPE_CHAR);
#else
  return fcntl((int)number, F_GETFD) == -1 && errno == EBADF;
#endif
}

static int child(int argc, char **argv) {
#ifdef _WIN32
  _setmode(0, _O_BINARY);
  _setmode(1, _O_BINARY);
  _setmode(2, _O_BINARY);
#endif
  if (strcmp(argv[1], "--wait") == 0) { uv_sleep(30000); return 0; }
  if (strcmp(argv[1], "--exit") == 0) return 3;
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
  if (argc > 2 && strcmp(argv[1], "--leak") == 0) return absent(atoll(argv[2])) ? 0 : 1;
  agc_init();
  agc_io_init();
  if (argc > 1) return child(argc, argv);
  char self[32768];
  size_t size = sizeof self;
  assert(uv_exepath(self, &size) == 0);
  long long leak = inheritable();
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
  /* The child has ended, but the loop has not run, so its exit callback is still to come: stopping it must not fail
     (TerminateProcess on a Windows process that exited gives UV_ESRCH). */
  rest[0] = text("--exit");
  args[0] = text(self);
  args[1] = agc_list_value(agc_list_from_array(rest, 1));
  args[2] = text(".");
  args[3] = agc_int(5000);
  handle = ok(call("Process.spawn_captured", args));
  uv_sleep(500);
  args[0] = handle;
  call("Process.close", args);
  /* Only the standard streams and the channel reach a child: not a descriptor or handle that the VM process holds. */
  char number[32];
  snprintf(number, sizeof number, "%lld", leak);
  rest[0] = text("--leak");
  agc_value leak_words[] = {rest[0], text(number)};
  args[0] = text(self);
  args[1] = agc_list_value(agc_list_from_array(leak_words, 2));
  args[2] = text(".");
  args[3] = agc_int(5000);
  handle = ok(call("Process.spawn_captured", args));
  args[0] = handle;
  args[1] = agc_int(5000);
  assert(agc_as_int(&vm, ok(call("Process.wait", args))) == 0);
  call("Process.close", args);
  search_tests(self);
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

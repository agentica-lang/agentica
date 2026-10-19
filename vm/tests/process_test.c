/* Native child processes: literal arguments, inherited environment, pipes, private channel and guard cleanup. */
#include "builtin_test.h"
#include "../services.h"
#include "../process_os.h"

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
  char joined[40000];
  snprintf(joined, sizeof joined, "%s%s", head, tail);
  assert(uv_os_setenv("PATH", joined) == 0);
}

/* The name rules and the path test of process_os.h, on the strings alone: `win` is the answer on Windows, and every
   name is accepted on POSIX. */
static void name_rules(void) {
  static const struct { const char *name; bool win_ok; bool win_path; bool posix_path; } cases[] = {
    {"tool", true, false, false},
    {"tool.exe", true, false, false},
    {"a b.exe", true, false, false},
    {"dir/tool.exe", true, true, true},
    {"dir\\tool.exe", true, true, false},
    {"C:\\x.exe", true, true, false},
    {"C:/x.exe", true, true, true},
    {"C:foo.exe", false, true, false},
    {"x.exe:s.exe", false, true, false},
    {"x.exe::$DATA", false, true, false},
    {"\\\\?\\C:\\x.exe", false, true, false},
    {"\\\\.\\C:\\x.exe", false, true, false},
    {"\\\\?\\UNC\\h\\s\\x.exe", false, true, false},
    {"//./x.exe", false, true, true},
    {"tool.exe.", false, false, false},
    {"tool.exe ", false, false, false},
    {"dir\\", false, true, false},
    {"x.cmd", false, false, false},
    {"X.BAT", false, false, false},
    {"x.cmd.exe", true, false, false},
  };
  for (size_t k = 0; k < sizeof cases / sizeof cases[0]; k++) {
    size_t n = strlen(cases[k].name);
#ifdef _WIN32
    assert(agc_proc_name_ok(cases[k].name, n) == cases[k].win_ok);
    assert(agc_proc_is_path(cases[k].name, n) == cases[k].win_path);
#else
    assert(agc_proc_name_ok(cases[k].name, n));
    assert(agc_proc_is_path(cases[k].name, n) == cases[k].posix_path);
#endif
  }
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

  /* An empty entry, then the directory; the rest of PATH stays, so the copy still finds its libraries. That an empty
     entry or the working directory is not searched is checked end to end in tests/test_process.py. */
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
  /* Case does not matter, `.com` runs, `.cmd` and `.bat` never do (that needs cmd.exe), and a planted x.cmd.exe does
     not answer a request for x.cmd. */
  assert(status_of("AGC-PEER") == 3 && status_of("agc-peer.EXE") == 3);
  char com[4400], script[4400];
  snprintf(com, sizeof com, "%s/agc-com.com", dir);
  copy_file(self, com);
  assert(status_of("agc-com") == 3 && status_of("agc-com.com") == 3);
  snprintf(script, sizeof script, "%s/agc-script.cmd", dir);
  FILE *f = fopen(script, "wb");
  assert(f && fputs("@exit 3\r\n", f) >= 0 && fclose(f) == 0);
  assert(status_of("agc-script") == -1 && status_of("agc-script.cmd") == -1 && status_of(script) == -1);
  char plant[4400];
  snprintf(plant, sizeof plant, "%s/agc-plant.cmd.exe", dir);
  copy_file(self, plant);
  assert(status_of("agc-plant.cmd") == -1 && status_of("agc-plant.cmd.exe") == 3);
#endif

  assert(uv_os_setenv("PATH", old) == 0);
  assert(uv_fs_unlink(NULL, &req, file, NULL) == 0);
  uv_fs_req_cleanup(&req);
#ifdef _WIN32
  assert(uv_fs_unlink(NULL, &req, com, NULL) == 0);
  uv_fs_req_cleanup(&req);
  snprintf(script, sizeof script, "%s/agc-script.cmd", dir);
  assert(uv_fs_unlink(NULL, &req, script, NULL) == 0);
  uv_fs_req_cleanup(&req);
  assert(uv_fs_unlink(NULL, &req, plant, NULL) == 0);
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

/* The child's check, made before any set-up of its own: true when the parent's descriptor or handle did not arrive.
   On Windows it assumes no handle of the child's own sits at the same value and is a character device. */
static bool absent(long long number) {
#ifdef _WIN32
  HANDLE h = (HANDLE)(intptr_t)number;
  DWORD flags;
  return !(GetHandleInformation(h, &flags) && GetFileType(h) == FILE_TYPE_CHAR);
#else
  return fcntl((int)number, F_GETFD) == -1 && errno == EBADF;
#endif
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

/* The VM side of a channel child: it takes the channel from the descriptors the parent gave it. */
static void take_channel(void) {
  init();
  agc_parent_take(&vm);
  assert(agc_parent_open(&vm));
}

/* True when the CRT descriptor is not open in this process. */
static bool fd_absent(int fd) {
#ifdef _WIN32
  return _get_osfhandle(fd) == (intptr_t)INVALID_HANDLE_VALUE;
#else
  return fcntl(fd, F_GETFD) == -1 && errno == EBADF;
#endif
}

/* Starts this program again in `mode` (with one more word when `extra` is given) with Process.spawn_channel or
   Process.spawn_captured, and returns the handle. */
static agc_value start(const char *builtin, const char *self, const char *mode, const char *extra) {
  agc_value words[] = {text(mode), text(extra ? extra : "")};
  agc_value args[] = {text(self), agc_list_value(agc_list_from_array(words, extra ? 2 : 1)), text("."), agc_int(5000)};
  return ok(call(builtin, args));
}

static agc_value read_line(agc_value handle, int64_t ms) {
  agc_value args[] = {handle, agc_int(ms)};
  return call("Process.channel_read_line", args);
}

static agc_value send_line(agc_value handle, agc_value line) {
  agc_value args[] = {handle, line, agc_int(5000)};
  return call("Process.channel_send", args);
}

static void fails(agc_value result, const char *message) {
  const agc_result *r = agc_as_result(&vm, result);
  assert(!r->ok);
  equal(r->value, message);
}

static int64_t exit_status(agc_value handle) {
  agc_value args[] = {handle, agc_int(5000)};
  return agc_as_int(&vm, ok(call("Process.wait", args)));
}

static void close_process(agc_value handle) {
  agc_value args[] = {handle};
  call("Process.close", args);
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
  if (strcmp(argv[1], "--lines") == 0) {
    /* Counts the lines until the channel ends, and reports how many came and why it ended. */
    take_channel();
    int count = 0;
    for (;;) {
      agc_value args[] = {agc_int(5000), agc_void()};
      const agc_result *r = agc_as_result(&vm, call("Process.parent_read_line", args));
      if (!r->ok) {
        const agc_string *why = agc_as_string(&vm, r->value);
        char reply[160];
        snprintf(reply, sizeof reply, "%d %.*s\n", count, (int)why->bytes, why->data);
        args[0] = text(reply);
        args[1] = agc_int(5000);
        ok(call("Process.parent_send", args));
        break;
      }
      count++;
    }
    assert(agc_io_close(&vm));
    return 0;
  }
  if (strcmp(argv[1], "--flood") == 0) {
    /* More than a line may hold, written to the raw channel descriptor with no newline. */
    static char block[65536];
    memset(block, 'x', sizeof block);
    size_t left = 1048700;
    while (left) {
      size_t n = left < sizeof block ? left : sizeof block;
#ifdef _WIN32
      int done = _write(4, block, (unsigned)n);
#else
      long done = write(3, block, n);
#endif
      if (done <= 0) return 0;
      left -= (size_t)done;
    }
    uv_sleep(30000);
    return 0;
  }
  if (strcmp(argv[1], "--isolated") == 0) {
    /* What a child of a channel child must not inherit: the marker and the channel descriptors. */
    char value[64];
    size_t room = sizeof value;
    return uv_os_getenv(AGC_CHANNEL_ENV, value, &room) == UV_ENOENT && fd_absent(3) && fd_absent(4) ? 0 : 1;
  }
  if (strcmp(argv[1], "--middle") == 0) {
    /* A channel child with a plain child of its own: it reports whether that one inherited the marker or a channel
       descriptor. */
    take_channel();
    char self[32768];
    size_t size = sizeof self;
    assert(uv_exepath(self, &size) == 0);
    agc_value plain = start("Process.spawn_captured", self, "--isolated", NULL);
    agc_value args[] = {plain, agc_int(5000)};
    int64_t status = agc_as_int(&vm, ok(call("Process.wait", args)));
    args[0] = text(status == 0 ? "isolated\n" : "inherited\n");
    args[1] = agc_int(5000);
    ok(call("Process.parent_send", args));
    return 0;
  }
  if (strcmp(argv[1], "--channel") == 0) {
    take_channel();
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

/* The channel contract with children that are this program: lines in both directions, the end of input after a half
   close and what still comes back, a line over the limit, a timeout, a child that ends, and the isolation of a grandchild. */
static void channel_tests(const char *self) {
  agc_value handle = start("Process.spawn_channel", self, "--lines", NULL);
  ok(send_line(handle, text("one\n")));
  ok(send_line(handle, text("two\n")));
  agc_value args[] = {handle, agc_int(5000)};
  ok(call("Process.channel_close", args));
  equal(ok(read_line(handle, 5000)), "2 process: end of input");
  assert(exit_status(handle) == 0);
  close_process(handle);

  handle = start("Process.spawn_channel", self, "--flood", NULL);
  fails(read_line(handle, 10000), "process: line exceeds 1048576 bytes");
  fails(read_line(handle, 100), "process: channel is closed");
  close_process(handle);

  handle = start("Process.spawn_channel", self, "--wait", NULL);
  agc_string *big = agc_new_string(1048577, 0);
  memset(big->data, 'y', big->bytes);
  fails(send_line(handle, agc_string_value(big)), "process: send exceeds 1048576 bytes");
  fails(read_line(handle, 100), "network: operation timed out");
  fails(read_line(handle, 100), "process: channel is closed");
  fails(send_line(handle, text("late\n")), "process: channel is closed");
  close_process(handle);

  handle = start("Process.spawn_channel", self, "--exit", NULL);
  fails(read_line(handle, 5000), "process: end of input");
  assert(exit_status(handle) == 3);
  close_process(handle);

  handle = start("Process.spawn_channel", self, "--middle", NULL);
  equal(ok(read_line(handle, 10000)), "isolated");
  assert(exit_status(handle) == 0);
  close_process(handle);
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
  assert(!absent(leak)); /* positive control: the parent does hold it */
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
  name_rules();
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
  channel_tests(self);
  assert(uv_os_unsetenv("AGENTICA_PROCESS_TEST") == 0);
  assert(uv_os_unsetenv(AGC_CHANNEL_ENV) == 0);
  assert(agc_io_close(&vm));
  puts("process tests passed");
  return 0;
}

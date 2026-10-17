/* File builtins on native paths: binary round trips and rejected writes leave data intact. */
#include "../core.h"
#include "../services.h"
#include "../file_io.h"

#include <assert.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

static agc_vm vm;
static agc_task *task;

static agc_value string(const char *text) {
  return agc_string_value(agc_make_string(text, strlen(text), 0));
}

static agc_value call(const char *name, agc_value *args) {
  const agc_builtin *builtin = NULL;
  for (size_t k = 0; k < agc_file_builtin_count; k++)
    if (strcmp(agc_file_builtins[k].name, name) == 0) builtin = &agc_file_builtins[k];
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
  assert(r->ok);
  return r->value;
}

static void check_text(agc_value path, const char *text) {
  agc_value args[] = {path, agc_int(5000)};
  const agc_string *got = agc_as_string(&vm, ok(call("File.read_text", args)));
  assert(got->bytes == strlen(text) && memcmp(got->data, text, got->bytes) == 0);
}

int main(void) {
  agc_init();
  agc_io_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  task = agc_alloc(sizeof(agc_task));
  vm.in_turn = true;
  char temporary[4096];
  size_t size = sizeof temporary;
  assert(uv_os_tmpdir(temporary, &size) == 0);
  char pattern[4200];
  assert(snprintf(pattern, sizeof pattern, "%s/agentica-files-XXXXXX", temporary) > 0);
  uv_fs_t req;
  assert(uv_fs_mkdtemp(NULL, &req, pattern, NULL) == 0);
  char *directory = strdup(req.path);
  assert(directory);
  uv_fs_req_cleanup(&req);
  char path[4300];
  assert(snprintf(path, sizeof path, "%s/space name-\xC3\xB1-\xF0\x9F\x99\x82.bin", directory) > 0);
  agc_value file = string(path);
  const char *text = "one\r\ntwo\n\xC3\xB1\xF0\x9F\x99\x82";
  agc_value args[] = {file, string(""), agc_int(5000)};
  ok(call("File.write_text", args));
  check_text(file, "");
  args[1] = string(text);
  ok(call("File.write_text", args));
  check_text(file, text);
  args[1] = string("\nend");
  ok(call("File.append_text", args));
  char appended[128];
  assert(snprintf(appended, sizeof appended, "%s\nend", text) > 0);
  text = appended;
  check_text(file, text);
  unsigned invalid_flags[] = {
    AGC_FS_TRUNCATE, AGC_FS_WRITE | AGC_FS_APPEND | AGC_FS_TRUNCATE,
    AGC_FS_WRITE | AGC_FS_EXCLUSIVE, 1u << 30, AGC_FS_WRITE | AGC_FS_CREATE | AGC_FS_PRIVATE
  };
  for (size_t k = 0; k < sizeof invalid_flags / sizeof invalid_flags[0]; k++) {
    assert(agc_fs_open(path, invalid_flags[k]) == -1 && errno == EINVAL);
    check_text(file, text);
  }
  assert(agc_fs_open(NULL, AGC_FS_WRITE) == -1 && errno == EINVAL);
  assert(agc_fs_open("", AGC_FS_WRITE) == -1 && errno == EINVAL);
  agc_value bad_paths[] = {string(""), agc_string_value(agc_make_string(path, strlen(path) + 1, 0))};
  for (size_t k = 0; k < sizeof bad_paths / sizeof bad_paths[0]; k++) {
    args[0] = bad_paths[k];
    assert(!agc_as_result(&vm, call("File.write_text", args))->ok);
    check_text(file, text);
  }
  args[0] = file;
  args[2] = agc_int(0);
  assert(!agc_as_result(&vm, call("File.write_text", args))->ok);
  check_text(file, text);
  args[1] = string("invalid-mode");
  args[2] = agc_int(5000);
  assert(!agc_as_result(&vm, call("File.open", args))->ok);
  check_text(file, text);
  args[1] = string("write");
  agc_value handle = ok(call("File.open", args));
  agc_list_builder bytes;
  agc_list_builder_sized(&bytes, 256);
  for (int k = 0; k < 256; k++) agc_list_builder_push(&bytes, agc_int(k));
  args[0] = handle;
  args[1] = agc_list_value(agc_list_builder_finish(&bytes));
  ok(call("File.write_bytes", args));
  args[1] = agc_int(5000);
  ok(call("File.flush", args));
  ok(call("File.close", args));
  args[0] = file;
  args[1] = string("read");
  handle = ok(call("File.open", args));
  args[0] = handle;
  args[1] = string("must not write");
  assert(!agc_as_result(&vm, call("File.write", args))->ok);
  agc_list_builder read_bytes;
  agc_list_builder_sized(&read_bytes, 256);
  for (size_t at = 0; at < 256;) {
    size_t count = 256 - at < 17 ? 256 - at : 17;
    args[1] = agc_int((int64_t)count);
    const agc_list *read = agc_as_list(&vm, ok(call("File.read_bytes", args)));
    assert(agc_list_len(read) == count);
    for (size_t k = 0; k < count; k++) {
      agc_value byte = agc_list_get(read, k);
      assert(agc_as_int(&vm, byte) == (int64_t)(at + k));
      agc_list_builder_push(&read_bytes, byte);
    }
    at += count;
  }
  args[1] = agc_int(1);
  assert(agc_list_len(agc_as_list(&vm, ok(call("File.read_bytes", args)))) == 0);
  agc_value original = agc_list_value(agc_list_builder_finish(&read_bytes));
  args[1] = agc_int(5000);
  ok(call("File.close", args));
  args[0] = file;
  args[1] = string("write");
  handle = ok(call("File.open", args));
  args[0] = handle;
  args[1] = original;
  ok(call("File.write_bytes", args));
  args[1] = agc_int(5000);
  ok(call("File.close", args));
  agc_fs_info info;
  assert(agc_fs_stat(path, &info, true) == 0 && AGC_FS_ISREG(info.mode) && info.size == 256);
  agc_value path_arg[] = {file};
  const agc_string *resolved = agc_as_string(&vm, ok(call("Path.real", path_arg)));
  assert(resolved->bytes > 0 && memchr(resolved->data, '\\', resolved->bytes) == NULL);
#ifdef _WIN32
  const char *given[] = {"C:\\one\\..\\two", "\\\\server\\share\\dir\\..\\file"};
  const char *expected[] = {"C:/two", "//server/share/file"};
  for (size_t k = 0; k < 2; k++) {
    path_arg[0] = string(given[k]);
    const agc_string *full = agc_as_string(&vm, ok(call("Path.resolve", path_arg)));
    assert(full->bytes == strlen(expected[k]) && memcmp(full->data, expected[k], full->bytes) == 0);
  }
  agc_value remove_args[] = {file, agc_int(5000)};
  assert(!agc_as_result(&vm, call("Path.remove", remove_args))->ok);
  assert(agc_fs_stat(path, &info, true) == 0 && info.size == 256);
#endif
  int fd = agc_fs_open(path, AGC_FS_READ);
  uint8_t data[257];
  assert(fd >= 0 && agc_fs_read(fd, data, sizeof data) == 256);
  for (int k = 0; k < 256; k++) assert(data[k] == k);
  assert(agc_fs_close(fd) == 0);
  args[0] = file;
  args[1] = string("append");
  handle = ok(call("File.open", args));
  args[0] = handle;
  args[1] = string("tail");
  ok(call("File.write", args));
  agc_close_owned(&vm, task);
  while (task->closing) agc_io_poll(&vm, true);
  fd = agc_fs_open(path, AGC_FS_READ);
  uint8_t final[260];
  assert(fd >= 0 && agc_fs_read(fd, final, sizeof final) == 260);
  assert(memcmp(final + 256, "tail", 4) == 0);
  assert(agc_fs_close(fd) == 0);
  assert(agc_fs_unlink(path) == 0);
  assert(uv_fs_rmdir(NULL, &req, directory, NULL) == 0);
  uv_fs_req_cleanup(&req);
  free(directory);
  assert(agc_io_close(&vm));
  puts("files tests passed");
  return 0;
}

/* File builtins on native paths: binary round trips and rejected writes leave data intact. */
#include "builtin_test.h"
#include "../services.h"
#include "../file_io.h"

#include <assert.h>
#include <errno.h>
#include <stdbool.h>
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
  return agc_test_call(&vm, task, builtin, args);
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

#ifdef _WIN32
/* A value no errno uses: the translation has to overwrite it on every path. */
#define SENTINEL_ERRNO 9999

static void check_error(int from, bool win32, int expected_errno) {
  errno = SENTINEL_ERRNO;
  agc_fs_set_error(win32 ? uv_translate_sys_error(from) : from);
  assert(errno == expected_errno);
}

static void test_error_mapping(void) {
  const struct { int uv_error, expected_errno; } cases[] = {
    {UV_EACCES, EACCES}, {UV_EAGAIN, EAGAIN}, {UV_EBADF, EBADF},
    {UV_EBUSY, EBUSY}, {UV_ECANCELED, ECANCELED}, {UV_ECHARSET, EILSEQ},
    {UV_EEXIST, EEXIST}, {UV_EFAULT, EFAULT}, {UV_EINTR, EINTR},
    {UV_EINVAL, EINVAL}, {UV_EIO, EIO}, {UV_EISDIR, EISDIR}, {UV_ELOOP, ELOOP},
    {UV_EMFILE, EMFILE}, {UV_ENAMETOOLONG, ENAMETOOLONG}, {UV_ENOENT, ENOENT},
    {UV_ENOMEM, ENOMEM}, {UV_ENOSPC, ENOSPC}, {UV_ENOTDIR, ENOTDIR},
    {UV_ENOTEMPTY, ENOTEMPTY}, {UV_ENOTSUP, ENOTSUP}, {UV_EPERM, EPERM},
    {UV_EPIPE, EPIPE}, {UV_EROFS, EROFS}, {UV_ETIMEDOUT, ETIMEDOUT},
    {UV_EXDEV, EXDEV},
    {UV_UNKNOWN, EIO}, {UV_EFTYPE, EIO}, {-1234567, EIO}
  };
  for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++)
    check_error(cases[i].uv_error, false, cases[i].expected_errno);
}

/* The whole chain a native call walks: GetLastError(), libuv, then errno. */
static void test_win32_error_chain(void) {
  const struct { int win_error, expected_errno; } cases[] = {
    {ERROR_SHARING_VIOLATION, EBUSY},
    {ERROR_LOCK_VIOLATION, EBUSY},
    {ERROR_ACCESS_DENIED, EPERM},
    {ERROR_NOT_SAME_DEVICE, EXDEV},
    {ERROR_NOT_SUPPORTED, ENOTSUP},
    {ERROR_OPERATION_ABORTED, ECANCELED},
    {ERROR_DIR_NOT_EMPTY, ENOTEMPTY},
    {ERROR_SEM_TIMEOUT, ETIMEDOUT},
    {ERROR_DIRECTORY, ENOENT},
    {ERROR_FILE_NOT_FOUND, ENOENT},
    {ERROR_PATH_NOT_FOUND, ENOENT},
    {ERROR_FILENAME_EXCED_RANGE, ENAMETOOLONG},
    {ERROR_NO_UNICODE_TRANSLATION, EILSEQ},
    {ERROR_WRITE_PROTECT, EROFS},
    {ERROR_DISK_FULL, ENOSPC},
    {ERROR_TOO_MANY_OPEN_FILES, EMFILE},
    {ERROR_BAD_PIPE, EPIPE},
    {ERROR_INVALID_PARAMETER, EINVAL},
    {ERROR_CANT_RESOLVE_FILENAME, ELOOP},
    {ERROR_INVALID_FUNCTION, EISDIR}
  };
  for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++)
    check_error(cases[i].win_error, true, cases[i].expected_errno);
  /* A Win32 code the vendored libuv does not list keeps the reported I/O error. */
  assert(uv_translate_sys_error(54321) == UV_UNKNOWN);
  check_error(54321, true, EIO);
}
#endif

int main(void) {
#ifdef _WIN32
  test_error_mapping();
  test_win32_error_chain();
#endif
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
  assert(agc_fs_mkdir(NULL, false) == -1 && errno == EINVAL);
  assert(agc_fs_mkdir("", false) == -1 && errno == EINVAL);
  assert(agc_fs_unlink(NULL) == -1 && errno == EINVAL);
  assert(agc_fs_unlink("") == -1 && errno == EINVAL);
  check_text(file, text);
  char child[4300];
  assert(snprintf(child, sizeof child, "%s/child", directory) > 0);
  agc_value dir_args[] = {string(child), agc_int(5000)};
  ok(call("Dir.mkdir", dir_args));
  agc_fs_info child_info;
  assert(agc_fs_stat(child, &child_info, true) == 0 && AGC_FS_ISDIR(child_info.mode));
  agc_value list_args[] = {string(directory), agc_int(5000)};
  const agc_list *names = agc_as_list(&vm, ok(call("Dir.list", list_args)));
  assert(agc_list_len(names) == 2);
  bool found_child = false;
  for (size_t k = 0; k < agc_list_len(names); k++) {
    const agc_string *name = agc_as_string(&vm, agc_list_get(names, k));
    if (name->bytes == 5 && memcmp(name->data, "child", 5) == 0) found_child = true;
  }
  assert(found_child);
  assert(uv_fs_rmdir(NULL, &req, child, NULL) == 0);
  uv_fs_req_cleanup(&req);
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
  agc_value lock_open[] = {file, string("read"), agc_int(5000)};
  agc_value first = ok(call("File.open", lock_open));
  agc_value second = ok(call("File.open", lock_open));
  agc_value lock_args[] = {first, agc_int(5000)};
  assert(agc_as_bool(&vm, ok(call("File.try_lock", lock_args))));
  assert(agc_as_bool(&vm, ok(call("File.try_lock", lock_args))));
  lock_args[0] = second;
  assert(!agc_as_bool(&vm, ok(call("File.try_lock", lock_args))));
  lock_args[0] = first;
  ok(call("File.close", lock_args));
  lock_args[0] = second;
  assert(agc_as_bool(&vm, ok(call("File.try_lock", lock_args))));
  ok(call("File.close", lock_args));
#ifdef _WIN32
  assert(agc_fs_try_lock(-1) == -1 && errno == EBADF);
  int first_lock = agc_fs_open(path, AGC_FS_WRITE);
  int second_lock = agc_fs_open(path, AGC_FS_WRITE);
  assert(first_lock >= 0 && second_lock >= 0);
  assert(agc_fs_try_lock(first_lock) == 0);
  assert(agc_fs_try_lock(second_lock) == -1 && errno == EAGAIN);
  int locked_reader = agc_fs_open(path, AGC_FS_READ);
  uint8_t locked_byte;
  assert(locked_reader >= 0 && agc_fs_read(locked_reader, &locked_byte, 1) == -1);
  assert(agc_fs_close(first_lock) == 0);
  assert(agc_fs_read(locked_reader, &locked_byte, 1) == 1 && locked_byte == 0);
  assert(agc_fs_close(locked_reader) == 0);
  assert(agc_fs_try_lock(second_lock) == 0);
  assert(agc_fs_close(second_lock) == 0);
  const char *given[] = {"C:\\one\\..\\two", "\\\\server\\share\\dir\\..\\file"};
  const char *expected[] = {"C:/two", "//server/share/file"};
  for (size_t k = 0; k < 2; k++) {
    path_arg[0] = string(given[k]);
    const agc_string *full = agc_as_string(&vm, ok(call("Path.resolve", path_arg)));
    assert(full->bytes == strlen(expected[k]) && memcmp(full->data, expected[k], full->bytes) == 0);
  }
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
  size_t file_size = 0;
  fd = agc_fs_bytecode_open(path, false, sizeof final, &file_size);
  assert(fd >= 0 && file_size == sizeof final);
  assert(agc_fs_close(fd) == 0);
  assert(agc_fs_bytecode_open(path, false, sizeof final - 1, &file_size) == -1);
  assert(agc_fs_bytecode_open(directory, false, sizeof final, &file_size) == -1);
  assert(agc_fs_bytecode_open(NULL, false, sizeof final, &file_size) == -1);
  assert(agc_fs_bytecode_open("", false, sizeof final, &file_size) == -1);
  assert(agc_fs_bytecode_open(path, false, sizeof final, NULL) == -1);
  assert(agc_fs_stat(path, &info, true) == 0 && info.size == sizeof final);
  assert(agc_fs_unlink(path) == 0);
  assert(uv_fs_rmdir(NULL, &req, directory, NULL) == 0);
  uv_fs_req_cleanup(&req);
  free(directory);
  assert(agc_io_close(&vm));
  puts("files tests passed");
  return 0;
}

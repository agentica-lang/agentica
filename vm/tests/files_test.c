/* File builtins on native paths: binary round trips and rejected writes leave data intact. */
#include "builtin_test.h"
#include "test_support.h"
#include "scratch_dir.h"
#include "../services.h"
#include "../file_io.h"

#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#include <io.h>
#else
#include <sys/stat.h>
#include <unistd.h>
#endif
#include <string.h>
#include <uv.h>

static agc_vm vm;
static agc_task *task;

/* The SHA-256 digests File.sha256 must return: the empty and "abc" vectors, the padding (55, 56) and block (64)
   boundaries, the 64 KiB chunk boundary, a multi-chunk input and one over the 1 MiB whole-text limit (checked with
   Python's hashlib). */
static const unsigned char sha256_empty[32] = {0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4,
  0xc8, 0x99, 0x6f, 0xb9, 0x24, 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52,
  0xb8, 0x55};
static const unsigned char sha256_abc[32] = {0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40,
  0xde, 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00,
  0x15, 0xad};
static const unsigned char sha256_a55[32] = {0x9f, 0x43, 0x90, 0xf8, 0xd3, 0x0c, 0x2d, 0xd9, 0x2e, 0xc9, 0xf0,
  0x95, 0xb6, 0x5e, 0x2b, 0x9a, 0xe9, 0xb0, 0xa9, 0x25, 0xa5, 0x25, 0x8e, 0x24, 0x1c, 0x9f, 0x1e, 0x91, 0x0f, 0x73,
  0x43, 0x18};
static const unsigned char sha256_a56[32] = {0xb3, 0x54, 0x39, 0xa4, 0xac, 0x6f, 0x09, 0x48, 0xb6, 0xd6, 0xf9,
  0xe3, 0xc6, 0xaf, 0x0f, 0x5f, 0x59, 0x0c, 0xe2, 0x0f, 0x1b, 0xde, 0x70, 0x90, 0xef, 0x79, 0x70, 0x68, 0x6e, 0xc6,
  0x73, 0x8a};
static const unsigned char sha256_a64[32] = {0xff, 0xe0, 0x54, 0xfe, 0x7a, 0xe0, 0xcb, 0x6d, 0xc6, 0x5c, 0x3a,
  0xf9, 0xb6, 0x1d, 0x52, 0x09, 0xf4, 0x39, 0x85, 0x1d, 0xb4, 0x3d, 0x0b, 0xa5, 0x99, 0x73, 0x37, 0xdf, 0x15, 0x46,
  0x68, 0xeb};
static const unsigned char sha256_a65[32] = {0x63, 0x53, 0x61, 0xc4, 0x8b, 0xb9, 0xea, 0xb1, 0x41, 0x98, 0xe7,
  0x6e, 0xa8, 0xab, 0x7f, 0x1a, 0x41, 0x68, 0x5d, 0x6a, 0xd6, 0x2a, 0xa9, 0x14, 0x6d, 0x30, 0x1d, 0x4f, 0x17, 0xeb,
  0x0a, 0xe0};
static const unsigned char sha256_zeros64k[32] = {0xde, 0x2f, 0x25, 0x60, 0x64, 0xa0, 0xaf, 0x79, 0x77, 0x47,
  0xc2, 0xb9, 0x75, 0x05, 0xdc, 0x0b, 0x9f, 0x3d, 0xf0, 0xde, 0x4f, 0x48, 0x9e, 0xac, 0x73, 0x1c, 0x23, 0xae, 0x9c,
  0xa9, 0xcc, 0x31};
static const unsigned char sha256_zeros64k1[32] = {0x32, 0x66, 0x30, 0x4f, 0x31, 0xbe, 0x27, 0x8d, 0x06, 0xc3,
  0xbd, 0x3e, 0xb9, 0xaa, 0x3e, 0x00, 0xc5, 0x9b, 0xed, 0xec, 0x0a, 0x89, 0x0d, 0xe4, 0x66, 0x56, 0x8b, 0x0b, 0x90,
  0xb0, 0xe0, 0x1f};
static const unsigned char sha256_pattern200k[32] = {0xe2, 0x4b, 0xc6, 0x23, 0x81, 0xf1, 0x22, 0x4f, 0xbb,
  0xb7, 0x46, 0x88, 0x66, 0x3f, 0x8f, 0x97, 0x43, 0xb9, 0x68, 0x0b, 0x19, 0x3e, 0xdd, 0x66, 0x68, 0x35, 0xe9, 0x7b,
  0x06, 0xe7, 0x30, 0xeb};
static const unsigned char sha256_pattern2m13[32] = {0xd4, 0xb8, 0x4f, 0x16, 0x5a, 0x59, 0x2a, 0xcd, 0x5d,
  0x38, 0xc4, 0xd1, 0x43, 0x10, 0x4d, 0x24, 0xf5, 0xe5, 0x92, 0x8d, 0xd8, 0x1b, 0x13, 0xb3, 0x8c, 0x64, 0xa5, 0x3a,
  0x6c, 0x0c, 0x01, 0xf9};

static agc_value string(const char *text) {
  return agc_string_value(agc_make_string(text, strlen(text), 0));
}

static agc_value call(const char *name, agc_value *args) {
  const agc_builtin *builtin = NULL;
  for (size_t k = 0; k < agc_file_builtin_count; k++)
    if (strcmp(agc_file_builtins[k].name, name) == 0) builtin = &agc_file_builtins[k];
  for (size_t k = 0; k < agc_zlib_builtin_count; k++)
    if (strcmp(agc_zlib_builtins[k].name, name) == 0) builtin = &agc_zlib_builtins[k];
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
  /* A Win32 code the vendored libuv does not list keeps the reported I/O error.
     54321 is above every code the table has; the assert below fails loudly if a
     libuv update ever starts listing it. */
  assert(uv_translate_sys_error(54321) == UV_UNKNOWN);
  check_error(54321, true, EIO);
}
#endif

static void write_test_file(const char *path, const uint8_t *data, size_t len) {
  FILE *out = fopen(path, "wb");
  assert(out);
  if (len) assert(fwrite(data, 1, len, out) == len);
  assert(fclose(out) == 0);
}

static void check_sha256(agc_value path, const unsigned char expected[32]) {
  agc_value args[] = {path, agc_int(5000)};
  const agc_list *digest = agc_as_list(&vm, ok(call("File.sha256", args)));
  assert(agc_list_len(digest) == 32);
  for (size_t k = 0; k < 32; k++) assert(agc_as_int(&vm, agc_list_get(digest, k)) == expected[k]);
}

/* File.sha256 streams a whole regular file in fixed chunks with O(chunk) memory: the digests around the padding
   (55, 56), block (64) and chunk (64 KiB) boundaries, a multi-chunk input and one over the 1 MiB whole-text limit,
   then the rejections (a missing path, a directory, a FIFO or device that can wait, a bad timeout or path). A FIFO
   is refused at once: the open is non-blocking and the fstat of the descriptor decides, so the call never waits. */
static void test_sha256(const char *directory) {
  char path[4300], other[4300];
  assert(snprintf(path, sizeof path, "%s/sha256-empty.bin", directory) > 0);
  write_test_file(path, NULL, 0);
  check_sha256(string(path), sha256_empty);
  assert(agc_fs_unlink(path) == 0);
  assert(snprintf(path, sizeof path, "%s/sha256-abc.bin", directory) > 0);
  write_test_file(path, (const uint8_t *)"abc", 3);
  check_sha256(string(path), sha256_abc);
  assert(agc_fs_unlink(path) == 0);
  static const struct {
    const char *name;
    size_t len;
    uint8_t fill;
    const unsigned char *digest;
  } bounds[] = {
    {"sha256-a55.bin", 55, 'a', sha256_a55}, {"sha256-a56.bin", 56, 'a', sha256_a56},
    {"sha256-a64.bin", 64, 'a', sha256_a64}, {"sha256-a65.bin", 65, 'a', sha256_a65},
    {"sha256-zeros64k.bin", 65536, 0, sha256_zeros64k},
    {"sha256-zeros64k1.bin", 65537, 0, sha256_zeros64k1},
  };
  uint8_t fill[65537];
  for (size_t k = 0; k < sizeof bounds / sizeof bounds[0]; k++) {
    memset(fill, bounds[k].fill, bounds[k].len);
    assert(snprintf(path, sizeof path, "%s/%s", directory, bounds[k].name) > 0);
    write_test_file(path, fill, bounds[k].len);
    check_sha256(string(path), bounds[k].digest);
    assert(agc_fs_unlink(path) == 0);
  }
  size_t multi = 200000;
  uint8_t *pattern = malloc(multi);
  assert(pattern);
  for (size_t k = 0; k < multi; k++) pattern[k] = (uint8_t)(k % 251);
  assert(snprintf(path, sizeof path, "%s/sha256-multi.bin", directory) > 0);
  write_test_file(path, pattern, multi);
  free(pattern);
  check_sha256(string(path), sha256_pattern200k);
  assert(agc_fs_unlink(path) == 0);
  size_t huge = 2 * 1048576 + 13;
  uint8_t *big = malloc(huge);
  assert(big);
  for (size_t k = 0; k < huge; k++) big[k] = (uint8_t)(k % 251);
  assert(snprintf(other, sizeof other, "%s/sha256-huge with spaces.bin", directory) > 0);
  write_test_file(other, big, huge);
  free(big);
  /* A path with spaces hashes the same bytes; there is no 1 MiB cap on the input. */
  check_sha256(string(other), sha256_pattern2m13);
#ifndef _WIN32
  /* A symlink to a regular file follows it, like File.read_text. */
  assert(snprintf(path, sizeof path, "%s/sha256-link.bin", directory) > 0);
  assert(symlink(other, path) == 0);
  check_sha256(string(path), sha256_pattern2m13);
  assert(agc_fs_unlink(path) == 0);
  /* A FIFO and a device are refused without waiting; a directory too. */
  assert(snprintf(path, sizeof path, "%s/sha256-fifo", directory) > 0);
  assert(mkfifo(path, 0600) == 0);
  agc_value fifo[] = {string(path), agc_int(5000)};
  assert(!agc_as_result(&vm, call("File.sha256", fifo))->ok);
  assert(agc_fs_unlink(path) == 0);
  agc_value device[] = {string("/dev/null"), agc_int(5000)};
  assert(!agc_as_result(&vm, call("File.sha256", device))->ok);
#endif
  agc_value missing[] = {string("missing.bin"), agc_int(5000)};
  assert(!agc_as_result(&vm, call("File.sha256", missing))->ok);
  agc_value is_dir[] = {string(directory), agc_int(5000)};
  assert(!agc_as_result(&vm, call("File.sha256", is_dir))->ok);
  agc_value no_path[] = {string(""), agc_int(5000)};
  assert(!agc_as_result(&vm, call("File.sha256", no_path))->ok);
  agc_value nul[] = {agc_string_value(agc_make_string(other, strlen(other) + 1, 0)), agc_int(5000)};
  assert(!agc_as_result(&vm, call("File.sha256", nul))->ok);
  agc_value bad_timeout[] = {string(other), agc_int(0)};
  assert(!agc_as_result(&vm, call("File.sha256", bad_timeout))->ok);
  assert(agc_fs_unlink(other) == 0);
}

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
  char directory[4300];
  uv_fs_t req;
  agc_test_scratch(directory, &req, "files");
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
  /* A real handle whose LockFileEx fails for another reason must not read as contention: Windows does not lock a
     directory handle, and answers an invalid-handle or access error instead. The live descriptor keeps the early
     invalid-argument return from standing in for the call. */
  int directory_fd = agc_fs_open(directory, AGC_FS_READ);
  assert(directory_fd >= 0 && (intptr_t)_get_osfhandle(directory_fd) != -1);
  assert(agc_fs_try_lock(directory_fd) == -1 && errno != EAGAIN);
  assert(agc_fs_close(directory_fd) == 0);
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
  test_sha256(directory);
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
  assert(agc_io_close(&vm));
  puts("files tests passed");
  return 0;
}

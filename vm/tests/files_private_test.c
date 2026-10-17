/* Private-file handoff validation; every consume and cleanup runs in the Docker sandbox. */
#include "../file_io.h"
#include "remove_sandbox.h"

#include <assert.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

int main(void) {
  if (!agc_test_remove_sandbox()) return 1;
  char temporary[4096];
  size_t size = sizeof temporary;
  assert(uv_os_tmpdir(temporary, &size) == 0);
  char pattern[4200];
  assert(snprintf(pattern, sizeof pattern, "%s/agentica-private-XXXXXX", temporary) > 0);
  uv_fs_t request;
  assert(uv_fs_mkdtemp(NULL, &request, pattern, NULL) == 0);
  char *directory = strdup(request.path);
  assert(directory != NULL);
  uv_fs_req_cleanup(&request);

  char private_path[4300], alias[4300], sentinel[4300];
  assert(snprintf(private_path, sizeof private_path, "%s/handoff.agcb", directory) > 0);
  assert(snprintf(alias, sizeof alias, "%s/alias.agcb", directory) > 0);
  assert(snprintf(sentinel, sizeof sentinel, "%s/sibling.keep", directory) > 0);
  const uint8_t expected[] = {0, 1, 2, 0xff, 'A'};
  const unsigned flags = AGC_FS_WRITE | AGC_FS_CREATE | AGC_FS_EXCLUSIVE | AGC_FS_PRIVATE;
  assert(agc_fs_open(NULL, flags) == -1);
  assert(agc_fs_open("", flags) == -1);
  int fd = agc_fs_open(private_path, flags);
  assert(fd >= 0 && agc_fs_write(fd, expected, sizeof expected) == sizeof expected);
  assert(agc_fs_close(fd) == 0);
  fd = agc_fs_open(sentinel, AGC_FS_WRITE | AGC_FS_CREATE | AGC_FS_EXCLUSIVE);
  assert(fd >= 0 && agc_fs_write(fd, "preserve", 8) == 8);
  assert(agc_fs_close(fd) == 0);

  agc_fs_info before, after;
  assert(agc_fs_stat(sentinel, &before, true) == 0);
  assert(uv_fs_link(NULL, &request, private_path, alias, NULL) == 0);
  uv_fs_req_cleanup(&request);
  size_t bytecode_size = 0;
  assert(agc_fs_bytecode_open(private_path, true, sizeof expected, &bytecode_size) == -1);
  assert(agc_fs_stat(private_path, &after, true) == 0 && after.size == sizeof expected);
  assert(agc_fs_stat(alias, &after, true) == 0 && after.size == sizeof expected);
  assert(agc_fs_unlink(alias) == 0);
  assert(agc_fs_bytecode_open(private_path, true, sizeof expected - 1, &bytecode_size) == -1);
  assert(agc_fs_stat(private_path, &after, true) == 0 && after.size == sizeof expected);

  fd = agc_fs_bytecode_open(private_path, true, sizeof expected, &bytecode_size);
  assert(fd >= 0 && bytecode_size == sizeof expected);
  uint8_t got[sizeof expected];
  assert(agc_fs_read(fd, got, sizeof got) == sizeof got);
  assert(memcmp(got, expected, sizeof got) == 0);
  assert(agc_fs_close(fd) == 0);
  assert(agc_fs_stat(private_path, &after, false) == -1 && errno == ENOENT);
  assert(agc_fs_stat(sentinel, &after, true) == 0);
  assert(before.dev == after.dev && before.ino == after.ino && before.size == after.size);

  assert(agc_fs_unlink(sentinel) == 0);
  assert(uv_fs_rmdir(NULL, &request, directory, NULL) == 0);
  uv_fs_req_cleanup(&request);
  free(directory);
  puts("private-file tests passed");
  return 0;
}

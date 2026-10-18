/* Deterministic native enumeration/open races, confined to Actions scratch.
 * Interposition belongs only to this test binary; production has no test hooks. */
#ifdef _WIN32
#include "../file_io.h"
#include "remove_sandbox.h"
#include <assert.h>
#include <errno.h>
#include <stdlib.h>
#include <uv.h>
#include <windows.h>
#include <wchar.h>

static wchar_t victim[4096], away[4096], outside[4096];
static unsigned race_mode, intercepted;

static BOOL WINAPI enumerate_then_replace(HANDLE file, FILE_INFO_BY_HANDLE_CLASS kind,
                                         LPVOID buffer, DWORD size) {
  BOOL result = GetFileInformationByHandleEx(file, kind, buffer, size);
  if (!result || !race_mode || (kind != FileIdBothDirectoryRestartInfo && kind != FileIdBothDirectoryInfo))
    return result;
  FILE_ID_BOTH_DIR_INFO *entry = buffer;
  for (;;) {
    if (entry->FileNameLength == 4 * sizeof(wchar_t) && wmemcmp(entry->FileName, L"swap", 4) == 0) {
      unsigned mode = race_mode;
      race_mode = 0;
      assert(MoveFileW(victim, away));
      if (mode == 2) assert(CreateDirectoryW(victim, NULL));
      if (mode == 3) assert(CreateSymbolicLinkW(victim, outside, SYMBOLIC_LINK_FLAG_DIRECTORY | 2));
      intercepted++;
      break;
    }
    if (!entry->NextEntryOffset) break;
    entry = (FILE_ID_BOTH_DIR_INFO *)((unsigned char *)entry + entry->NextEntryOffset);
  }
  return result;
}

#define GetFileInformationByHandleEx enumerate_then_replace
#include "../file_windows.c"
#undef GetFileInformationByHandleEx

static void child_path(wchar_t *result, const wchar_t *parent, const wchar_t *name) {
  int length = swprintf(result, 4096, L"%ls\\%ls", parent, name);
  assert(length > 0 && length < 4096);
}

int main(void) {
  const char *scratch = getenv("AGENTICA_REMOVE_TEST_SCRATCH");
  if (!agc_test_remove_sandbox(scratch)) return 1;
  char pattern[4200];
  assert(snprintf(pattern, sizeof pattern, "%s/agentica-races-XXXXXX", scratch) > 0);
  uv_fs_t request;
  assert(uv_fs_mkdtemp(NULL, &request, pattern, NULL) == 0);
  char *directory = strdup(request.path);
  assert(directory);
  uv_fs_req_cleanup(&request);
  wchar_t root[4096], tree[4096], sentinel[4096];
  assert(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, directory, -1, root, 4096));
  child_path(tree, root, L"tree");
  child_path(victim, tree, L"swap");
  child_path(away, root, L"away");
  child_path(outside, root, L"outside");
  child_path(sentinel, outside, L"keep");
  assert(CreateDirectoryW(outside, NULL));
  HANDLE keep = CreateFileW(sentinel, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                            CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
  assert(keep != INVALID_HANDLE_VALUE);
  DWORD transferred;
  assert(WriteFile(keep, "preserve", 8, &transferred, NULL) && transferred == 8);
  BY_HANDLE_FILE_INFORMATION before, after;
  assert(GetFileInformationByHandle(keep, &before));
  for (unsigned mode = 1; mode <= 3; mode++) {
    assert(CreateDirectoryW(tree, NULL));
    assert(CreateDirectoryW(victim, NULL));
    char tree_utf8[16384];
    assert(WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, tree, -1,
                              tree_utf8, sizeof tree_utf8, NULL, NULL));
    race_mode = mode;
    char *failed = NULL;
    int result = agc_fs_remove_tree(tree_utf8, &failed);
    assert(intercepted == mode && race_mode == 0);
    if (mode == 1) {
      assert(result == 0 && failed == NULL);
      assert(GetFileAttributesW(tree) == INVALID_FILE_ATTRIBUTES);
    } else {
      assert(result == EBUSY && failed != NULL && strstr(failed, "swap"));
      assert(GetFileAttributesW(victim) != INVALID_FILE_ATTRIBUTES);
      assert(RemoveDirectoryW(victim));
      assert(RemoveDirectoryW(tree));
    }
    free(failed);
    assert(RemoveDirectoryW(away));
    assert(GetFileInformationByHandle(keep, &after));
    assert(before.nFileIndexHigh == after.nFileIndexHigh && before.nFileIndexLow == after.nFileIndexLow);
    assert(SetFilePointer(keep, 0, NULL, FILE_BEGIN) != INVALID_SET_FILE_POINTER);
    char data[8];
    assert(ReadFile(keep, data, sizeof data, &transferred, NULL) && transferred == sizeof data);
    assert(memcmp(data, "preserve", sizeof data) == 0);
  }
  assert(CloseHandle(keep));
  assert(DeleteFileW(sentinel));
  assert(RemoveDirectoryW(outside));
  assert(RemoveDirectoryW(root));
  free(directory);
  puts("Windows deterministic remove races passed (vanish, directory, symlink)");
  return 0;
}
#else
#include <stdio.h>
int main(void) {
  puts("Windows remove races: native Windows only");
  return 0;
}
#endif

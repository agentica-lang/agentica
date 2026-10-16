/*
 * Native Windows filesystem and path operations.
 * Converts UTF-8 paths at the operating system boundary.
 * Platform adapter; no VM state or scheduling.
 */
#include "file_io.h"

#ifdef _WIN32
#include <errno.h>
#include <stdlib.h>
#include <uv.h>
#include <windows.h>

void agc_fs_set_error(int result) {
  switch (result) {
    case UV_EACCES: errno = EACCES; break;
    case UV_EBADF: errno = EBADF; break;
    case UV_EEXIST: errno = EEXIST; break;
    case UV_EINTR: errno = EINTR; break;
    case UV_EINVAL: errno = EINVAL; break;
    case UV_EISDIR: errno = EISDIR; break;
    case UV_ELOOP: errno = ELOOP; break;
    case UV_EMFILE: errno = EMFILE; break;
    case UV_ENAMETOOLONG: errno = ENAMETOOLONG; break;
    case UV_ENOENT: errno = ENOENT; break;
    case UV_ENOMEM: errno = ENOMEM; break;
    case UV_ENOSPC: errno = ENOSPC; break;
    case UV_ENOTDIR: errno = ENOTDIR; break;
    case UV_ENOTEMPTY: errno = ENOTEMPTY; break;
    case UV_EPERM: errno = EPERM; break;
    case UV_EPIPE: errno = EPIPE; break;
    case UV_EROFS: errno = EROFS; break;
    default: errno = EIO; break;
  }
}

bool agc_fs_rooted(const char *path, size_t size) {
  return size && (path[0] == '/' || path[0] == '\\' || (size > 1 && path[1] == ':'));
}

char *agc_fs_absolute(const char *path) {
  int len = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  if (!len) { errno = EINVAL; return NULL; }
  wchar_t *wide = malloc((size_t)len * sizeof(wchar_t));
  if (!wide) { errno = ENOMEM; return NULL; }
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, len)) {
    free(wide);
    errno = EINVAL;
    return NULL;
  }
  DWORD size = GetFullPathNameW(wide, 0, NULL, NULL);
  wchar_t *full = size ? malloc((size_t)size * sizeof(wchar_t)) : NULL;
  DWORD written = full ? GetFullPathNameW(wide, size, full, NULL) : 0;
  free(wide);
  if (!written || written >= size) {
    int err = size && !full ? ENOMEM : EINVAL;
    free(full);
    errno = err;
    return NULL;
  }
  len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, full, -1, NULL, 0, NULL, NULL);
  char *out = len ? malloc((size_t)len) : NULL;
  if (!out || !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, full, -1, out, len, NULL, NULL)) {
    free(full);
    free(out);
    errno = ENOMEM;
    return NULL;
  }
  free(full);
  for (char *p = out; *p; p++) if (*p == '\\') *p = '/';
  return out;
}
#endif

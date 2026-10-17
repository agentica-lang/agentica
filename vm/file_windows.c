/*
 * Native Windows filesystem and path operations.
 * Converts UTF-8 paths at the operating system boundary.
 * Platform adapter; no VM state or scheduling.
 */
#include "file_io.h"

#ifdef _WIN32
#include <errno.h>
#include <fcntl.h>
#include <io.h>
#include <string.h>
#include <stdlib.h>
#include <uv.h>
#include <windows.h>
#include <aclapi.h>

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

static wchar_t *native_path(const char *path) {
  if (!path || !*path || (strlen(path) >= 4 && (path[0] == '/' || path[0] == '\\') &&
      (path[1] == '/' || path[1] == '\\') && (path[2] == '.' || path[2] == '?') &&
      (path[3] == '/' || path[3] == '\\'))) {
    errno = EINVAL;
    return NULL;
  }
  int len = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
  if (!len) { errno = EINVAL; return NULL; }
  wchar_t *wide = malloc((size_t)len * sizeof(wchar_t));
  if (!wide) { errno = ENOMEM; return NULL; }
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, len)) {
    free(wide);
    errno = EINVAL;
    return NULL;
  }
  return wide;
}

static TOKEN_USER *current_user(void) {
  HANDLE token;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return NULL;
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, NULL, 0, &size);
  TOKEN_USER *user = size ? malloc(size) : NULL;
  if (user && !GetTokenInformation(token, TokenUser, user, size, &size)) {
    free(user);
    user = NULL;
  }
  CloseHandle(token);
  return user;
}

static bool owner_only(HANDLE file) {
  TOKEN_USER *user = current_user();
  if (!user) return false;
  PSID owner = NULL;
  PACL acl = NULL;
  PSECURITY_DESCRIPTOR security = NULL;
  DWORD rc = GetSecurityInfo(file, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                            &owner, NULL, &acl, NULL, &security);
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  bool valid = rc == ERROR_SUCCESS && owner && EqualSid(owner, user->User.Sid) && acl && acl->AceCount &&
               GetSecurityDescriptorControl(security, &control, &revision) && (control & SE_DACL_PROTECTED);
  for (WORD k = 0; valid && k < acl->AceCount; k++) {
    void *entry = NULL;
    valid = GetAce(acl, k, &entry) && entry;
    if (valid) {
      const ACCESS_ALLOWED_ACE *ace = entry;
      valid = ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE && !(ace->Header.AceFlags & INHERITED_ACE) &&
              EqualSid((PSID)&ace->SidStart, user->User.Sid);
    }
  }
  if (security) LocalFree(security);
  free(user);
  return valid;
}

int agc_fs_private_create(const char *path, bool directory) {
  wchar_t *wide = native_path(path);
  if (!wide) return -1;
  TOKEN_USER *user = current_user();
  if (!user) { free(wide); errno = EACCES; return -1; }
  DWORD bytes = sizeof(ACL) + sizeof(ACCESS_ALLOWED_ACE) - sizeof(DWORD) + GetLengthSid(user->User.Sid);
  PACL acl = malloc(bytes);
  SECURITY_DESCRIPTOR security;
  bool valid = acl && InitializeAcl(acl, bytes, ACL_REVISION) &&
               AddAccessAllowedAceEx(acl, ACL_REVISION, directory ? OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE : 0,
                                     FILE_ALL_ACCESS, user->User.Sid) &&
               InitializeSecurityDescriptor(&security, SECURITY_DESCRIPTOR_REVISION) &&
               SetSecurityDescriptorOwner(&security, user->User.Sid, FALSE) &&
               SetSecurityDescriptorDacl(&security, TRUE, acl, FALSE) &&
               SetSecurityDescriptorControl(&security, SE_DACL_PROTECTED, SE_DACL_PROTECTED);
  SECURITY_ATTRIBUTES attributes = {sizeof attributes, &security, FALSE};
  HANDLE file = INVALID_HANDLE_VALUE;
  bool made = false;
  if (valid) {
    if (directory) {
      made = CreateDirectoryW(wide, &attributes);
    } else {
      file = CreateFileW(wide, GENERIC_WRITE | READ_CONTROL, FILE_SHARE_READ, &attributes, CREATE_NEW,
                         FILE_ATTRIBUTE_NORMAL, NULL);
      made = file != INVALID_HANDLE_VALUE;
    }
  }
  DWORD error = valid ? GetLastError() : ERROR_ACCESS_DENIED;
  free(acl);
  free(user);
  free(wide);
  if (!made) {
    agc_fs_set_error(uv_translate_sys_error((int)error));
    return -1;
  }
  if (directory) return 0;
  int fd = _open_osfhandle((intptr_t)file, _O_WRONLY | _O_BINARY | _O_NOINHERIT);
  if (fd < 0) CloseHandle(file);
  return fd;
}

int agc_fs_private_read(const char *path, size_t maximum, size_t *size) {
  if (!size) { errno = EINVAL; return -1; }
  wchar_t *wide = native_path(path);
  if (!wide) return -1;
  HANDLE file = CreateFileW(wide, GENERIC_READ | READ_CONTROL | DELETE, FILE_SHARE_READ, NULL,
                            OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  DWORD error = GetLastError();
  free(wide);
  if (file == INVALID_HANDLE_VALUE) {
    agc_fs_set_error(uv_translate_sys_error((int)error));
    return -1;
  }
  BY_HANDLE_FILE_INFORMATION info;
  bool valid = GetFileType(file) == FILE_TYPE_DISK && GetFileInformationByHandle(file, &info) &&
               !(info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) &&
               info.nNumberOfLinks == 1 && owner_only(file);
  uint64_t bytes = valid ? ((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow : 0;
  if (!valid || bytes > maximum) {
    CloseHandle(file);
    errno = EACCES;
    return -1;
  }
  int fd = _open_osfhandle((intptr_t)file, _O_RDONLY | _O_BINARY | _O_NOINHERIT);
  if (fd < 0) { CloseHandle(file); return -1; }
  FILE_DISPOSITION_INFO disposition = {.DeleteFile = TRUE};
  if (!SetFileInformationByHandle(file, FileDispositionInfo, &disposition, sizeof disposition)) {
    error = GetLastError();
    _close(fd);
    agc_fs_set_error(uv_translate_sys_error((int)error));
    return -1;
  }
  *size = (size_t)bytes;
  return fd;
}

char *agc_fs_absolute(const char *path) {
  wchar_t *wide = native_path(path);
  if (!wide) return NULL;
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
  int len = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, full, -1, NULL, 0, NULL, NULL);
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

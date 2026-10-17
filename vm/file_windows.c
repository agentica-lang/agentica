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
#include <wchar.h>
#include <uv.h>
#include <windows.h>
#include <aclapi.h>

typedef struct {
  TOKEN_USER *user;
  PACL acl;
  SECURITY_DESCRIPTOR descriptor;
} private_security;

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

static void free_security(private_security *security) {
  free(security->acl);
  free(security->user);
}

static bool make_security(private_security *security, bool directory) {
  memset(security, 0, sizeof *security);
  security->user = current_user();
  if (!security->user) return false;
  PSID sid = security->user->User.Sid;
  DWORD bytes = sizeof(ACL) + sizeof(ACCESS_ALLOWED_ACE) - sizeof(DWORD) + GetLengthSid(sid);
  security->acl = malloc(bytes);
  return security->acl && InitializeAcl(security->acl, bytes, ACL_REVISION) &&
         AddAccessAllowedAceEx(security->acl, ACL_REVISION, directory ? OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE : 0,
                               FILE_ALL_ACCESS, sid) &&
         InitializeSecurityDescriptor(&security->descriptor, SECURITY_DESCRIPTOR_REVISION) &&
         SetSecurityDescriptorOwner(&security->descriptor, sid, FALSE) &&
         SetSecurityDescriptorDacl(&security->descriptor, TRUE, security->acl, FALSE) &&
         SetSecurityDescriptorControl(&security->descriptor, SE_DACL_PROTECTED, SE_DACL_PROTECTED);
}

static bool private_object(HANDLE file, bool directory) {
  BY_HANDLE_FILE_INFORMATION info;
  return GetFileType(file) == FILE_TYPE_DISK && GetFileInformationByHandle(file, &info) &&
         !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
         ((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) == directory &&
         (directory || info.nNumberOfLinks == 1) && owner_only(file);
}

int agc_fs_private_create(const char *path, bool directory) {
  wchar_t *wide = native_path(path);
  if (!wide) return -1;
  private_security security;
  bool valid = make_security(&security, directory);
  SECURITY_ATTRIBUTES attributes = {sizeof attributes, &security.descriptor, FALSE};
  HANDLE file = INVALID_HANDLE_VALUE;
  bool made = false;
  if (valid) {
    if (directory) {
      made = CreateDirectoryW(wide, &attributes);
      if (made)
        file = CreateFileW(wide, READ_CONTROL | FILE_READ_ATTRIBUTES, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                           FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    } else {
      file = CreateFileW(wide, GENERIC_WRITE | READ_CONTROL | FILE_READ_ATTRIBUTES, FILE_SHARE_READ, &attributes, CREATE_NEW,
                         FILE_ATTRIBUTE_NORMAL, NULL);
      made = file != INVALID_HANDLE_VALUE;
    }
  }
  DWORD error = valid ? GetLastError() : ERROR_ACCESS_DENIED;
  free_security(&security);
  free(wide);
  if (!made) {
    agc_fs_set_error(uv_translate_sys_error((int)error));
    return -1;
  }
  if (file == INVALID_HANDLE_VALUE || !private_object(file, directory)) {
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    errno = EACCES;
    return -1;
  }
  if (directory) { CloseHandle(file); return 0; }
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

int agc_fs_pipepair(int fds[2]) {
  if (!fds) return UV_EINVAL;
  fds[0] = fds[1] = -1;
  uint8_t random[16];
  int rc = uv_random(NULL, NULL, random, sizeof random, 0, NULL);
  if (rc) return rc;
  wchar_t name[80] = L"\\\\.\\pipe\\agentica-";
  size_t prefix = wcslen(name);
  static const wchar_t hex[] = L"0123456789abcdef";
  for (size_t k = 0; k < sizeof random; k++) {
    name[prefix + 2 * k] = hex[random[k] >> 4];
    name[prefix + 2 * k + 1] = hex[random[k] & 15];
  }
  name[prefix + 2 * sizeof random] = 0;
  private_security security;
  if (!make_security(&security, false)) { free_security(&security); return UV_EACCES; }
  SECURITY_ATTRIBUTES attributes = {sizeof attributes, &security.descriptor, FALSE};
  HANDLE server = CreateNamedPipeW(name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
                                   PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                   1, 65536, 65536, 0, &attributes);
  DWORD error = GetLastError();
  free_security(&security);
  if (server == INVALID_HANDLE_VALUE) return uv_translate_sys_error((int)error);
  HANDLE client = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
  if (client == INVALID_HANDLE_VALUE) {
    error = GetLastError();
    CloseHandle(server);
    return uv_translate_sys_error((int)error);
  }
  if (!ConnectNamedPipe(server, NULL) && GetLastError() != ERROR_PIPE_CONNECTED) {
    error = GetLastError();
    CloseHandle(client);
    CloseHandle(server);
    return uv_translate_sys_error((int)error);
  }
  fds[0] = _open_osfhandle((intptr_t)server, _O_RDWR | _O_BINARY | _O_NOINHERIT);
  if (fds[0] < 0) {
    CloseHandle(server);
    CloseHandle(client);
    return UV_EMFILE;
  }
  fds[1] = _open_osfhandle((intptr_t)client, _O_RDWR | _O_BINARY | _O_NOINHERIT);
  if (fds[1] < 0) {
    _close(fds[0]);
    fds[0] = -1;
    CloseHandle(client);
    return UV_EMFILE;
  }
  return 0;
}

int agc_fs_take_channel(int fd) {
  if (uv_guess_handle(fd) != UV_NAMED_PIPE) return -1;
  int taken = _dup(fd);
  if (taken < 0) return -1;
  if (!SetHandleInformation((HANDLE)_get_osfhandle(taken), HANDLE_FLAG_INHERIT, 0)) {
    _close(taken);
    return -1;
  }
  _setmode(taken, _O_BINARY);
  _close(fd);
  return taken;
}

int agc_fs_try_lock(int fd) {
  /* Avoid the CRT invalid-parameter handler for a closed descriptor. */
  if (fd < 0) {
    errno = EBADF;
    return -1;
  }
  intptr_t raw = _get_osfhandle(fd);
  if (raw == -1) {
    errno = EBADF;
    return -1;
  }
  OVERLAPPED range = {0};
  if (LockFileEx((HANDLE)raw, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY, 0, MAXDWORD, MAXDWORD, &range))
    return 0;
  /* Keep contention distinct from access denied: only a held range means try_lock returns false. */
  DWORD error = GetLastError();
  if (error == ERROR_LOCK_VIOLATION)
    errno = EAGAIN;
  else
    agc_fs_set_error(uv_translate_sys_error((int)error));
  return -1;
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

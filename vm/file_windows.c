/*
 * Native Windows filesystem and path operations.
 * Converts UTF-8 paths at the operating system boundary.
 * Platform adapter; no VM state or scheduling.
 */
#include "file_io.h"

#ifdef _WIN32
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <io.h>
#include <string.h>
#include <stdlib.h>
#include <wchar.h>
#include <uv.h>
#include <windows.h>
#include <aclapi.h>
#include <winternl.h>

typedef struct {
  TOKEN_USER *user;
  PACL acl;
  SECURITY_DESCRIPTOR descriptor;
} private_security;

void agc_fs_set_error(int result) {
  switch (result) {
    case UV_EACCES: errno = EACCES; break;
    case UV_EAGAIN: errno = EAGAIN; break;
    case UV_EBADF: errno = EBADF; break;
    case UV_EBUSY: errno = EBUSY; break;
    case UV_ECANCELED: errno = ECANCELED; break;
    case UV_ECHARSET: errno = EILSEQ; break;
    case UV_EEXIST: errno = EEXIST; break;
    case UV_EFAULT: errno = EFAULT; break;
    case UV_EINTR: errno = EINTR; break;
    case UV_EINVAL: errno = EINVAL; break;
    case UV_EIO: errno = EIO; break;
    case UV_EISDIR: errno = EISDIR; break;
    case UV_ELOOP: errno = ELOOP; break;
    case UV_EMFILE: errno = EMFILE; break;
    case UV_ENAMETOOLONG: errno = ENAMETOOLONG; break;
    case UV_ENOENT: errno = ENOENT; break;
    case UV_ENOMEM: errno = ENOMEM; break;
    case UV_ENOSPC: errno = ENOSPC; break;
    case UV_ENOTDIR: errno = ENOTDIR; break;
    case UV_ENOTEMPTY: errno = ENOTEMPTY; break;
    case UV_ENOTSUP: errno = ENOTSUP; break;
    case UV_EPERM: errno = EPERM; break;
    case UV_EPIPE: errno = EPIPE; break;
    case UV_EROFS: errno = EROFS; break;
    case UV_ETIMEDOUT: errno = ETIMEDOUT; break;
    case UV_EXDEV: errno = EXDEV; break;
    /* UV_UNKNOWN and the codes with no errno here keep the reported I/O error;
       the Windows CRT has no EFTYPE, so UV_EFTYPE lands here too. */
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

#define REMOVE_MAX_DEPTH 128u
#define REMOVE_MAX_PASSES 64u
#define REMOVE_ENUM_BYTES 65536u

static void remove_failed_path(char **failed, const wchar_t *path) {
  if (!failed || *failed) return;
  int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, -1, NULL, 0, NULL, NULL);
  char *text = size ? malloc((size_t)size) : NULL;
  if (text && WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, -1, text, size, NULL, NULL))
    *failed = text;
  else
    free(text);
}

static void close_handles(HANDLE *handles, size_t count) {
  while (count) CloseHandle(handles[--count]);
}

static int remove_handle(HANDLE file) {
  FILE_DISPOSITION_INFO disposition = {.DeleteFile = TRUE};
  if (SetFileInformationByHandle(file, FileDispositionInfo, &disposition, sizeof disposition)) return 0;
  DWORD error = GetLastError();
  agc_fs_set_error(uv_translate_sys_error((int)error));
  return errno;
}

static int remove_nt_error(NTSTATUS status) {
  ULONG error = RtlNtStatusToDosError(status);
  if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) errno = ENOENT;
  else agc_fs_set_error(uv_translate_sys_error((int)error));
  return errno;
}

static HANDLE remove_open_relative(HANDLE parent, const wchar_t *name, size_t length,
                                   bool directory, bool list_directory, bool delete_access) {
  if (!length || length > USHRT_MAX / sizeof(wchar_t)) { errno = ENAMETOOLONG; return INVALID_HANDLE_VALUE; }
  UNICODE_STRING object_name = {
    .Length = (USHORT)(length * sizeof(wchar_t)),
    .MaximumLength = (USHORT)(length * sizeof(wchar_t)),
    .Buffer = (PWSTR)name,
  };
  OBJECT_ATTRIBUTES attributes;
  InitializeObjectAttributes(&attributes, &object_name, OBJ_CASE_INSENSITIVE, parent, NULL);
  IO_STATUS_BLOCK status_block = {0};
  HANDLE file = INVALID_HANDLE_VALUE;
  ACCESS_MASK access = FILE_READ_ATTRIBUTES | SYNCHRONIZE;
  ULONG options = FILE_OPEN_FOR_BACKUP_INTENT | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT;
  if (delete_access) access |= DELETE;
  if (directory) { access |= FILE_TRAVERSE; options |= FILE_DIRECTORY_FILE; }
  if (list_directory) access |= FILE_LIST_DIRECTORY;
  NTSTATUS status = NtCreateFile(&file, access, &attributes, &status_block, NULL, FILE_ATTRIBUTE_NORMAL,
                                 FILE_SHARE_READ, FILE_OPEN, options, NULL, 0);
  if (status < 0) {
    remove_nt_error(status);
    return INVALID_HANDLE_VALUE;
  }
  return file;
}

static bool remove_file_info(HANDLE file, BY_HANDLE_FILE_INFORMATION *info) {
  if (GetFileType(file) != FILE_TYPE_DISK) { errno = EINVAL; return false; }
  if (GetFileInformationByHandle(file, info)) return true;
  DWORD error = GetLastError();
  agc_fs_set_error(uv_translate_sys_error((int)error));
  return false;
}

static uint64_t remove_file_id(const BY_HANDLE_FILE_INFORMATION *info) {
  return ((uint64_t)info->nFileIndexHigh << 32) | info->nFileIndexLow;
}

static bool remove_valid_component(const wchar_t *name, size_t length) {
  if (!length || (length == 1 && name[0] == L'.') ||
      (length == 2 && name[0] == L'.' && name[1] == L'.')) return false;
  for (size_t i = 0; i < length; i++)
    if (!name[i] || name[i] == L'\\' || name[i] == L'/' || name[i] == L':') return false;
  return true;
}

static wchar_t *remove_child_path(const wchar_t *parent, const wchar_t *name, size_t name_length) {
  size_t parent_length = wcslen(parent);
  bool separator = parent_length && parent[parent_length - 1] != L'\\';
  if (parent_length > SIZE_MAX - name_length - (separator ? 2u : 1u)) { errno = ENOMEM; return NULL; }
  size_t length = parent_length + name_length + (separator ? 1u : 0u) + 1u;
  wchar_t *path = malloc(length * sizeof(wchar_t));
  if (!path) { errno = ENOMEM; return NULL; }
  memcpy(path, parent, parent_length * sizeof(wchar_t));
  size_t at = parent_length;
  if (separator) path[at++] = L'\\';
  memcpy(path + at, name, name_length * sizeof(wchar_t));
  path[at + name_length] = 0;
  return path;
}

static bool remove_valid_entry_name(const FILE_ID_BOTH_DIR_INFO *entry) {
  if (!entry->FileNameLength || entry->FileNameLength % sizeof(wchar_t)) return false;
  size_t length = entry->FileNameLength / sizeof(wchar_t);
  if ((length == 1 && entry->FileName[0] == L'.') ||
      (length == 2 && entry->FileName[0] == L'.' && entry->FileName[1] == L'.')) return true;
  return remove_valid_component(entry->FileName, length);
}

static int remove_tree_entry(char **failed, HANDLE parent, const wchar_t *name, size_t name_length,
                             const wchar_t *display_path, unsigned depth, uint64_t expected_id, bool check_id) { // NOLINT(misc-no-recursion)
  HANDLE file = remove_open_relative(parent, name, name_length, false, false, true);
  if (file == INVALID_HANDLE_VALUE) return errno == ENOENT ? 0 : errno;
  int result = 0;
  unsigned char *buffer = NULL;
  BY_HANDLE_FILE_INFORMATION info;
  if (!remove_file_info(file, &info)) { result = errno; goto done; }
  if (check_id && remove_file_id(&info) != expected_id) { result = EBUSY; goto done; }
  bool directory = (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
  bool reparse = (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
  if (!directory || reparse) {
    result = remove_handle(file);
    goto done;
  }
  if (depth >= REMOVE_MAX_DEPTH) { result = AGC_FS_REMOVE_TOO_DEEP; goto done; }
  uint64_t file_id = remove_file_id(&info);
  CloseHandle(file);
  file = INVALID_HANDLE_VALUE;
  file = remove_open_relative(parent, name, name_length, true, true, true);
  if (file == INVALID_HANDLE_VALUE) { result = errno == ENOENT ? 0 : errno; goto done; }
  BY_HANDLE_FILE_INFORMATION directory_info;
  if (!remove_file_info(file, &directory_info)) { result = errno; goto done; }
  if (remove_file_id(&directory_info) != file_id ||
      (directory_info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) { result = EBUSY; goto done; }
  buffer = malloc(REMOVE_ENUM_BYTES);
  if (!buffer) { result = ENOMEM; goto done; }
  for (unsigned attempt = 0; attempt < REMOVE_MAX_PASSES; attempt++) {
    bool restart = true;
    unsigned removed = 0;
    for (;;) {
      FILE_INFO_BY_HANDLE_CLASS info_class = restart ? FileIdBothDirectoryRestartInfo : FileIdBothDirectoryInfo;
      if (!GetFileInformationByHandleEx(file, info_class, buffer, REMOVE_ENUM_BYTES)) {
        DWORD error = GetLastError();
        if (error == ERROR_NO_MORE_FILES) break;
        agc_fs_set_error(uv_translate_sys_error((int)error));
        result = errno;
        goto done;
      }
      restart = false;
      size_t offset = 0;
      for (;;) {
        size_t header = offsetof(FILE_ID_BOTH_DIR_INFO, FileName);
        if (offset > REMOVE_ENUM_BYTES - header) { result = EIO; goto done; }
        FILE_ID_BOTH_DIR_INFO *entry = (FILE_ID_BOTH_DIR_INFO *)(buffer + offset);
        size_t remaining = REMOVE_ENUM_BYTES - offset;
        if (entry->FileNameLength > remaining - header || !remove_valid_entry_name(entry)) {
          result = EIO;
          goto done;
        }
        size_t name_length = entry->FileNameLength / sizeof(wchar_t);
        bool dot = name_length == 1 && entry->FileName[0] == L'.';
        bool dotdot = name_length == 2 && entry->FileName[0] == L'.' && entry->FileName[1] == L'.';
        if (!dot && !dotdot) {
          wchar_t *child_path = remove_child_path(display_path, entry->FileName, name_length);
          if (!child_path) { result = errno; goto done; }
          uint64_t expected_id = (uint64_t)entry->FileId.QuadPart;
          result = remove_tree_entry(failed, file, entry->FileName, name_length, child_path, depth + 1,
                                     expected_id, true);
          free(child_path);
          if (result != 0) goto done;
          removed++;
        }
        if (!entry->NextEntryOffset) break;
        if (entry->NextEntryOffset < header + entry->FileNameLength || entry->NextEntryOffset > remaining ||
            entry->NextEntryOffset % sizeof(ULONG)) {
          result = EIO;
          goto done;
        }
        offset += entry->NextEntryOffset;
      }
    }
    result = remove_handle(file);
    if (result == 0) goto done;
    if (errno != ENOTEMPTY || removed == 0) { result = errno; goto done; }
  }
  result = EBUSY;
done:
  if (result != 0) remove_failed_path(failed, display_path);
  free(buffer);
  if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
  if (result == AGC_FS_REMOVE_TOO_DEEP) return result;
  if (result != 0 && result != errno) errno = result;
  return result;
}

int agc_fs_remove_tree(const char *path, char **failed) {
  if (failed) *failed = NULL;
  wchar_t *wide = native_path(path);
  if (!wide) return errno;
  for (wchar_t *p = wide; *p; p++) if (*p == L'/') *p = L'\\';
  size_t length = wcslen(wide);
  bool drive_path = length >= 3 && wide[1] == L':' && wide[2] == L'\\' &&
                    ((wide[0] >= L'A' && wide[0] <= L'Z') || (wide[0] >= L'a' && wide[0] <= L'z'));
  bool unc_path = length >= 5 && wide[0] == L'\\' && wide[1] == L'\\';
  if (wide[length - 1] == L'\\' || (!drive_path && !unc_path)) {
    free(wide);
    errno = EINVAL;
    return AGC_FS_REMOVE_REFUSED;
  }

  size_t root_prefix;
  HANDLE root;
  if (drive_path) {
    wchar_t drive_root[] = {wide[0], L':', L'\\', 0};
    root = CreateFileW(drive_root, FILE_TRAVERSE | FILE_READ_ATTRIBUTES, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                       FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    root_prefix = 3;
  } else {
    wchar_t *server_end = wcschr(wide + 2, L'\\');
    wchar_t *share_end = server_end ? wcschr(server_end + 1, L'\\') : NULL;
    if (!server_end || server_end == wide + 2 || server_end[1] == 0 || server_end[1] == L'\\') {
      free(wide);
      errno = EINVAL;
      return AGC_FS_REMOVE_REFUSED;
    }
    if (!share_end) {
      free(wide);
      errno = EINVAL;
      return AGC_FS_REMOVE_REFUSED;
    }
    if (share_end == server_end + 1 || !share_end[1]) {
      free(wide);
      errno = EINVAL;
      return AGC_FS_REMOVE_REFUSED;
    }
    wchar_t saved = *share_end;
    *share_end = 0;
    root = CreateFileW(wide, FILE_TRAVERSE | FILE_READ_ATTRIBUTES, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                       FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    *share_end = saved;
    root_prefix = (size_t)(share_end + 1 - wide);
  }
  if (root == INVALID_HANDLE_VALUE) {
    DWORD error = GetLastError();
    free(wide);
    agc_fs_set_error(uv_translate_sys_error((int)error));
    return errno;
  }
  BY_HANDLE_FILE_INFORMATION root_info;
  if (!remove_file_info(root, &root_info)) {
    int error = errno;
    CloseHandle(root);
    free(wide);
    return error;
  }
  if (!(root_info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
      (root_info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    CloseHandle(root);
    free(wide);
    errno = ELOOP;
    return ELOOP;
  }

  size_t capacity = length + 1;
  HANDLE *parents = calloc(capacity, sizeof(HANDLE));
  if (!parents) { CloseHandle(root); free(wide); errno = ENOMEM; return ENOMEM; }
  size_t parent_count = 1;
  parents[0] = root;
  wchar_t *last_sep = wcsrchr(wide, L'\\');
  if (!last_sep || !last_sep[1] || (size_t)(last_sep + 1 - wide) < root_prefix) {
    close_handles(parents, parent_count);
    free(parents);
    free(wide);
    errno = EINVAL;
    return AGC_FS_REMOVE_REFUSED;
  }
  wchar_t *component = wide + root_prefix;
  while (component < last_sep) {
    wchar_t *separator = wcschr(component, L'\\');
    if (!separator || separator > last_sep || separator == component) {
      close_handles(parents, parent_count);
      free(parents);
      free(wide);
      errno = EINVAL;
      return AGC_FS_REMOVE_REFUSED;
    }
    size_t component_length = (size_t)(separator - component);
    if (!remove_valid_component(component, component_length)) {
      close_handles(parents, parent_count);
      free(parents);
      free(wide);
      errno = EINVAL;
      return AGC_FS_REMOVE_REFUSED;
    }
    HANDLE parent = remove_open_relative(parents[parent_count - 1], component, component_length, true, false, false);
    if (parent == INVALID_HANDLE_VALUE) {
      int error = errno;
      close_handles(parents, parent_count);
      free(parents);
      free(wide);
      if (error == ENOENT) return 0;
      return error;
    }
    BY_HANDLE_FILE_INFORMATION info;
    if (!remove_file_info(parent, &info)) {
      int error = errno;
      remove_failed_path(failed, wide);
      CloseHandle(parent);
      close_handles(parents, parent_count);
      free(parents);
      free(wide);
      return error;
    }
    if (!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
      remove_failed_path(failed, wide);
      CloseHandle(parent);
      close_handles(parents, parent_count);
      free(parents);
      free(wide);
      errno = ELOOP;
      return ELOOP;
    }
    parents[parent_count++] = parent;
    component = separator + 1;
  }
  size_t target_length = wcslen(last_sep + 1);
  if (!remove_valid_component(last_sep + 1, target_length)) {
    close_handles(parents, parent_count);
    free(parents);
    free(wide);
    errno = EINVAL;
    return AGC_FS_REMOVE_REFUSED;
  }
  int rc = remove_tree_entry(failed, parents[parent_count - 1], last_sep + 1, target_length, wide, 0, 0, false);
  if (rc != 0) remove_failed_path(failed, wide);
  close_handles(parents, parent_count);
  free(parents);
  free(wide);
  return rc;
}

int agc_fs_rename_noreplace(const char *from, const char *to) {
  wchar_t *wide_from = native_path(from);
  if (!wide_from) return -1;
  wchar_t *wide_to = native_path(to);
  if (!wide_to) {
    free(wide_from);
    return -1;
  }
  if (MoveFileW(wide_from, wide_to)) {
    free(wide_from);
    free(wide_to);
    return 0;
  }
  DWORD error = GetLastError();
  free(wide_from);
  free(wide_to);
  agc_fs_set_error(uv_translate_sys_error((int)error));
  return -1;
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

/*
 * Filesystem primitives shared through libuv.
 * Requests execute synchronously on the existing I/O workers.
 * Platform adapter; no VM state or scheduling.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#define _GNU_SOURCE
#include "file_io.h"

#include <errno.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>
#ifndef _WIN32
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

static int os_result(int64_t result) {
  if (result >= 0) return (int)result;
#ifdef _WIN32
  agc_fs_set_error((int)result);
#else
  errno = (int)-result;
#endif
  return -1;
}

static void copy_info(agc_fs_info *to, const uv_stat_t *from) {
  *to = (agc_fs_info){
    .mode = from->st_mode, .dev = from->st_dev, .ino = from->st_ino, .rdev = from->st_rdev,
    .size = (int64_t)from->st_size, .mtime = from->st_mtim.tv_sec,
    .uid = from->st_uid, .gid = from->st_gid
  };
}

int agc_fs_open(const char *path, unsigned flags) {
  unsigned changes = AGC_FS_CREATE | AGC_FS_EXCLUSIVE | AGC_FS_APPEND | AGC_FS_TRUNCATE | AGC_FS_PRIVATE;
  if (!path || !*path || (flags & ~(changes | AGC_FS_WRITE)) ||
      ((flags & changes) && !(flags & AGC_FS_WRITE)) ||
      ((flags & AGC_FS_PRIVATE) && !(flags & AGC_FS_EXCLUSIVE)) ||
      ((flags & AGC_FS_EXCLUSIVE) && !(flags & AGC_FS_CREATE)) ||
      ((flags & AGC_FS_APPEND) && (flags & AGC_FS_TRUNCATE))) {
    errno = EINVAL;
    return -1;
  }
#ifdef _WIN32
  if (flags & AGC_FS_PRIVATE) return agc_fs_private_create(path, false);
#endif
  int native = flags & AGC_FS_WRITE ? UV_FS_O_WRONLY : UV_FS_O_RDONLY;
  if (flags & AGC_FS_CREATE) native |= UV_FS_O_CREAT;
  if (flags & AGC_FS_EXCLUSIVE) native |= UV_FS_O_EXCL | UV_FS_O_NOFOLLOW;
  if (flags & AGC_FS_APPEND) native |= UV_FS_O_APPEND;
  if (flags & AGC_FS_TRUNCATE) native |= UV_FS_O_TRUNC;
  native |= UV_FS_O_NONBLOCK;
  uv_fs_t req;
  int result = uv_fs_open(NULL, &req, path, native, flags & AGC_FS_PRIVATE ? 0600 : 0666, NULL);
  uv_fs_req_cleanup(&req);
  return os_result(result);
}

int agc_fs_bytecode_open(const char *path, bool private, size_t maximum, size_t *size) {
  if (!path || !*path || !size) { errno = EINVAL; return -1; }
#ifdef _WIN32
  if (private) return agc_fs_private_read(path, maximum, size);
  int fd = agc_fs_open(path, AGC_FS_READ);
  if (fd < 0) return -1;
  agc_fs_info info;
  if (agc_fs_fstat(fd, &info) != 0 || !AGC_FS_ISREG(info.mode) || info.size < 0 ||
      (uint64_t)info.size > maximum) {
    agc_fs_close(fd);
    errno = EINVAL;
    return -1;
  }
  *size = (size_t)info.size;
#else
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | (private ? O_NOFOLLOW : 0));
  if (fd < 0) return -1;
  struct stat info;
  if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 0 ||
      (uint64_t)info.st_size > maximum ||
      (private && (info.st_uid != geteuid() || info.st_nlink != 1 || (info.st_mode & 077) != 0))) {
    close(fd);
    errno = EINVAL;
    return -1;
  }
  if (private) {
    struct stat now;
    if (lstat(path, &now) == 0 && now.st_dev == info.st_dev && now.st_ino == info.st_ino) unlink(path);
  }
  *size = (size_t)info.st_size;
#endif
  return fd;
}

int agc_fs_close(int fd) {
  uv_fs_t req;
  int result = uv_fs_close(NULL, &req, fd, NULL);
  uv_fs_req_cleanup(&req);
  return os_result(result);
}

int64_t agc_fs_read(int fd, void *data, size_t size) {
  uv_buf_t buffer = uv_buf_init(data, (unsigned)(size > INT_MAX ? INT_MAX : size));
  uv_fs_t req;
  int result = uv_fs_read(NULL, &req, fd, &buffer, 1, -1, NULL);
  uv_fs_req_cleanup(&req);
  return os_result(result);
}

int64_t agc_fs_write(int fd, const void *data, size_t size) {
  uv_buf_t buffer = uv_buf_init((char *)data, (unsigned)(size > INT_MAX ? INT_MAX : size));
  uv_fs_t req;
  int result = uv_fs_write(NULL, &req, fd, &buffer, 1, -1, NULL);
  uv_fs_req_cleanup(&req);
  return os_result(result);
}

int agc_fs_stat(const char *path, agc_fs_info *info, bool follow) {
  uv_fs_t req;
  int result = follow ? uv_fs_stat(NULL, &req, path, NULL) : uv_fs_lstat(NULL, &req, path, NULL);
  if (result == 0) copy_info(info, &req.statbuf);
  uv_fs_req_cleanup(&req);
  return os_result(result);
}

int agc_fs_fstat(int fd, agc_fs_info *info) {
  uv_fs_t req;
  int result = uv_fs_fstat(NULL, &req, fd, NULL);
  if (result == 0) copy_info(info, &req.statbuf);
  uv_fs_req_cleanup(&req);
  return os_result(result);
}

int agc_fs_mkdir(const char *path, bool private) {
  if (!path || !*path) {
    errno = EINVAL;
    return -1;
  }
#ifdef _WIN32
  if (private) return agc_fs_private_create(path, true);
#endif
  uv_fs_t req;
  int result = uv_fs_mkdir(NULL, &req, path, private ? 0700 : 0777, NULL);
  uv_fs_req_cleanup(&req);
  return os_result(result);
}

int agc_fs_unlink(const char *path) {
  if (!path || !*path) {
    errno = EINVAL;
    return -1;
  }
  uv_fs_t req;
  int result = uv_fs_unlink(NULL, &req, path, NULL);
  uv_fs_req_cleanup(&req);
  return os_result(result);
}

/* The length of the folder part of PATH, its last separator included (0 for a bare name). */
static size_t folder_length(const char *path) {
  size_t cut = 0;
  for (size_t k = 0; path[k]; k++) {
#ifdef _WIN32
    if (path[k] == '\\') cut = k + 1;
#endif
    if (path[k] == '/') cut = k + 1;
  }
  return cut;
}

int agc_fs_open_beside(const char *path, char **name) {
  static atomic_uint counter;
  *name = NULL;
  if (!path || !*path) {
    errno = EINVAL;
    return -1;
  }
  size_t folder = folder_length(path);
  size_t cap = folder + 48;
  char *candidate = malloc(cap);
  if (!candidate) {
    errno = ENOMEM;
    return -1;
  }
  /* The name does not repeat the file's own, so a long file name cannot make it too long. Only the owner may open it
     (0600) until the caller sets the final mode, so nobody else reads the data while it is written. Another process
     holds a name of this pid's sequence only after a pid reuse; a few tries step past it. */
  int fd = -1;
  for (int attempt = 0; attempt < 16; attempt++) {
    snprintf(candidate, cap, "%.*s.agc-%lu-%u.tmp", (int)folder, path, (unsigned long)uv_os_getpid(),
             atomic_fetch_add(&counter, 1));
    uv_fs_t req;
    int result = uv_fs_open(NULL, &req, candidate,
                            UV_FS_O_WRONLY | UV_FS_O_CREAT | UV_FS_O_EXCL | UV_FS_O_NOFOLLOW, 0600, NULL);
    uv_fs_req_cleanup(&req);
    fd = os_result(result);
    if (fd >= 0 || errno != EEXIST) break;
  }
  *name = candidate;
  return fd;
}

int agc_fs_fsync(int fd) {
  uv_fs_t req;
  int result = uv_fs_fsync(NULL, &req, fd, NULL);
  uv_fs_req_cleanup(&req);
  return os_result(result);
}

void agc_fs_sync_folder(const char *path) {
#ifdef _WIN32
  (void)path;
#else
  size_t folder = folder_length(path);
  char *copy = folder ? strndup(path, folder) : strdup(".");
  if (!copy) return;
  int fd = open(copy, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  free(copy);
  if (fd < 0) return;
  (void)fsync(fd);
  close(fd);
#endif
}

int agc_fs_fchmod(int fd, int mode) {
  uv_fs_t req;
  int result = uv_fs_fchmod(NULL, &req, fd, mode, NULL);
  uv_fs_req_cleanup(&req);
  return os_result(result);
}

int agc_fs_replace(const char *from, const char *to) {
  uv_fs_t req;
  int result = uv_fs_rename(NULL, &req, from, to, NULL);
  uv_fs_req_cleanup(&req);
  return os_result(result);
}

int agc_fs_list(const char *path, char **names, size_t *size, size_t *count) {
  *names = NULL;
  *size = *count = 0;
  size_t cap = 0;
  uv_fs_t req;
  int result = uv_fs_scandir(NULL, &req, path, 0, NULL);
  if (result >= 0) {
    uv_dirent_t entry;
    while ((result = uv_fs_scandir_next(&req, &entry)) == 0) {
      size_t len = strlen(entry.name) + 1;
      if (len > SIZE_MAX - *size) {
        result = UV_ENOMEM;
        break;
      }
      if (*size + len > cap) {
        size_t next = cap ? cap : 256;
        while (next < *size + len && next <= SIZE_MAX / 2) next *= 2;
        if (next < *size + len) next = *size + len;
        char *grown = realloc(*names, next);
        if (!grown) { result = UV_ENOMEM; break; }
        *names = grown;
        cap = next;
      }
      memcpy(*names + *size, entry.name, len);
      *size += len;
      (*count)++;
    }
    if (result == UV_EOF) result = 0;
  }
  uv_fs_req_cleanup(&req);
  return os_result(result);
}

char *agc_fs_realpath(const char *path) {
  uv_fs_t req;
  int result = uv_fs_realpath(NULL, &req, path, NULL);
  char *copy = result == 0 ? strdup(req.ptr) : NULL;
  uv_fs_req_cleanup(&req);
  if (result < 0) os_result(result);
  else if (!copy) errno = ENOMEM;
#ifdef _WIN32
  for (char *p = copy; p && *p; p++) if (*p == '\\') *p = '/';
#endif
  return copy;
}

char *agc_fs_cwd(void) {
  size_t size = 256;
  for (;;) {
    char *path = malloc(size);
    if (!path) { errno = ENOMEM; return NULL; }
    int result = uv_cwd(path, &size);
    if (result == 0) {
#ifdef _WIN32
      for (char *p = path; *p; p++) if (*p == '\\') *p = '/';
#endif
      return path;
    }
    free(path);
    if (result != UV_ENOBUFS) { os_result(result); return NULL; }
  }
}

#ifndef _WIN32
bool agc_fs_rooted(const char *path, size_t size) { return size && path[0] == '/'; }
#endif

/*
 * File I/O types and operations shared by the platform adapters.
 * All paths crossing this interface use UTF-8.
 * Port interface; no VM values or scheduling.
 */
#ifndef AGC_FILE_IO_H
#define AGC_FILE_IO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
  uint64_t mode, dev, ino, rdev;
  int64_t size, mtime, uid, gid;
} agc_fs_info;

#define AGC_FS_ISREG(mode) (((mode) & 0170000) == 0100000)
#define AGC_FS_ISDIR(mode) (((mode) & 0170000) == 0040000)
#define AGC_FS_ISLNK(mode) (((mode) & 0170000) == 0120000)
#define AGC_FS_ISFIFO(mode) (((mode) & 0170000) == 0010000)
#define AGC_FS_ISCHR(mode) (((mode) & 0170000) == 0020000)
#define AGC_FS_ISBLK(mode) (((mode) & 0170000) == 0060000)

enum {
  AGC_FS_READ = 0, AGC_FS_WRITE = 1, AGC_FS_CREATE = 2, AGC_FS_EXCLUSIVE = 4,
  AGC_FS_APPEND = 8, AGC_FS_TRUNCATE = 16, AGC_FS_PRIVATE = 32
};

int agc_fs_open(const char *path, unsigned flags);
int agc_fs_bytecode_open(const char *path, bool private, size_t maximum, size_t *size);
int agc_fs_close(int fd);
int64_t agc_fs_read(int fd, void *data, size_t size);
int64_t agc_fs_write(int fd, const void *data, size_t size);
int agc_fs_stat(const char *path, agc_fs_info *info, bool follow);
int agc_fs_fstat(int fd, agc_fs_info *info);
int agc_fs_mkdir(const char *path, bool private);
int agc_fs_unlink(const char *path);
#ifdef _WIN32
#define AGC_FS_REMOVE_TOO_DEEP (-1)
#define AGC_FS_REMOVE_REFUSED (-2)
int agc_fs_rename_noreplace(const char *from, const char *to);
int agc_fs_remove_tree(const char *path, char **failed);
#endif
int agc_fs_list(const char *path, char **names, size_t *size, size_t *count);
char *agc_fs_cwd(void);
char *agc_fs_realpath(const char *path);
#ifdef _WIN32
void agc_fs_set_error(int result);
int agc_fs_try_lock(int fd);
int agc_fs_private_create(const char *path, bool directory);
int agc_fs_private_read(const char *path, size_t maximum, size_t *size);
char *agc_fs_absolute(const char *path);
#endif
bool agc_fs_rooted(const char *path, size_t size);

#endif

/*
 * File I/O types and operations shared by the platform adapters.
 * All paths crossing this interface use UTF-8.
 * Port interface; no VM values or scheduling.
 */
#ifndef AGC_FILE_IO_H
#define AGC_FILE_IO_H

#include "cchecker.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef _WIN32
#include <wchar.h>
#endif

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
#define AGC_FS_ISSOCK(mode) (((mode) & 0170000) == 0140000)

enum {
  AGC_FS_READ = 0, AGC_FS_WRITE = 1, AGC_FS_CREATE = 2, AGC_FS_EXCLUSIVE = 4,
  AGC_FS_APPEND = 8, AGC_FS_TRUNCATE = 16, AGC_FS_PRIVATE = 32,
  /* With APPEND: the handle may be locked (File.try_lock). Windows then adds read access, which LockFileEx needs. */
  AGC_FS_LOCKABLE = 64,
  /* With PRIVATE: the open file may be opened again, renamed or removed by path while it is open, as a POSIX file
     always may (Path.replace opens it to sync it, then renames it). Only Windows needs it, where the share mode of a
     private create is read alone. */
  AGC_FS_SHARED = 128
};

int agc_fs_open(const char *path, unsigned flags);
int agc_fs_bytecode_open(const char *path, bool private, size_t maximum, size_t *size);
int agc_fs_close(int fd);
/* Clears O_NONBLOCK, which agc_fs_open sets, so reads and writes on the descriptor wait as usual (a file the pool
   reads, a child's stdout); nothing on Windows, where agc_fs_open sets no such flag. */
void agc_fs_blocking(int fd);
int64_t agc_fs_read(int fd, void *data, size_t size);
int64_t agc_fs_write(int fd, const void *data, size_t size);
/* Moves the file position of FD to OFFSET bytes from the start: 0, or -1 with errno (ESPIPE for a pipe). */
int agc_fs_seek(int fd, int64_t offset);
int agc_fs_stat(const char *path, agc_fs_info *info, bool follow);
int agc_fs_fstat(int fd, agc_fs_info *info);
int agc_fs_mkdir(const char *path, bool private);
int agc_fs_unlink(const char *path);
/* A new file in the folder of PATH, named .agc-<pid>-<n>.tmp, opened for writing (exclusive, no link followed) with
   mode 0600. *NAME is the malloc'd name, also on failure (the last name tried, for the error text; NULL only when the
   name could not be made); -1 with errno on failure. */
int agc_fs_open_beside(const char *path, CC_OWNS_OUT char **name);
int agc_fs_fsync(int fd);
/* Flushes the folder of PATH to the disk, so a rename in it lasts; best effort, nothing on Windows. */
void agc_fs_sync_folder(const char *path);
/* The permission bits of the open file FD; on Windows only the owner write bit counts (read-only or not). */
int agc_fs_fchmod(int fd, int mode);
/* agc_fs_fchmod for a copy of a file: 0 also when the file system cannot hold permission bits (EPERM, ENOTSUP or
   EOPNOTSUPP, as on vfat and exFAT), where the file keeps what the system gave it. */
int agc_fs_fchmod_if_able(int fd, int mode);
/* Whether a rename can replace the file that INFO describes: false for a read-only file on Windows, where MoveFileExW
   never replaces one; elsewhere the folder decides, so true. */
bool agc_fs_replaceable(const agc_fs_info *info);
/* The length of the folder part of PATH, its last separator included (0 for a bare name). */
size_t agc_fs_folder_length(const char *path);
/* The permission bits of PATH, a link followed (on Windows through its real path); on Windows only the owner write bit
   counts (read-only or not). */
int agc_fs_chmod(const char *path, int mode);
/* Makes the symbolic link LINK whose text is TARGET (any text, no check that it names something): 0, or -1 with errno
   (EEXIST when LINK exists, ENOTSUP when the system refuses links, as Windows does without the right to make them).
   On Windows a '/' of TARGET becomes '\\', and a target that is a folder (a relative one is read from the folder of LINK)
   makes a folder link. */
int agc_fs_symlink(const char *target, const char *link);
/* The text of the symbolic link at PATH, malloc'd (the caller frees it), or NULL with errno (EINVAL when PATH is not
   a link); on Windows its '\\' are '/'. */
CC_OWNS char *agc_fs_readlink(const char *path);
/* Renames FROM to TO, replacing a file at TO in one step (rename on POSIX, MoveFileExW REPLACE_EXISTING on Windows). */
int agc_fs_replace(const char *from, const char *to);
#ifdef _WIN32
#define AGC_FS_REMOVE_TOO_DEEP (-1)
#define AGC_FS_REMOVE_REFUSED (-2)
int agc_fs_rename_noreplace(const char *from, const char *to);
int agc_fs_remove_tree(const char *path, CC_OWNS_OUT char **failed);
#endif
/* 0; a negative result with errno set when the system call fails; or AGC_FS_LIST_NO_MEMORY, positive so no system
   error matches it, when the names buffer could not grow. *names is the caller's to free in every case. */
#define AGC_FS_LIST_NO_MEMORY 1
int agc_fs_list(const char *path, char **names, size_t *size, size_t *count);
CC_OWNS char *agc_fs_cwd(void);
CC_OWNS char *agc_fs_realpath(const char *path);
#ifdef _WIN32
void agc_fs_set_error(int result);
int agc_fs_try_lock(int fd);
int agc_fs_private_create(const char *path, bool directory, bool shared);
int agc_fs_private_read(const char *path, size_t maximum, size_t *size);
/* The errno of the Win32 ERROR that CreateSymbolicLinkW gave: ENOTSUP when the privilege is not held, EEXIST for an
   access denied where LINK_EXISTS (a folder at the link says that, not "exists"), else libuv's translation. */
int agc_fs_symlink_errno(uint32_t error, bool link_exists);
char *agc_fs_absolute(const char *path);
/* PATH (UTF-8) as a malloc'd UTF-16 string for the wide Windows calls; NULL with errno (EINVAL for bad UTF-8, an
   empty path or a device path such as //./x or //?/x, ENOMEM). */
wchar_t *agc_fs_wide(const char *path);
#endif
bool agc_fs_rooted(const char *path, size_t size);

#endif

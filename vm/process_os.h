/*
 * The rules of command search that differ between systems: what is a path,
 * how PATH splits, which files may run, which names are refused; and whether
 * a child's stdout pipe can be read at once beside libuv. Port interface:
 * plain strings and descriptors, no VM values. Implemented by process_posix.c
 * and process_windows.c. Windows: `\` and drives in paths, `;` and quoted PATH
 * entries, only `.exe` and `.com` (no PATHEXT: `.bat` and `.cmd` need the
 * implicit shell `cmd.exe`), no name with a trailing dot or space or a `:`
 * that is not a drive (an alternate data stream), and no read beside libuv.
 */
#ifndef AGC_PROCESS_OS_H
#define AGC_PROCESS_OS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* True when the command names a path, which is not searched in PATH. */
bool agc_proc_is_path(const char *command, size_t size);

/* False for a command the system would read as another name (see above). */
bool agc_proc_name_ok(const char *command, size_t size);

/* The next nonempty entry of a PATH list. *cursor is the rest of the list
   (NULL at the end); *dir and *size give the entry, without quotes. */
bool agc_proc_next_dir(const char **cursor, const char **dir, size_t *size);

/* True when a file with this name may run as it is. */
bool agc_proc_suffix_ok(const char *path);

/* NULL-terminated suffixes to try, in order, on a name that has none that
   suffix_ok accepts. Empty on systems where every name may run. */
const char *const *agc_proc_suffixes(void);

/* True where agc_proc_read_now can read a pipe that libuv watches. On Windows libuv's overlapped read owns the pipe,
   so nothing is read beside it. */
bool agc_proc_drains(void);

/* Returned by agc_proc_read_now when the pipe holds nothing now. */
#define AGC_PROC_NOTHING INT64_MIN

/* One read of what the pipe holds now, never waiting: the bytes read, 0 at the end, AGC_PROC_NOTHING when nothing is
   there (always on Windows), or the system error number negated. fd is the pipe's descriptor (uv_os_fd_t). */
int64_t agc_proc_read_now(intptr_t fd, uint8_t *buf, size_t len);

#endif

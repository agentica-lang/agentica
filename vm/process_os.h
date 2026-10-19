/*
 * The rules of command search that differ between systems: what is a path,
 * how PATH splits, which files may run, which names are refused. Port
 * interface: plain strings, no VM values. Implemented by process_posix.c and
 * process_windows.c. Windows: `\` and drives in paths, `;` and quoted PATH
 * entries, only `.exe` and `.com` (no PATHEXT: `.bat` and `.cmd` need the
 * implicit shell `cmd.exe`), and no name with a trailing dot or space or a
 * `:` that is not a drive (an alternate data stream).
 */
#ifndef AGC_PROCESS_OS_H
#define AGC_PROCESS_OS_H

#include <stdbool.h>
#include <stddef.h>

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

#endif

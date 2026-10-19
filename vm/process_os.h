/*
 * The rules of command search that differ between systems: what counts as a
 * path, how the PATH list splits, which files may run, and which names are
 * refused. Port interface: plain strings, no VM values, no scheduling.
 * Implemented by process_posix.c and process_windows.c.
 *
 * The real differences: on Windows a command may also use `\` and a drive
 * (`C:`), `PATH` splits at `;` and may quote an entry, only `.exe` and `.com`
 * files run (no `PATHEXT`: `.bat` and `.cmd` need `cmd.exe`, an implicit
 * shell), and a name with a trailing dot or space, or a `:` that is not a
 * drive letter, is refused (the system drops the dot or space, and a `:` names
 * an alternate data stream).
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

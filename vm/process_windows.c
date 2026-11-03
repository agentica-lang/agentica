/*
 * Command search rules and environment names for Windows. Platform adapter
 * (process_os.h); no VM state or scheduling. Only .exe and .com run, PATH
 * splits at ';' and may quote an entry, a variable name ignores case, and a
 * child pipe is read only by libuv.
 * Docs: docs/vm/10-io-processes.md, section 10.4.
 */
#include "process_os.h"

#ifdef _WIN32
#include "value.h"
#include <ctype.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

/* UTF-16 units kept on the stack for one environment name; a longer name goes to malloc memory. */
enum { NAME_UNITS = 256 };

static bool separator(char c) { return c == '/' || c == '\\'; }

bool agc_proc_is_path(const char *command, size_t size) {
  for (size_t k = 0; k < size; k++)
    if (separator(command[k]) || command[k] == ':') return true;
  return false;
}

static const char *const runnable[] = {".exe", ".com", NULL};

static bool ends_with(const char *text, size_t size, const char *suffix) {
  size_t n = strlen(suffix);
  return size >= n && _strnicmp(text + size - n, suffix, n) == 0;
}

/* A `:` is allowed only as the drive letter of `C:\` or `C:/`. The last
   component may not end in a dot or a space, nor in .cmd or .bat: a request
   for x.cmd must not find a planted x.cmd.exe once a suffix is added. */
bool agc_proc_name_ok(const char *command, size_t size) {
  /* The \\?\ and \\.\ prefixes switch off Win32 name parsing (and reach devices), so they are refused outright. */
  if (size >= 4 && separator(command[0]) && separator(command[1]) && (command[2] == '?' || command[2] == '.') &&
      separator(command[3]))
    return false;
  size_t last = 0;
  for (size_t k = 0; k < size; k++) {
    if (separator(command[k])) last = k + 1;
    if (command[k] != ':') continue;
    bool drive = k == 1 && isalpha((unsigned char)command[0]) && size > 2 && separator(command[2]);
    if (!drive) return false;
  }
  if (last >= size) return false;
  char end = command[size - 1];
  return end != '.' && end != ' ' && !ends_with(command, size, ".cmd") && !ends_with(command, size, ".bat");
}

bool agc_proc_next_dir(const char **cursor, const char **dir, size_t *size) {
  while (*cursor) {
    const char *at = *cursor;
    const char *end = strchr(at, ';');
    *cursor = end ? end + 1 : NULL;
    size_t len = end ? (size_t)(end - at) : strlen(at);
    if (len >= 2 && at[0] == '"' && at[len - 1] == '"') {
      at++;
      len -= 2;
    }
    *dir = at;
    *size = len;
    if (len) return true;
  }
  return false;
}

bool agc_proc_suffix_ok(const char *path) {
  size_t size = strlen(path);
  for (const char *const *suffix = runnable; *suffix; suffix++)
    if (ends_with(path, size, *suffix)) return true;
  return false;
}

const char *const *agc_proc_suffixes(void) { return runnable; }

/* The UTF-16 of a name: in BUF when it fits, else in malloc memory that the caller frees. *units gets its length.
   A name has at most as many UTF-16 units as UTF-8 bytes. A program's names are valid UTF-8; a host name with a lone
   surrogate (libuv gives WTF-8) gets U+FFFD for it. A name of INT_MAX bytes or more, far over what Windows accepts in
   an environment, is compared on its first INT_MAX. */
static WCHAR *wide_name(const char *name, size_t size, WCHAR *buf, int *units) {
  int bytes = size > INT_MAX ? INT_MAX : (int)size;
  *units = 0;
  if (!bytes) return buf;
  WCHAR *wide = buf;
  if (bytes > NAME_UNITS && !(wide = malloc((size_t)bytes * sizeof *wide))) agc_out_of_memory();
  *units = MultiByteToWideChar(CP_UTF8, 0, name, bytes, wide, bytes);
  return wide;
}

/* CompareStringOrdinal ignoring case, as libuv's make_program_env sorts the block of the child, so `Ä` and `ä` are one
   variable here as there. */
int agc_proc_env_name_compare(const char *a, size_t asize, const char *b, size_t bsize) {
  WCHAR abuf[NAME_UNITS], bbuf[NAME_UNITS];
  int aunits, bunits;
  WCHAR *awide = wide_name(a, asize, abuf, &aunits);
  WCHAR *bwide = wide_name(b, bsize, bbuf, &bunits);
  int order = CompareStringOrdinal(awide, aunits, bwide, bunits, TRUE);
  if (awide != abuf) free(awide);
  if (bwide != bbuf) free(bwide);
  return order - CSTR_EQUAL;
}

bool agc_proc_env_case_blind(void) { return true; }

bool agc_proc_drains(void) { return false; }

int64_t agc_proc_read_now(intptr_t fd, uint8_t *buf, size_t len) {
  (void)fd;
  (void)buf;
  (void)len;
  return AGC_PROC_NOTHING;
}
#endif

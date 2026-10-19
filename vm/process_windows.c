/*
 * Command search rules for Windows. Platform adapter (process_os.h); no VM
 * state or scheduling. Only .exe and .com run, PATH splits at ';' and may
 * quote an entry.
 * Docs: docs/vm/10-io-processes.md, section 10.4.
 */
#include "process_os.h"

#ifdef _WIN32
#include <ctype.h>
#include <string.h>

static bool separator(char c) { return c == '/' || c == '\\'; }

bool agc_proc_is_path(const char *command, size_t size) {
  for (size_t k = 0; k < size; k++)
    if (separator(command[k]) || command[k] == ':') return true;
  return false;
}

/* A `:` is allowed only as the drive letter of `C:\` or `C:/`. The last
   component may not end in a dot or a space. */
bool agc_proc_name_ok(const char *command, size_t size) {
  size_t last = 0;
  for (size_t k = 0; k < size; k++) {
    if (separator(command[k])) last = k + 1;
    if (command[k] != ':') continue;
    bool drive = k == 1 && isalpha((unsigned char)command[0]) && size > 2 && separator(command[2]);
    if (!drive) return false;
  }
  if (last >= size) return false;
  char end = command[size - 1];
  return end != '.' && end != ' ';
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
  return size >= 4 && (_stricmp(path + size - 4, ".exe") == 0 || _stricmp(path + size - 4, ".com") == 0);
}

const char *const *agc_proc_suffixes(void) {
  static const char *const both[] = {".exe", ".com", NULL};
  return both;
}
#endif

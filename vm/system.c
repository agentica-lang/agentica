/*
 * System environment and process identity, independent of child processes.
 * Native UTF-8 environment access comes from libuv on every platform.
 * Service layer; the VM's private channel marker stays hidden.
 */
#include "services.h"

#include <stdlib.h>
#include <string.h>
#include <uv.h>

static bool same_name(const agc_string *name, const char *expected) {
  if (name->bytes != strlen(expected)) return false;
  for (size_t k = 0; k < name->bytes; k++) {
    unsigned char a = (unsigned char)name->data[k], b = (unsigned char)expected[k];
#ifdef _WIN32
    if (a >= 'a' && a <= 'z') a -= 'a' - 'A';
    if (b >= 'a' && b <= 'z') b -= 'a' - 'A';
#endif
    if (a != b) return false;
  }
  return true;
}

char *agc_system_env(const char *name) {
  size_t size = 256;
  char *value = NULL;
  int rc;
  do {
    free(value);
    value = malloc(size);
    if (!value) agc_out_of_memory();
    rc = uv_os_getenv(name, value, &size);
  } while (rc == UV_ENOBUFS);
  if (rc == 0) return value;
  free(value);
  return NULL;
}

static agc_value builtin_env(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  const agc_string *name = agc_as_string(vm, args[0]);
  if (!name->bytes || memchr(name->data, 0, name->bytes) || memchr(name->data, '=', name->bytes))
    return agc_error_value("system: environment variable name must be nonempty and cannot contain = or NUL");
  if (same_name(name, AGC_CHANNEL_ENV) || (vm->rt->drop_uring_env && same_name(name, "UV_USE_IO_URING")))
    return agc_error_value("system: environment variable is not set");
  char *key = agc_cstr(name);
  char *value = agc_system_env(key);
  free(key);
  if (!value) return agc_error_value("system: environment variable is not set");
  agc_string *text = agc_utf8_decode((const uint8_t *)value, strlen(value), "\xEF\xBF\xBD", false);
  free(value);
  return agc_result_value(true, agc_string_value(text));
}

static agc_value builtin_pid(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)vm;
  (void)args;
  (void)span;
  return agc_int((int64_t)uv_os_getpid());
}

static char os_name[sizeof(((uv_utsname_t *)0)->sysname)];
static uv_once_t os_once = UV_ONCE_INIT;

/* The name once, whatever thread asks first: linux, macos and windows for what uv_os_uname calls Linux, Darwin and
   Windows_NT, the lowercase system name for any other, and "unknown" when the system will not say. */
static void find_os(void) {
  uv_utsname_t info;
  if (uv_os_uname(&info) != 0) {
    strcpy(os_name, "unknown");
    return;
  }
  const char *known[][2] = {{"Linux", "linux"}, {"Darwin", "macos"}, {"Windows_NT", "windows"}};
  for (size_t k = 0; k < sizeof known / sizeof known[0]; k++)
    if (strcmp(info.sysname, known[k][0]) == 0) {
      strcpy(os_name, known[k][1]);
      return;
    }
  size_t n = 0;
  for (; info.sysname[n] && n + 1 < sizeof os_name; n++) {
    char c = info.sysname[n];
    os_name[n] = c >= 'A' && c <= 'Z' ? (char)(c - 'A' + 'a') : c;
  }
  os_name[n] = '\0';
}

static agc_value builtin_os(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)vm;
  (void)args;
  (void)span;
  uv_once(&os_once, find_os);
  return agc_string_value(agc_make_string(os_name, strlen(os_name), 0));
}

const agc_builtin agc_system_builtins[] = {
  {"System.env", 1, builtin_env, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"System.os", 0, builtin_os, AGC_NATIVE_NONE, AGC_COST_NONE, false},
  {"System.pid", 0, builtin_pid, AGC_NATIVE_NONE, AGC_COST_NONE, true},
};

const size_t agc_system_builtin_count = sizeof agc_system_builtins / sizeof agc_system_builtins[0];

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

const agc_builtin agc_system_builtins[] = {
  {"System.env", 1, builtin_env, AGC_NATIVE_NONE, AGC_COST_NONE, true},
  {"System.pid", 0, builtin_pid, AGC_NATIVE_NONE, AGC_COST_NONE, true},
};

const size_t agc_system_builtin_count = sizeof agc_system_builtins / sizeof agc_system_builtins[0];

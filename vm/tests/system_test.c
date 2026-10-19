/* Native environment UTF-8, empty/missing/invalid names, the VM process identity and the system name. */
#include "../core.h"
#include "../services.h"

#include <assert.h>
#include <string.h>
#include <uv.h>

static agc_value env(agc_vm *vm, const char *name, size_t size) {
  agc_value argument = agc_string_value(agc_make_string(name, size, 0));
  return agc_system_builtins[0].fn(vm, &argument, 0);
}

static agc_value call(agc_vm *vm, const char *name) {
  for (size_t k = 0; k < agc_system_builtin_count; k++)
    if (strcmp(agc_system_builtins[k].name, name) == 0) return agc_system_builtins[k].fn(vm, NULL, 0);
  assert(!"no such builtin");
  return agc_void();
}

int main(void) {
  agc_init();
  agc_io_init();
  agc_vm vm;
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  const char *name = "AGENTICA_TEST_ENV_\xC3\x91";
  const char *value = "\xC3\xB1\xF0\x9F\x99\x82";
  assert(uv_os_setenv(name, value) == 0);
  const agc_result *r = agc_as_result(&vm, env(&vm, name, strlen(name)));
  assert(r->ok);
  const agc_string *text = agc_as_string(&vm, r->value);
  assert(text->bytes == strlen(value) && memcmp(text->data, value, text->bytes) == 0);
  assert(uv_os_setenv(name, "") == 0);
  r = agc_as_result(&vm, env(&vm, name, strlen(name)));
  assert(r->ok && agc_as_string(&vm, r->value)->bytes == 0);
  assert(uv_os_unsetenv(name) == 0);
  assert(!agc_as_result(&vm, env(&vm, name, strlen(name)))->ok);
  assert(!agc_as_result(&vm, env(&vm, "", 0))->ok);
  assert(!agc_as_result(&vm, env(&vm, "A=B", 3))->ok);
  assert(!agc_as_result(&vm, env(&vm, "A\0B", 3))->ok);
  assert(uv_os_setenv(AGC_CHANNEL_ENV, "private") == 0);
  assert(!agc_as_result(&vm, env(&vm, AGC_CHANNEL_ENV, strlen(AGC_CHANNEL_ENV)))->ok);
#ifdef _WIN32
  assert(!agc_as_result(&vm, env(&vm, "agentica_channel", strlen("agentica_channel")))->ok);
#endif
  assert(uv_os_unsetenv(AGC_CHANNEL_ENV) == 0);
  assert(agc_as_int(&vm, call(&vm, "System.pid")) == (int64_t)uv_os_getpid());
#ifdef _WIN32
  const char *os = "windows";
#elif defined(__APPLE__)
  const char *os = "macos";
#else
  const char *os = "linux";
#endif
  const agc_string *name_of_os = agc_as_string(&vm, call(&vm, "System.os"));
  assert(name_of_os->bytes == strlen(os) && memcmp(name_of_os->data, os, name_of_os->bytes) == 0);
  assert(name_of_os->chars == strlen(os));
  assert(agc_io_close(&vm));
  puts("system tests passed");
  return 0;
}

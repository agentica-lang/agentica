/* Native environment UTF-8, empty/missing/invalid names, the VM process identity, the system name and Std.source. */
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

static agc_value source(agc_vm *vm, const char *path) {
  agc_value argument = agc_string_value(agc_make_string(path, strlen(path), 0));
  return agc_std_builtins[0].fn(vm, &argument, 0);
}

/* A runtime without std sources answers an error; with a table, only an exact path matches. */
static void test_std_source(agc_vm *vm) {
  const agc_result *r = agc_as_result(vm, source(vm, "queue.agc"));
  assert(!r->ok);
  static const uint8_t queue[] = "## queue\n", gherkin[] = "caf\xc3\xa9";
  const agc_std_source table[] = {{"queue.agc", queue, sizeof queue - 1}, {"bdd/gherkin.agc", gherkin, 5}};
  vm->rt->std = table;
  vm->rt->std_count = 2;
  r = agc_as_result(vm, source(vm, "queue.agc"));
  assert(r->ok);
  const agc_string *text = agc_as_string(vm, r->value);
  assert(text->bytes == sizeof queue - 1 && memcmp(text->data, queue, text->bytes) == 0);
  r = agc_as_result(vm, source(vm, "bdd/gherkin.agc"));
  assert(r->ok && agc_as_string(vm, r->value)->chars == 4);
  assert(!agc_as_result(vm, source(vm, "queue"))->ok);
  assert(!agc_as_result(vm, source(vm, "queue.agc2"))->ok);
  assert(!agc_as_result(vm, source(vm, ""))->ok);
  vm->rt->std = NULL;
  vm->rt->std_count = 0;
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
  const char *names[][2] = {{"Linux", "linux"}, {"Darwin", "macos"}, {"Windows_NT", "windows"}, {"FreeBSD", "freebsd"},
                            {"", "unknown"}, {"Caf\xc3\xa9", "unknown"}, {"a\tb", "unknown"}, {NULL, "unknown"}};
  for (size_t k = 0; k < sizeof names / sizeof names[0]; k++) {
    char got[AGC_OS_NAME_MAX];
    agc_system_os_name(names[k][0], got, sizeof got);
    assert(strcmp(got, names[k][1]) == 0);
  }
  char too_long[AGC_OS_NAME_MAX + 1], got[AGC_OS_NAME_MAX];
  memset(too_long, 'x', AGC_OS_NAME_MAX);
  too_long[AGC_OS_NAME_MAX] = '\0';
  agc_system_os_name(too_long, got, sizeof got);
  assert(strcmp(got, "unknown") == 0);
  test_std_source(&vm);
  assert(agc_io_close(&vm));
  puts("system tests passed");
  return 0;
}

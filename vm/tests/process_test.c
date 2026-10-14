/*
 * Process.spawn called as a C function, then agc_io_close, in an order that
 * releases the process guard before its process.
 */
#include "../core.h"
#include "../services.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

#ifdef __linux__
static agc_value text(const char *s) {
  size_t bytes = strlen(s);
  return agc_string_value(agc_make_string(s, bytes, bytes));
}

int main(void) {
  agc_init();
  agc_vm vm;
  agc_io_init();
  agc_vm_init(&vm, NULL, stdout, stderr, INT64_MAX);
  vm.rt->allow_run = true;

  agc_resource *spare = agc_register(&vm, NULL, NULL);
  agc_value rest[] = {text("30")};
  agc_value args[3] = {text("sleep"), agc_list_value(agc_list_from_array(rest, 1)), agc_int(1000)};
  agc_value made = agc_process_builtins[0].fn(&vm, args, 0);
  assert(agc_as_result(&vm, made)->ok);
  agc_unregister(&vm, spare);
  assert(agc_io_close(&vm));
  assert(vm.loop == NULL);
  puts("process tests passed");
  return 0;
}
#else
int main(void) {
  puts("process tests skipped");
  return 0;
}
#endif

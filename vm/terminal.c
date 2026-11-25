/*
 * Terminal: whether a standard stream is a terminal, the raw mode of stdin's terminal and the size of stdout's. The
 * system calls are in vm/stdio_posix.c and vm/stdio_windows.c (agc_tty_*), which also keep the mode that the exit
 * gives back. A resize is the signal System.Signal.Winch (vm/channel.c). Service layer.
 * Design: docs/vm/10-io-scheduler.md §10.2.2.
 */
#include "services.h"

/* Terminal.tty?(stream): the descriptor is the variant's place in Terminal.Stream (Stdin, Stdout, Stderr). */
static agc_value builtin_tty(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  static const char *const names[] = {"Stdin", "Stdout", "Stderr"};
  uint32_t variant = agc_as_enum(vm, args[0])->variant;
  for (int fd = 0; fd < 3; fd++)
    if (agc_builtin_variant(vm, "Terminal.Stream", names[fd], 0) == variant) return agc_bool(agc_tty_is(fd));
  agc_fail(vm, "RUNTIME-INTERNAL", "invalid bytecode: not a Terminal.Stream value", 0);
}

/* Terminal.raw(on): shared, so two tasks never write the saved mode at once. */
static agc_value builtin_raw(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)span;
  int err = agc_tty_raw(agc_as_bool(vm, args[0]));
  if (err) return agc_system_error(vm, AGC_FAMILY_IO, "terminal: could not set the mode of standard input", err);
  return agc_result_value(true, agc_void());
}

static agc_value builtin_size(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  (void)span;
  static const char *const fields[] = {"rows", "cols"};
  int64_t rows = 0, cols = 0;
  int err = agc_tty_size(&rows, &cols);
  if (err) return agc_system_error(vm, AGC_FAMILY_IO, "terminal: could not read the size of the terminal", err);
  agc_struct *s = agc_new_struct(agc_builtin_struct(vm, "Terminal.Size", fields, 2), 2);
  s->fields[0] = agc_int(rows);
  s->fields[1] = agc_int(cols);
  return agc_result_value(true, agc_struct_value(s));
}

const agc_builtin agc_terminal_builtins[] = {
  {"Terminal.raw", 1, builtin_raw, AGC_NATIVE_NONE, AGC_COST_NONE, true, false, false, false},
  {"Terminal.size", 0, builtin_size, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
  {"Terminal.tty?", 1, builtin_tty, AGC_NATIVE_NONE, AGC_COST_NONE, false, false, false, false},
};

const size_t agc_terminal_builtin_count = sizeof agc_terminal_builtins / sizeof agc_terminal_builtins[0];

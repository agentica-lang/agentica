/*
 * The FrontEnd builtins (agc_front_end_builtins): the calls that only the
 * front end of the single binary may make. hand_off gives the compiled
 * program to the driver and ends the front end's run; std_source reads a std/
 * source that the binary carries; stdin_bytes reads the standard input that
 * the front end's runtime does not otherwise have. A user program, or a front end that is run as
 * an ordinary program with `agentica run`, has no agc_front_end in its runtime
 * and fails with RUNTIME-FRONT-END-ONLY. Service layer.
 * Design: docs/vm/08-loader-and-cli.md and docs/future/18-front-end-language.md §18.4.
 */
#include "services.h"

#include <stdio.h>
#include <string.h>

/* The driver sets rt->front_end only for the front end it loads itself, so this one test is the whole guard. */
static agc_front_end *guarded(agc_vm *vm, uint32_t span) {
  agc_front_end *fe = vm->rt->front_end;
  if (!fe) agc_fail(vm, "RUNTIME-FRONT-END-ONLY", "FrontEnd is for the front end of the agentica binary", span);
  return fe;
}

/* The words as NUL-terminated GC strings, which stay valid after the front end's runtime is gone. A word with a
 * character 0 cannot be an argument of a process, so it is refused with its position. */
static char **copy_words(agc_vm *vm, const agc_list *list, const char *what, agc_value *refused) {
  size_t n = agc_list_len(list);
  char **words = agc_alloc(agc_size_mul(n ? n : 1, sizeof *words));
  for (size_t k = 0; k < n; k++) {
    const agc_string *word = agc_as_string(vm, agc_list_get(list, k));
    if (word->bytes && memchr(word->data, 0, word->bytes)) {
      char message[96];
      snprintf(message, sizeof message, "%s %zu has a character 0", what, k + 1);
      *refused = agc_error_value(message);
      return NULL;
    }
    char *copy = agc_alloc_atomic(agc_size_add(word->bytes, 1));
    if (word->bytes) memcpy(copy, word->data, word->bytes);
    copy[word->bytes] = '\0';
    words[k] = copy;
  }
  return words;
}

/* The program must not be larger than a file the loader would take (AGC_MAX_FILE_BYTES), and the words are capped
 * (AGC_FRONT_END_MAX_OPTIONS, AGC_FRONT_END_MAX_ARGUMENTS), so the hand-off cannot make the driver allocate more than a
 * compiled file and a process's arguments ever do, and the driver can count the words in an int. */
static agc_value builtin_hand_off(agc_vm *vm, agc_value *args, uint32_t span) {
  agc_front_end *fe = guarded(vm, span);
  const agc_list *program = agc_as_list(vm, args[0]);
  const agc_list *options = agc_as_list(vm, args[1]);
  const agc_list *arguments = agc_as_list(vm, args[2]);
  if (agc_list_len(options) > AGC_FRONT_END_MAX_OPTIONS) return agc_error_value("too many options");
  if (agc_list_len(arguments) > AGC_FRONT_END_MAX_ARGUMENTS) return agc_error_value("too many arguments");
  uint8_t *bytes = agc_byte_list(vm, program, AGC_MAX_FILE_BYTES);
  if (!bytes) return agc_error_value("the program is not a list of bytes, or it is too large");
  agc_value refused = agc_void();
  char **option_words = copy_words(vm, options, "option", &refused);
  if (!option_words) return refused;
  char **argument_words = copy_words(vm, arguments, "argument", &refused);
  if (!argument_words) return refused;
  fe->handed = true;
  fe->program = bytes;
  fe->program_len = agc_list_len(program);
  fe->options = option_words;
  fe->option_count = agc_list_len(options);
  fe->arguments = argument_words;
  fe->argument_count = agc_list_len(arguments);
  agc_exit(vm, 0);
}

static agc_value builtin_std_source(agc_vm *vm, agc_value *args, uint32_t span) {
  const agc_front_end *fe = guarded(vm, span);
  const agc_string *path = agc_as_string(vm, args[0]);
  for (size_t k = 0; k < fe->std_count; k++) {
    const agc_std_source *source = &fe->std[k];
    if (strlen(source->path) != path->bytes || memcmp(source->path, path->data, path->bytes) != 0) continue;
    return agc_result_value(true, agc_string_value(agc_utf8_decode(source->data, source->len, "\xEF\xBF\xBD", false)));
  }
  return agc_error_value("no such std source");
}

/* All of standard input, read blocking and once: the front end's runtime has no input stream (agc_input_open is for the
 * program that runs after it), so the real descriptor is still the program's, and this is the one place the front end
 * touches it. The front end calls it only for a command that asks (`check --stdin FILE`), so `agentica FILE.agc` leaves
 * the input to the program. stdin is in binary mode (agc_launch_init_streams), so no byte changes on Windows. The bytes
 * or the failure are kept: a second call (the root file is read more than once) gets the same answer. */
static void read_stdin(agc_front_end *fe) {
  size_t cap = 65536, len = 0;
  uint8_t *data = agc_alloc_atomic(cap);
  fe->stdin_read = true;
  for (;;) {
    if (len == cap) {
      uint8_t *grown = agc_alloc_atomic(cap * 2);
      memcpy(grown, data, len);
      data = grown;
      cap *= 2;
    }
    /* One byte past the cap is enough to know that the input is too long. */
    size_t want = cap - len;
    if (len + want > AGC_FRONT_END_MAX_STDIN + 1) want = AGC_FRONT_END_MAX_STDIN + 1 - len;
    size_t got = fread(data + len, 1, want, stdin);
    len += got;
    if (len > AGC_FRONT_END_MAX_STDIN) {
      fe->stdin_error = "standard input is larger than 16777216 bytes"; /* AGC_FRONT_END_MAX_STDIN */
      return;
    }
    if (got < want) {
      if (ferror(stdin)) fe->stdin_error = "cannot read standard input";
      break;
    }
  }
  fe->stdin_data = data;
  fe->stdin_len = len;
}

static agc_value builtin_stdin_bytes(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  agc_front_end *fe = guarded(vm, span);
  if (!fe->stdin_read) read_stdin(fe);
  if (fe->stdin_error) return agc_error_value(fe->stdin_error);
  if (fe->stdin_len == 0) return agc_result_value(true, vm->rt->empty_list);
  agc_list_builder out;
  agc_list_builder_sized(&out, fe->stdin_len);
  for (size_t k = 0; k < fe->stdin_len; k++) agc_list_builder_push(&out, agc_int(fe->stdin_data[k]));
  return agc_result_value(true, agc_list_value(agc_list_builder_finish(&out)));
}

const agc_builtin agc_front_end_builtins[] = {
  {"FrontEnd.hand_off", 3, builtin_hand_off, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
  {"FrontEnd.std_source", 1, builtin_std_source, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
  {"FrontEnd.stdin_bytes", 0, builtin_stdin_bytes, AGC_NATIVE_NONE, AGC_COST_SIZE, true},
};

const size_t agc_front_end_builtin_count = sizeof agc_front_end_builtins / sizeof agc_front_end_builtins[0];

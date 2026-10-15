/*
 * The FrontEnd builtins (agc_front_end_builtins): the two calls that only the
 * front end of the single binary may make. hand_off gives the compiled
 * program to the driver and ends the front end's run; std_source reads a std/
 * source that the binary carries. A user program, or a front end that runs on
 * agentica-vm, has no agc_front_end in its runtime and fails with
 * RUNTIME-FRONT-END-ONLY. Service layer.
 * Design: docs/vm/08-loader-and-cli.md and docs/future/35-self-hosting.md §35.5.
 */
#include "services.h"

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

const agc_builtin agc_front_end_builtins[] = {
  {"FrontEnd.hand_off", 3, builtin_hand_off, AGC_NATIVE_NONE, AGC_COST_SIZE},
  {"FrontEnd.std_source", 1, builtin_std_source, AGC_NATIVE_NONE, AGC_COST_SIZE},
};

const size_t agc_front_end_builtin_count = sizeof agc_front_end_builtins / sizeof agc_front_end_builtins[0];

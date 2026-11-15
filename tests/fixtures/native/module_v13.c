/* A native module built for API 1.3 against a frozen copy of that header (tests/test_vm_native_module.py): the VM of
   a later minor version still loads it, its an_error is an Error of kind "error" and an_get_result gives the message
   of any error as a String. */
#include "agentica_native_1_3.h"

static an_term fail(an_env *env, int argc, const an_term *argv) {
  (void)argc;
  (void)argv;
  return an_error(env, "old", 3);
}

static an_term message(an_env *env, int argc, const an_term *argv) {
  bool ok;
  an_term value;
  (void)argc;
  if (!an_get_result(env, argv[0], &ok, &value)) return an_badarg(env, 0);
  return ok ? an_string(env, "ok", 2) : value;
}

static const an_function functions[] = {
  {"fail", "() -> Result[Int]", fail, AN_SHORT},
  {"message", "(Result[Int]) -> String", message, AN_SHORT},
};

AN_EXPORT const an_module *agentica_native_init(const an_api *api);
AN_EXPORT const an_module *agentica_native_init(const an_api *api) {
  static const an_module module = {AN_API_MAJOR, AN_API_MINOR, sizeof(an_module), "module_v13",
                                   NULL,         functions,    AN_COUNT(functions)};
  (void)api;
  return &module;
}

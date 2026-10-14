#include "core.h"
#include "services.h"

const agc_builtin_table agc_builtin_tables[] = {
  {agc_core_builtins, &agc_core_builtin_count},
  {agc_string_builtins, &agc_string_builtin_count},
  {agc_number_builtins, &agc_number_builtin_count},
  {agc_json_builtins, &agc_json_builtin_count},
  {agc_file_builtins, &agc_file_builtin_count},
  {agc_task_builtins, &agc_task_builtin_count},
  {agc_process_builtins, &agc_process_builtin_count},
  {agc_tcp_builtins, &agc_tcp_builtin_count},
  {agc_http_builtins, &agc_http_builtin_count},
  {agc_http_server_builtins, &agc_http_server_builtin_count},
  {agc_test_builtins, &agc_test_builtin_count},
};

const size_t agc_builtin_table_count = sizeof agc_builtin_tables / sizeof agc_builtin_tables[0];

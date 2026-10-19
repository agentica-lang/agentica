/*
 * The list of every builtin library's table, in lookup order (the first match
 * wins). A new library adds its table here and an extern in services.h (the
 * core tables are declared in core.h). Driver, not a layer. Design:
 * docs/vm/15-layers.md §15.6 (V2).
 */
#include "core.h"
#include "services.h"

const agc_builtin_table agc_builtin_tables[] = {
  {agc_core_builtins, &agc_core_builtin_count, false},
  {agc_string_builtins, &agc_string_builtin_count, false},
  {agc_number_builtins, &agc_number_builtin_count, false},
  {agc_json_builtins, &agc_json_builtin_count, false},
  {agc_file_builtins, &agc_file_builtin_count, true},
  {agc_task_builtins, &agc_task_builtin_count, true},
  {agc_task_map_builtins, &agc_task_map_builtin_count, true},
  {agc_channel_builtins, &agc_channel_builtin_count, true},
  {agc_process_builtins, &agc_process_builtin_count, true},
  {agc_system_builtins, &agc_system_builtin_count, true},
  {agc_duplex_builtins, &agc_duplex_builtin_count, true},
  {agc_tcp_builtins, &agc_tcp_builtin_count, true},
  {agc_http_builtins, &agc_http_builtin_count, true},
  {agc_http_server_builtins, &agc_http_server_builtin_count, true},
  {agc_logger_builtins, &agc_logger_builtin_count, true},
  {agc_test_builtins, &agc_test_builtin_count, true},
  {agc_front_end_builtins, &agc_front_end_builtin_count, true},
};

const size_t agc_builtin_table_count = sizeof agc_builtin_tables / sizeof agc_builtin_tables[0];

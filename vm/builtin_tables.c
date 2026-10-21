/*
 * The list of every builtin library's table, in lookup order (the first match
 * wins). A new library adds its table here and an extern in services.h (the
 * core tables are declared in core.h). Driver, not a layer. Design:
 * docs/vm/15-layers.md §15.6 (V2).
 */
#include "core.h"
#include "services.h"

const agc_builtin_table agc_builtin_tables[] = {
  {agc_core_builtins, &agc_core_builtin_count},
  {agc_string_builtins, &agc_string_builtin_count},
  {agc_number_builtins, &agc_number_builtin_count},
  {agc_crypto_builtins, &agc_crypto_builtin_count},
  {agc_json_builtins, &agc_json_builtin_count},
  {agc_file_builtins, &agc_file_builtin_count},
  {agc_lazy_builtins, &agc_lazy_builtin_count},
  {agc_task_builtins, &agc_task_builtin_count},
  {agc_task_map_builtins, &agc_task_map_builtin_count},
  {agc_channel_builtins, &agc_channel_builtin_count},
  {agc_process_builtins, &agc_process_builtin_count},
  {agc_system_builtins, &agc_system_builtin_count},
  {agc_duplex_builtins, &agc_duplex_builtin_count},
  {agc_tcp_builtins, &agc_tcp_builtin_count},
  {agc_http_service_builtins, &agc_http_service_builtin_count},
  {agc_http_server_builtins, &agc_http_server_builtin_count},
  {agc_http_wire_builtins, &agc_http_wire_builtin_count},
  {agc_logger_builtins, &agc_logger_builtin_count},
  {agc_test_builtins, &agc_test_builtin_count},
  {agc_front_end_builtins, &agc_front_end_builtin_count},
  {agc_ffi_builtins, &agc_ffi_builtin_count},
  {agc_std_builtins, &agc_std_builtin_count},
  {agc_profile_builtins, &agc_profile_builtin_count},
};

const size_t agc_builtin_table_count = sizeof agc_builtin_tables / sizeof agc_builtin_tables[0];

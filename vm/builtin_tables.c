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
  {agc_json_builtins, &agc_json_builtin_count},
  {agc_file_builtins, &agc_file_builtin_count},
  {agc_task_builtins, &agc_task_builtin_count},
  {agc_task_map_builtins, &agc_task_map_builtin_count},
  {agc_channel_builtins, &agc_channel_builtin_count},
  {agc_process_builtins, &agc_process_builtin_count},
  {agc_system_builtins, &agc_system_builtin_count},
  {agc_duplex_builtins, &agc_duplex_builtin_count},
  {agc_tcp_builtins, &agc_tcp_builtin_count},
  {agc_http_builtins, &agc_http_builtin_count},
  {agc_http_server_builtins, &agc_http_server_builtin_count},
  {agc_http_wire_builtins, &agc_http_wire_builtin_count},
  {agc_logger_builtins, &agc_logger_builtin_count},
  {agc_test_builtins, &agc_test_builtin_count},
  {agc_front_end_builtins, &agc_front_end_builtin_count},
};

const size_t agc_builtin_table_count = sizeof agc_builtin_tables / sizeof agc_builtin_tables[0];

/* The tables whose builtins still make their own libuv handles and steps on the scheduler that calls them (HTTP,
   Process, Duplex and the child channel): a run with several schedulers refuses them until those steps are requests
   to the I/O thread (agc_io_uv aborts off that thread). TCP and TLS post every step there (vm/tcp.c). */
static bool loop_bound(const agc_builtin *b) {
  static const agc_builtin_table bound[] = {
    {agc_process_builtins, &agc_process_builtin_count}, {agc_duplex_builtins, &agc_duplex_builtin_count},
    {agc_http_builtins, &agc_http_builtin_count},       {agc_http_server_builtins, &agc_http_server_builtin_count},
  };
  for (size_t k = 0; k < sizeof bound / sizeof bound[0]; k++)
    if (b >= bound[k].entries && b < bound[k].entries + *bound[k].count) return true;
  return false;
}

static agc_value refuse_loop_bound(agc_vm *vm, agc_value *args, uint32_t span) {
  (void)args;
  agc_fail(vm, "RUNTIME-INTERNAL", "this builtin is not available with several schedulers yet", span);
}

/* The program as a run with several schedulers sees it: P itself, or a copy whose loop-bound rows fail with
   RUNTIME-INTERNAL at the call. The refusal lives in the table rather than in the interpreter's builtin call, so the
   loop that runs every program at N = 1 is not changed by it. */
const agc_program *agc_program_for_threads(const agc_program *p) {
  bool any = false;
  for (uint32_t k = 0; k < p->builtin_count && !any; k++) any = p->builtins[k] && loop_bound(p->builtins[k]);
  if (!any) return p;
  agc_program *copy = agc_alloc(sizeof *copy);
  *copy = *p;
  const agc_builtin **table = agc_alloc(agc_size_mul(p->builtin_count, sizeof *table));
  for (uint32_t k = 0; k < p->builtin_count; k++) {
    table[k] = p->builtins[k];
    if (!table[k] || !loop_bound(table[k])) continue;
    agc_builtin *row = agc_alloc(sizeof *row);
    *row = *table[k];
    row->fn = refuse_loop_bound;
    row->native = AGC_NATIVE_NONE;
    row->shared = false;
    table[k] = row;
  }
  copy->builtins = table;
  return copy;
}

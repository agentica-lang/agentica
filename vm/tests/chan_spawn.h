/* Test support for the child channel: starts a test program again, with libuv and no VM, over a channel pair. */
#ifndef AGC_CHAN_SPAWN_H
#define AGC_CHAN_SPAWN_H

#include "../duplex_os.h"
#include "../file_io.h"

#include <assert.h>
#include <string.h>
#include <uv.h>

/* Runs `self mode [extra]` with the standard streams ignored and the first `count` child ends of `ends` in the slots
   from 3 (in reverse order when `swap`), then closes the child ends here. Returns the libuv status of the spawn. */
static inline int chan_spawn(uv_loop_t *loop, uv_process_t *process, const char *self, const char *mode,
                             const char *extra, const agc_chan_ends *ends, int count, bool swap, unsigned flags,
                             uv_exit_cb exited) {
  uv_stdio_container_t stdio[5];
  for (int k = 0; k < 3; k++) stdio[k].flags = UV_IGNORE;
  for (int k = 0; k < count; k++) {
    stdio[3 + k].flags = UV_INHERIT_FD;
    stdio[3 + k].data.fd = ends->child[swap ? count - 1 - k : k];
  }
  char *argv[] = {(char *)self, (char *)mode, (char *)extra, NULL};
  uv_process_options_t options;
  memset(&options, 0, sizeof options);
  options.exit_cb = exited;
  options.file = self;
  options.args = argv;
  options.flags = flags;
  options.stdio_count = 3 + count;
  options.stdio = stdio;
  int rc = uv_spawn(loop, process, &options);
  for (int k = 0; k < ends->child_count; k++) agc_fs_close(ends->child[k]);
  return rc;
}

#endif

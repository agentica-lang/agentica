/*
 * agc_stdio_flush (vm/stdio_posix.c, vm/stdio_windows.c), the flush of stdout and stderr at the end of a run, while
 * another thread holds the lock of stdout as a compute call blocked in fwrite would (#616): the flush of stdout is
 * BUSY and returns, stderr still flushes, and once the lock is free stdout flushes again. On master the flush outside
 * Linux waited for the lock, so this test hung there.
 */
#include "../core.h"

#include <assert.h>
#include <stdio.h>
#include <uv.h>

#if defined(__linux__) || defined(__APPLE__) || defined(_WIN32)
static uv_sem_t held, release;

/* Holds the lock of the stream until main posts RELEASE. */
static void hold(void *arg) {
  FILE *stream = arg;
#ifdef _WIN32
  _lock_file(stream);
#else
  flockfile(stream);
#endif
  uv_sem_post(&held);
  uv_sem_wait(&release);
#ifdef _WIN32
  _unlock_file(stream);
#else
  funlockfile(stream);
#endif
}

int main(void) {
  assert(uv_sem_init(&held, 0) == 0 && uv_sem_init(&release, 0) == 0);
  uv_thread_t holder;
  assert(uv_thread_create(&holder, hold, stdout) == 0);
  uv_sem_wait(&held);
  assert(agc_stdio_flush(stdout) == AGC_STDIO_BUSY);
  /* Asked again while the lock is still held (on Windows the first flush still waits on its thread). */
  assert(agc_stdio_flush(stdout) == AGC_STDIO_BUSY);
  assert(agc_stdio_flush(stderr) == AGC_STDIO_FLUSHED);
  uv_sem_post(&release);
  assert(uv_thread_join(&holder) == 0);
  /* Once the lock is free the stream flushes; on Windows a call may still see the last flush thread finishing. */
  agc_stdio_flush_result result;
  while ((result = agc_stdio_flush(stdout)) == AGC_STDIO_BUSY) {}
  assert(result == AGC_STDIO_FLUSHED);
  uv_sem_destroy(&held);
  uv_sem_destroy(&release);
  puts("stdio_flush tests passed");
  return 0;
}
#else
int main(void) {
  puts("stdio_flush tests passed");
  return 0;
}
#endif

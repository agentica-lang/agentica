/* Standalone Clang TSan control: prove that a race is still reported and that TSan preserves its configured exit code
   through the public finalization hook. */
#define _POSIX_C_SOURCE 200809L
#include <pthread.h>
#include <string.h>
#include <unistd.h>

static volatile int shared_value;
static pthread_barrier_t race_start_barrier;
static pthread_barrier_t race_end_barrier;

static void wait_at_race_barrier(pthread_barrier_t *barrier) {
  int status = pthread_barrier_wait(barrier);
  if (status != 0 && status != PTHREAD_BARRIER_SERIAL_THREAD) _exit(4);
}

static void destroy_race_barriers(void) {
  int start_status = pthread_barrier_destroy(&race_start_barrier);
  int end_status = pthread_barrier_destroy(&race_end_barrier);
  if (start_status != 0 || end_status != 0) _exit(5);
}

static void *race_writer(void *unused) {
  (void)unused;
  wait_at_race_barrier(&race_start_barrier);
  shared_value = 1;
  wait_at_race_barrier(&race_end_barrier);
  return NULL;
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "race") == 0) {
    /* Distinct addresses prevent TSan clock merges between phases; the stores remain unordered. */
    pthread_t thread;
    if (pthread_barrier_init(&race_start_barrier, NULL, 2) != 0) _exit(4);
    if (pthread_barrier_init(&race_end_barrier, NULL, 2) != 0) {
      if (pthread_barrier_destroy(&race_start_barrier) != 0) _exit(5);
      _exit(4);
    }
    if (pthread_create(&thread, NULL, race_writer, NULL) != 0) {
      destroy_race_barriers();
      _exit(2);
    }
    wait_at_race_barrier(&race_start_barrier);
    shared_value = 2;
    wait_at_race_barrier(&race_end_barrier);
    if (pthread_join(thread, NULL) != 0) _exit(3);
    destroy_race_barriers();
    _exit(0);
  }
  _exit(argc > 1 && strcmp(argv[1], "seven") == 0 ? 7 : 0);
}

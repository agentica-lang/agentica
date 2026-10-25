/* Standalone Clang TSan control: prove that a race is still reported and that TSan preserves its configured exit code
   through the public finalization hook. */
#include <pthread.h>
#include <string.h>
#include <unistd.h>

static volatile int shared_value;

static void *race_writer(void *unused) {
  (void)unused;
  shared_value = 1;
  return NULL;
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "race") == 0) {
    pthread_t thread;
    if (pthread_create(&thread, NULL, race_writer, NULL) != 0) _exit(2);
    shared_value = 2;
    if (pthread_join(thread, NULL) != 0) _exit(3);
    _exit(0);
  }
  _exit(argc > 1 && strcmp(argv[1], "seven") == 0 ? 7 : 0);
}

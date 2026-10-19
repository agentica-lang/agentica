/*
 * agc_test_aborts_with: runs a function in a forked child and checks that it aborts with a given message. POSIX only;
 * a separate header because <sys/wait.h> declares wait(), a name some C tests use for their own helper.
 */
#ifndef AGC_TEST_ABORT_H
#define AGC_TEST_ABORT_H

#ifndef _WIN32
#include <assert.h>
#include <signal.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

/* Runs CHILD in a forked child with no core dump and its stderr on a pipe, and checks that the child ends by SIGABRT
   with EXPECTED in what it wrote: an abort for another reason (a failed setup assert) does not pass. */
static inline void agc_test_aborts_with(void (*child)(void), const char *expected) {
  int fds[2];
  assert(pipe(fds) == 0);
  pid_t pid = fork();
  assert(pid >= 0);
  if (pid == 0) {
    struct rlimit none = {0, 0};
    setrlimit(RLIMIT_CORE, &none);
    close(fds[0]);
    dup2(fds[1], 2);
    alarm(60);
    child();
    _exit(0);
  }
  close(fds[1]);
  char message[1024] = {0};
  size_t got = 0;
  for (ssize_t n; got < sizeof message - 1 && (n = read(fds[0], message + got, sizeof message - 1 - got)) > 0;)
    got += (size_t)n;
  close(fds[0]);
  int status = 0;
  assert(waitpid(pid, &status, 0) == pid);
  assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
  assert(strstr(message, expected));
}
#endif

#endif

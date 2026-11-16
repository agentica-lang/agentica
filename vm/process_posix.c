/*
 * Command search rules for POSIX systems, the read of a child pipe beside
 * libuv, and the start of a child on a pseudo-terminal (Linux, macOS).
 * Platform adapter (process_os.h); no VM state or scheduling. Every file may
 * run, a name is only a name, and PATH splits at ':'.
 */
#ifdef __linux__
#define _GNU_SOURCE
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "process_os.h"

#ifndef _WIN32
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>


bool agc_proc_is_path(const char *command, size_t size) { return memchr(command, '/', size) != NULL; }

bool agc_proc_name_ok(const char *command, size_t size) {
  (void)command;
  (void)size;
  return true;
}

bool agc_proc_next_dir(const char **cursor, const char **dir, size_t *size) {
  while (*cursor) {
    const char *at = *cursor;
    const char *end = strchr(at, ':');
    *cursor = end ? end + 1 : NULL;
    *dir = at;
    *size = end ? (size_t)(end - at) : strlen(at);
    if (*size) return true;
  }
  return false;
}

bool agc_proc_suffix_ok(const char *path) {
  (void)path;
  return true;
}

const char *const *agc_proc_suffixes(void) {
  static const char *const none[] = {NULL};
  return none;
}

int agc_proc_env_name_compare(const char *a, size_t asize, const char *b, size_t bsize) {
  int order = memcmp(a, b, asize < bsize ? asize : bsize);
  return order ? order : (asize > bsize) - (asize < bsize);
}

bool agc_proc_env_case_blind(void) { return false; }

bool agc_proc_drains(void) { return true; }

bool agc_proc_groups(void) { return true; }

int64_t agc_proc_read_now(intptr_t fd, uint8_t *buf, size_t len) {
  for (;;) {
    ssize_t n = read((int)fd, buf, len);
    if (n >= 0) return n;
    if (errno == EINTR) continue;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return AGC_PROC_NOTHING;
    return -errno;
  }
}

#if defined(__linux__) || defined(__APPLE__)
bool agc_proc_ptys(void) { return true; }

/* Linux opens both with close-on-exec at once; macOS sets it after, which a fork of another thread in between could
   miss (the VM forks only on the I/O thread). */
#ifdef __linux__
#define OPEN_CLOEXEC O_CLOEXEC
#define make_pipe(fds) pipe2(fds, O_CLOEXEC)
#else
#define OPEN_CLOEXEC 0
#define make_pipe(fds) pipe(fds)
#endif

static int close_on_exec(int fd) {
  int flags = fcntl(fd, F_GETFD);
  return flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0 ? -1 : 0;
}

static ssize_t write_all(int fd, const void *data, size_t len) {
  ssize_t n;
  do n = write(fd, data, len);
  while (n < 0 && errno == EINTR);
  return n;
}

/* The forked child, until its exec: only async-signal-safe calls. The parent learns a failure from ERR_FD, which
   the exec closes. */
static _Noreturn void pty_child(int slave, int err_fd, const char *path, char *const *argv, char *const *env,
                                const char *cwd) {
  struct sigaction dfl;
  memset(&dfl, 0, sizeof dfl);
  dfl.sa_handler = SIG_DFL;
  for (int n = 1; n < 32; n++)
    if (n != SIGKILL && n != SIGSTOP) (void)sigaction(n, &dfl, NULL);
  sigset_t none;
  sigemptyset(&none);
  (void)sigprocmask(SIG_SETMASK, &none, NULL);
  if (err_fd <= 2) err_fd = fcntl(err_fd, F_DUPFD_CLOEXEC, 3);
  if (slave <= 2) slave = fcntl(slave, F_DUPFD, 3);
  bool ready = err_fd >= 0 && slave >= 0 && setsid() >= 0 && ioctl(slave, TIOCSCTTY, 0) == 0;
  // cchecker: ignore CC-GCC-ANALYZER-FD-LEAK: descriptors 0 to 2 are the program's, which execve or _exit ends
  for (int fd = 0; ready && fd < 3; fd++) ready = dup2(slave, fd) == fd;
  if (ready && close(slave) == 0 && (!cwd || chdir(cwd) == 0)) execve(path, argv, env);
  int err = errno;
  (void)write_all(err_fd, &err, sizeof err);
  _exit(127);
}

static int open_pty(int rows, int cols, int *master, int *slave) {
  *master = posix_openpt(O_RDWR | O_NOCTTY | OPEN_CLOEXEC);
  if (*master < 0) return -errno;
  char name[128];
  struct winsize size = {(unsigned short)rows, (unsigned short)cols, 0, 0};
  if (close_on_exec(*master) || grantpt(*master) || unlockpt(*master) || ptsname_r(*master, name, sizeof name) ||
      (*slave = open(name, O_RDWR | O_NOCTTY | O_CLOEXEC)) < 0 || ioctl(*master, TIOCSWINSZ, &size)) {
    int err = errno;
    close(*master);
    if (*slave >= 0) close(*slave);
    *master = *slave = -1;
    return -err;
  }
  return 0;
}

int agc_proc_pty_spawn(const char *path, char *const *argv, char *const *env, const char *cwd, int rows, int cols,
                       int fds[2], int *pid) {
  int slave = -1, report[2] = {-1, -1};
  int rc = open_pty(rows, cols, &fds[0], &slave);
  if (rc) return rc;
  fds[1] = fcntl(fds[0], F_DUPFD_CLOEXEC, 0);
  if (fds[1] < 0 || make_pipe(report) || close_on_exec(report[0]) || close_on_exec(report[1])) rc = -errno;
  pid_t child = rc ? -1 : fork();
  if (child == 0) pty_child(slave, report[1], path, argv, env, cwd);
  if (!rc && child < 0) rc = -errno;
  close(slave);
  if (report[1] >= 0) close(report[1]);
  int err;
  ssize_t n = 0;
  if (!rc) {
    do n = read(report[0], &err, sizeof err);
    while (n < 0 && errno == EINTR);
  }
  if (report[0] >= 0) close(report[0]);
  if (!rc && n == (ssize_t)sizeof err) {
    int status;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    rc = -err;
  }
  if (rc) {
    for (int k = 0; k < 2; k++)
      if (fds[k] >= 0) close(fds[k]);
    fds[0] = fds[1] = -1;
    return rc;
  }
  *pid = (int)child;
  return 0;
  // cchecker: ignore CC-GCC-ANALYZER-FD-LEAK: only the forked child, which execve or _exit ends, keeps report[1]
}

bool agc_proc_reap(int pid, int *code, int *signal) {
  int status;
  pid_t got;
  do got = waitpid((pid_t)pid, &status, WNOHANG);
  while (got < 0 && errno == EINTR);
  if (got != (pid_t)pid) return false;
  *code = WIFEXITED(status) ? WEXITSTATUS(status) : 0;
  *signal = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
  return true;
}

int agc_proc_pty_resize(intptr_t fd, int rows, int cols) {
  struct winsize size = {(unsigned short)rows, (unsigned short)cols, 0, 0};
  return ioctl((int)fd, TIOCSWINSZ, &size) ? -errno : 0;
}
#endif
#endif

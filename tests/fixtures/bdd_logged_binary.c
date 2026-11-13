/* A stand-in for the agentica binary (tests/test_bdd.py): it appends its words, separated by tabs, as one line to
   the file LOGGED_LOG, then runs the binary LOGGED_REAL with the same words and ends with its status. The test builds
   it with both paths given as C string literals (-DLOGGED_REAL="..." -DLOGGED_LOG="...").

   The real binary is a child of the stand-in, not an exec of it (Windows has no exec), so:
   - `run --driver-pid N` names the stand-in's own process id, the parent that the real binary checks;
   - the child keeps every descriptor: on POSIX fork does, on Windows _spawnv passes the C descriptors (3 and 4 carry
     the channel of Process.spawn_channel) the way the VM gave them to the stand-in;
   - on Windows each word is quoted, since _spawnv joins the words with spaces. */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <process.h>
#define getpid _getpid
#else
#include <errno.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#ifdef _WIN32
/* The word as one argument of a Windows command line (the rules of CommandLineToArgvW and the C runtime). */
static char *quoted(const char *word) {
  size_t len = strlen(word);
  char *out = malloc(2 * len + 3);
  if (!out) exit(125);
  char *at = out;
  *at++ = '"';
  for (size_t k = 0; k <= len; k++) {
    size_t slashes = 0;
    while (k < len && word[k] == '\\') {
      slashes++;
      k++;
    }
    /* Backslashes are doubled only before a quote or the closing quote. */
    size_t copies = k == len || word[k] == '"' ? 2 * slashes : slashes;
    for (size_t s = 0; s < copies; s++) *at++ = '\\';
    if (k == len) break;
    if (word[k] == '"') *at++ = '\\';
    *at++ = word[k];
  }
  *at++ = '"';
  *at = '\0';
  return out;
}
#endif

int main(int argc, char **argv) {
  FILE *log = fopen(LOGGED_LOG, "ab");
  if (!log) return 125;
  for (int k = 1; k < argc; k++) fprintf(log, k > 1 ? "\t%s" : "%s", argv[k]);
  fputc('\n', log);
  if (fclose(log) != 0) return 125;

  char pid[32];
  snprintf(pid, sizeof pid, "%d", (int)getpid());
  char **words = calloc((size_t)argc + 1, sizeof *words);
  if (!words) return 125;
  words[0] = LOGGED_REAL;
  bool options = true;
  for (int k = 1; k < argc; k++) {
    bool driver = options && k > 1 && strcmp(argv[k - 1], "--driver-pid") == 0;
    if (strcmp(argv[k], "--") == 0) options = false;
    words[k] = driver ? pid : argv[k];
  }

#ifdef _WIN32
  for (int k = 0; k < argc; k++) words[k] = quoted(words[k]);
  intptr_t status = _spawnv(_P_WAIT, LOGGED_REAL, (const char *const *)words);
  return status < 0 ? 126 : (int)status;
#else
  pid_t child = fork();
  if (child < 0) return 126;
  if (child == 0) {
    execv(LOGGED_REAL, words);
    _exit(126);
  }
  int status;
  while (waitpid(child, &status, 0) < 0)
    if (errno != EINTR) return 126;
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
#endif
}

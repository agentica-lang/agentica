/* Test-only hook for LLVM TSan's documented finalization callback. The owner peer is released after TSan has
   finalized reports, so its own final fflush can run without weakening sanitizer status or reporting. */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>

int __tsan_on_finalize(int failed) {
  int saved_errno = errno;
  const char *text = getenv("AGENTICA_TSAN_RELEASE_FD");
  if (text && *text) {
    errno = 0;
    char *end = NULL;
    long parsed = strtol(text, &end, 10);
    if (errno != ERANGE && end && !*end && parsed >= 3 && parsed <= INT_MAX) {
      int fd = (int)parsed;
      int flags = fcntl(fd, F_GETFL);
      if (flags >= 0 && (flags & O_NONBLOCK)) {
        const unsigned char release = 0x52;
        (void)write(fd, &release, sizeof release);
      }
    }
  }
  errno = saved_errno;
  return failed;
}

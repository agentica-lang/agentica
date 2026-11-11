/* A stand-in resolver for DNS.lookup (tests/test_vm_dns.py), loaded with LD_PRELOAD on Linux, so the tests need no
   DNS server. Only three kinds of name are answered here; every other name goes to the system's getaddrinfo:
   - "slow..." sleeps DNS_SHIM_MS milliseconds (default 1500) on the pool thread, then says EAI_NONAME; it first
     appends the name and a newline to the file DNS_SHIM_LOG, if set, so a test sees which lookups ever started;
   - "missing..." says EAI_NONAME at once;
   - "dup..." lists 127.0.0.2, 127.0.0.1, 127.0.0.2, as a resolver may with two /etc/hosts lines.
   The "dup" list is a chain of the system's own answers for the literals, so the system's freeaddrinfo, which frees
   node by node, frees it. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*lookup_fn)(const char *, const char *, const struct addrinfo *, struct addrinfo **);

static int literal(lookup_fn real, const char *text, struct addrinfo **res) {
  struct addrinfo hints;
  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = AI_NUMERICHOST;
  return real(text, NULL, &hints, res);
}

int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
  lookup_fn real = (lookup_fn)dlsym(RTLD_NEXT, "getaddrinfo");
  if (node && strncmp(node, "slow", 4) == 0) {
    const char *log = getenv("DNS_SHIM_LOG");
    int fd = log ? open(log, O_WRONLY | O_APPEND | O_CREAT, 0644) : -1;
    if (fd >= 0) {
      /* One write per line: O_APPEND keeps lines of two pool threads whole. */
      char line[256];
      size_t n = strnlen(node, sizeof line - 1);
      memcpy(line, node, n);
      line[n] = '\n';
      (void)!write(fd, line, n + 1);
      close(fd);
    }
    const char *ms = getenv("DNS_SHIM_MS");
    usleep((useconds_t)(ms ? atoi(ms) : 1500) * 1000);
    return EAI_NONAME;
  }
  if (node && strncmp(node, "missing", 7) == 0) return EAI_NONAME;
  if (node && strncmp(node, "dup", 3) == 0) {
    static const char *const list[] = {"127.0.0.2", "127.0.0.1", "127.0.0.2"};
    struct addrinfo *head = NULL, **tail = &head;
    for (size_t k = 0; k < sizeof list / sizeof list[0]; k++) {
      int rc = literal(real, list[k], tail);
      if (rc) {
        if (head) freeaddrinfo(head);
        return rc;
      }
      while (*tail) tail = &(*tail)->ai_next;
    }
    *res = head;
    return 0;
  }
  return real(node, service, hints, res);
}

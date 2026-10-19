/*
 * The ends of a child channel and how a child finds them. POSIX: one socket
 * pair, descriptor 3, marker "3", and the VM uses two descriptors of the
 * socket (a duplicate), one per direction. Windows: one pipe per direction, descriptor
 * 3 (the child reads) and 4 (it writes), marker "3,4", because a duplex byte
 * pipe cannot be shut down for writing. Port interface: descriptors only.
 * Implemented by duplex_posix.c and duplex_windows.c.
 */
#ifndef AGC_DUPLEX_OS_H
#define AGC_DUPLEX_OS_H

#include <stdbool.h>

typedef struct {
  /* The ends the parent keeps: it reads `read` and writes `write`. On POSIX they are two descriptors of one socket
     (shutdown on `write` half-closes the socket for both), at the price of one more descriptor per channel. */
  int read, write;
  /* The ends for the child, in order from descriptor 3. */
  int child[2];
  int child_count;
} agc_chan_ends;

/* Makes the pair. Returns 0, or a negative libuv error with nothing left open. */
int agc_chan_pair(agc_chan_ends *ends);

/* The value of AGENTICA_CHANNEL that a child of this system understands: "3", or "3,4" on Windows. */
const char *agc_chan_value(void);

/* The child side. When the inherited descriptors are the ends of a channel (kind and direction), moves them above
   the standard streams, close-on-exec, calls before_close(fd, data) for each original and closes it, and returns the
   moved ones in *read and *write (two descriptors of the socket on POSIX). Otherwise returns false and touches nothing. */
bool agc_chan_take(void (*before_close)(int fd, void *data), void *data, int *read, int *write);

#endif

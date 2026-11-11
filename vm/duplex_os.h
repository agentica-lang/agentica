/*
 * The ends of a child channel and how a child finds them. Every system: one
 * pipe per direction, descriptor 3 (the child reads) and 4 (it writes), marker
 * "3,4". The parent ends its output by closing its write end, the one end of
 * input that every system delivers. On POSIX a child also takes the marker
 * "3" with one socket (or FIFO) open both ways on descriptor 3, the form of
 * earlier versions, from a parent that is no VM. Port interface: descriptors
 * only. The pair is the same on every system (duplex.c); the take is
 * implemented by duplex_posix.c and duplex_windows.c.
 */
#ifndef AGC_DUPLEX_OS_H
#define AGC_DUPLEX_OS_H

#include <stdbool.h>

typedef struct {
  /* The ends the parent keeps: it reads `read` and writes `write`. */
  int read, write;
  /* The ends for the child, in order from descriptor 3. */
  int child[2];
  int child_count;
} agc_chan_ends;

/* Makes the pair. Returns 0, or a negative libuv error with nothing left open. */
int agc_chan_pair(agc_chan_ends *ends);

/* The value of AGENTICA_CHANNEL that the VM gives a child: "3,4". */
const char *agc_chan_value(void);

/* The child side, for the value `marker` of AGENTICA_CHANNEL. When the inherited descriptors are the ends of a
   channel of that form (kind and direction), moves them above the standard streams, close-on-exec, calls
   before_close(fd, data) for each original and closes it, and returns the moved ones in *read and *write (two
   descriptors of the one socket for "3"). Otherwise returns false and touches nothing. */
bool agc_chan_take(const char *marker, void (*before_close)(int fd, void *data), void *data, int *read, int *write);

#endif

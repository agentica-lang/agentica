/*
 * The connection object (agc_conn) that tcp.c and the HTTP server's group
 * share: the listener's watch callback, accept, the clean end of input,
 * half-close and release. Service header: it includes services.h and tls.h.
 * A connection belongs to the I/O thread: call these there (inline at N = 1),
 * except agc_conn_socket on a scheduler (see it) and agc_conn_closed anywhere
 * (a hint). Design: docs/vm/10-io-http.md §10.7.2.
 */
#ifndef AGC_NET_H
#define AGC_NET_H

#include "services.h"
#include "tls.h"

typedef struct agc_conn agc_conn;
typedef void (*agc_conn_watch)(void *watcher);

void agc_conn_observe(agc_conn *c, agc_conn_watch watch, void *watcher);
bool agc_conn_clean_eof(const agc_conn *c);
void agc_conn_half_close(agc_conn *c);
void agc_conn_release(agc_conn *c);
void agc_conn_retain(agc_conn *c);
bool agc_conn_closed(const agc_conn *c);
agc_conn *agc_conn_accept(agc_conn *l);
/* Closes a connection that agc_conn_accept made and no socket took, and gives back the count accept took. */
void agc_conn_discard(agc_conn *c);
/* On a scheduler: the socket value of a connection that agc_conn_accept made and that no step has used yet; the
   resource takes the count that agc_conn_accept took. */
agc_value agc_conn_socket(agc_vm *vm, agc_conn *c);
void agc_net_close(agc_vm *vm, agc_resource *r, const char *why);
agc_value agc_tls_load_error(agc_vm *vm, const char *what, const char *path, const agc_tls_failure *f);

#endif

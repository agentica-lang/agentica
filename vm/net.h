#ifndef AGC_NET_H
#define AGC_NET_H

#include "agc.h"
#include "tls.h"

typedef struct agc_conn agc_conn;
typedef void (*agc_conn_watch)(void *watcher);

agc_conn *agc_conn_open(const agc_trace *trace, struct uv_loop_s *loop, uint64_t id, const char *host, int64_t port,
                        agc_tls_config *config, agc_conn_watch watch, void *watcher);
void agc_conn_observe(agc_conn *c, agc_conn_watch watch, void *watcher);
bool agc_conn_ready(const agc_conn *c);
bool agc_conn_failed(const agc_conn *c);
agc_value agc_conn_error(agc_vm *vm, const agc_conn *c);
int agc_conn_send(agc_conn *c, const uint8_t *data, size_t len);
bool agc_conn_sent(const agc_conn *c);
int agc_conn_write_status(const agc_conn *c);
bool agc_conn_clean_eof(const agc_conn *c);
void agc_conn_hold(agc_conn *c, bool hold);
agc_inbuf *agc_conn_input(agc_conn *c);
void agc_conn_read(agc_conn *c);
void agc_conn_pause(agc_conn *c);
void agc_conn_goodbye(agc_conn *c);
void agc_conn_shut(agc_conn *c, const char *why);
void agc_conn_half_close(agc_conn *c);
void agc_conn_release(agc_conn *c);
void agc_conn_retain(agc_conn *c);
void agc_conn_unobserve(agc_conn *c, const void *watcher);
bool agc_conn_closed(const agc_conn *c);
uint64_t agc_conn_heard(const agc_conn *c);
agc_conn *agc_conn_accept(agc_conn *l);
agc_value agc_conn_socket(agc_vm *vm, agc_conn *c);
void agc_net_close(agc_vm *vm, agc_resource *r, const char *why);
agc_value agc_tls_load_error(agc_vm *vm, const char *what, const char *path, const agc_tls_failure *f);

#endif

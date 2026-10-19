/*
 * The inbox of the I/O thread (vm/inbox.c, docs/vm/16-architecture.md §16.3): many producers and one consumer on a
 * libuv loop. Every request arrives once and in each producer's order, a post wakes a loop that is blocked, and a
 * request posted while the handler runs is handled by the next wake.
 */
#include "../core.h"
#include "test_support.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <uv.h>

#define PRODUCERS 6
#define PER_PRODUCER 20000
#define PING_ROUNDS 3000

typedef struct {
  uv_loop_t loop;
  agc_inbox *inbox;
  int64_t next[PRODUCERS];
  int64_t total, batches, largest;
} sink;

typedef struct {
  sink *s;
  int self;
} producer;

typedef struct {
  uv_loop_t loop;
  agc_inbox *inbox;
  uv_sem_t answered;
  int64_t seen;
} ping;

typedef struct {
  uv_loop_t loop;
  agc_inbox *inbox;
  uv_sem_t in_handler, go_on;
  int calls;
  int64_t first, second;
} overlap;

/* The handler checks what the producers wrote before they posted (the payload is the producer's own sequence number)
   and frees the entries. After the last request it stops keeping the loop alive, which ends uv_run. The inbox is closed
   only once the producers have been joined: libuv allows no uv_async_send on a handle that is closing, and a producer
   can still be inside it when the consumer has handled its request. */
static void collect(void *owner, agc_request *list) {
  sink *s = owner;
  int64_t batch = 0;
  while (list) {
    agc_request *next = list->next;
    assert(list->kind >= 0 && list->kind < PRODUCERS);
    assert(list->arg == s->next[list->kind]++);
    assert(list->subject == (void *)s);
    free(list);
    s->total++;
    batch++;
    list = next;
  }
  s->batches++;
  if (batch > s->largest) s->largest = batch;
  if (s->total == (int64_t)PRODUCERS * PER_PRODUCER) agc_inbox_keep(s->inbox, false);
}

static void post_all(void *arg) {
  producer *p = arg;
  for (int64_t k = 0; k < PER_PRODUCER; k++) {
    agc_request *req = malloc(sizeof *req);
    assert(req);
    *req = (agc_request){NULL, p->self, p->s, k};
    agc_inbox_post(p->s->inbox, req);
  }
}

static void test_many_producers(void) {
  sink s = {0};
  assert(uv_loop_init(&s.loop) == 0);
  s.inbox = agc_inbox_open(&s.loop, collect, &s);
  assert(s.inbox);
  producer producers[PRODUCERS];
  uv_thread_t threads[PRODUCERS];
  for (int k = 0; k < PRODUCERS; k++) {
    producers[k] = (producer){&s, k};
    assert(uv_thread_create(&threads[k], post_all, &producers[k]) == 0);
  }
  assert(uv_run(&s.loop, UV_RUN_DEFAULT) == 0);
  for (int k = 0; k < PRODUCERS; k++) assert(uv_thread_join(&threads[k]) == 0);
  agc_inbox_close(s.inbox);
  assert(uv_run(&s.loop, UV_RUN_DEFAULT) == 0);
  assert(s.total == (int64_t)PRODUCERS * PER_PRODUCER);
  for (int k = 0; k < PRODUCERS; k++) assert(s.next[k] == PER_PRODUCER);
  assert(uv_loop_close(&s.loop) == 0);
  printf("inbox: %lld requests in %lld batches, largest %lld\n", (long long)s.total, (long long)s.batches,
         (long long)s.largest);
}

static int ping_payload[PING_ROUNDS];

/* Each request is written, published and then waited for: the producer posts only after the loop answered the one
   before, so the loop is blocked in uv_run (or about to be) at every post. A wake that is lost leaves the producer
   waiting on `answered` until the deadline of the test ends the process. */
static void answer(void *owner, agc_request *list) {
  ping *p = owner;
  assert(list && !list->next);
  assert(list->arg == p->seen && ping_payload[list->arg] == (int)(list->arg * 3 + 1));
  free(list);
  p->seen++;
  if (p->seen == PING_ROUNDS) agc_inbox_keep(p->inbox, false);
  uv_sem_post(&p->answered);
}

static void ping_all(void *arg) {
  ping *p = arg;
  for (int64_t k = 0; k < PING_ROUNDS; k++) {
    ping_payload[k] = (int)(k * 3 + 1);
    agc_request *req = malloc(sizeof *req);
    assert(req);
    *req = (agc_request){NULL, 0, p, k};
    agc_inbox_post(p->inbox, req);
    uv_sem_wait(&p->answered);
  }
}

static void test_wake_after_publish(void) {
  ping p = {0};
  assert(uv_loop_init(&p.loop) == 0 && uv_sem_init(&p.answered, 0) == 0);
  p.inbox = agc_inbox_open(&p.loop, answer, &p);
  assert(p.inbox);
  uv_thread_t thread;
  assert(uv_thread_create(&thread, ping_all, &p) == 0);
  assert(uv_run(&p.loop, UV_RUN_DEFAULT) == 0);
  assert(uv_thread_join(&thread) == 0);
  agc_inbox_close(p.inbox);
  assert(uv_run(&p.loop, UV_RUN_DEFAULT) == 0);
  assert(p.seen == PING_ROUNDS);
  uv_sem_destroy(&p.answered);
  assert(uv_loop_close(&p.loop) == 0);
}

/* The first handler call posts nothing itself: it holds the loop while a producer posts the second request. The list
   it was given was taken whole, so the second request is not in it, and the next wake delivers the second. */
static void hold(void *owner, agc_request *list) {
  overlap *o = owner;
  o->calls++;
  assert(list && !list->next);
  if (o->calls == 1) {
    o->first = list->arg;
    uv_sem_post(&o->in_handler);
    uv_sem_wait(&o->go_on);
  } else {
    o->second = list->arg;
    agc_inbox_keep(o->inbox, false);
  }
  free(list);
}

static void post_second(void *arg) {
  overlap *o = arg;
  agc_request *req = malloc(sizeof *req);
  assert(req);
  *req = (agc_request){NULL, 0, o, 1};
  agc_inbox_post(o->inbox, req);
  uv_sem_wait(&o->in_handler);
  req = malloc(sizeof *req);
  assert(req);
  *req = (agc_request){NULL, 0, o, 2};
  agc_inbox_post(o->inbox, req);
  uv_sem_post(&o->go_on);
}

static void test_post_during_handler(void) {
  overlap o = {0};
  assert(uv_loop_init(&o.loop) == 0);
  assert(uv_sem_init(&o.in_handler, 0) == 0 && uv_sem_init(&o.go_on, 0) == 0);
  o.inbox = agc_inbox_open(&o.loop, hold, &o);
  assert(o.inbox);
  uv_thread_t thread;
  assert(uv_thread_create(&thread, post_second, &o) == 0);
  assert(uv_run(&o.loop, UV_RUN_DEFAULT) == 0);
  assert(uv_thread_join(&thread) == 0);
  agc_inbox_close(o.inbox);
  assert(uv_run(&o.loop, UV_RUN_DEFAULT) == 0);
  assert(o.calls == 2 && o.first == 1 && o.second == 2);
  uv_sem_destroy(&o.in_handler);
  uv_sem_destroy(&o.go_on);
  assert(uv_loop_close(&o.loop) == 0);
}

/* An inbox that nobody keeps alive does not hold the loop: uv_run returns at once with nothing queued. */
static void test_unkept_inbox_does_not_hold_the_loop(void) {
  uv_loop_t loop;
  assert(uv_loop_init(&loop) == 0);
  agc_inbox *inbox = agc_inbox_open(&loop, collect, NULL);
  assert(inbox);
  agc_inbox_keep(inbox, false);
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);
  agc_inbox_keep(inbox, true);
  agc_inbox_close(inbox);
  assert(uv_run(&loop, UV_RUN_DEFAULT) == 0);
  assert(uv_loop_close(&loop) == 0);
}

int main(void) {
  agc_test_deadline(120);
  test_unkept_inbox_does_not_hold_the_loop();
  test_wake_after_publish();
  test_post_during_handler();
  test_many_producers();
  puts("inbox tests passed");
  return 0;
}

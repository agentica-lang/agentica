/*
 * The compute pool: the threads that run the work of a job that agc_io_compute started (a native call of a `compute
 * def`), apart from the libuv pool, which takes only bounded work (docs/vm/14-core-invariants.md §14.1). At most one
 * thread per scheduler, started on demand; items run in the order they came. A thread never touches GC memory, and
 * an item that ends goes back to the loop's thread through the pool's own inbox. Core layer. Design:
 * docs/vm/16-architecture.md §16.9, "Compute pool".
 */
#include "core.h"

#include <stdlib.h>
#include <uv.h>

typedef struct {
  agc_compute *pool;
  /* Under the pool's lock: the thread runs an item now. `join`: it was idle when the pool closed, so the close joins
     it. */
  bool busy, join;
} worker;

/* malloc memory, no GC pointer. `lock` guards the queue, the counts, the workers' flags and `closed`; `queued` is the
   length of the queue, `idle` the threads waiting for an item; `refs` counts the loop's hold and one per started
   thread, and the last one out frees the pool. `running` (items given and not yet
   finished) belongs to the loop's thread, which alone may ref or unref the inbox's handle. */
struct agc_compute {
  uv_mutex_t lock;
  uv_cond_t wake;
  agc_request *first, *last;
  void *threads;
  worker *workers;
  uint32_t size, started, idle, queued, refs;
  bool closed;
  agc_inbox *done;
  void (*finished)(void *item);
  uint64_t running;
};

static void destroy(agc_compute *pool) {
  uv_cond_destroy(&pool->wake);
  uv_mutex_destroy(&pool->lock);
  agc_threads_free(pool->threads);
  free(pool->workers);
  free(pool);
}

/* Drops a hold under the lock; the caller frees the pool, after the unlock, when this was the last one. */
static bool let_go(agc_compute *pool) { return --pool->refs == 0; }

/* A pool thread: the next item in order, its work outside the lock, then its end to the loop's thread. The end is
   posted under the lock, so a post never races agc_compute_close, which closes the inbox only after it set `closed`
   under the same lock. After the close an item that ends has nobody to take it, so its entry is freed here. */
static void serve(void *arg) {
  worker *w = arg;
  agc_compute *pool = w->pool;
  uv_mutex_lock(&pool->lock);
  for (;;) {
    while (!pool->first && !pool->closed) {
      pool->idle++;
      uv_cond_wait(&pool->wake, &pool->lock);
      pool->idle--;
    }
    if (pool->closed) break;
    agc_request *item = pool->first;
    pool->first = item->next;
    if (!pool->first) pool->last = NULL;
    pool->queued--;
    w->busy = true;
    uv_mutex_unlock(&pool->lock);
    item->call(item->subject);
    uv_mutex_lock(&pool->lock);
    w->busy = false;
    if (pool->closed)
      free(item);
    else
      agc_inbox_post(pool->done, item);
  }
  bool last = let_go(pool);
  uv_mutex_unlock(&pool->lock);
  if (last) destroy(pool);
}

/* The loop's thread: each ended item to `finished`, then the inbox keeps the loop alive only while items run, so an
   idle pool never holds a run that has nothing else to wait for. */
static void deliver(void *owner, agc_request *list) {
  agc_compute *pool = owner;
  while (list) {
    agc_request *next = list->next;
    pool->running--;
    pool->finished(list->subject);
    free(list);
    list = next;
  }
  agc_inbox_keep(pool->done, pool->running > 0);
}

agc_compute *agc_compute_open(struct uv_loop_s *loop, uint32_t size, void (*finished)(void *item)) {
  agc_compute *pool = calloc(1, sizeof *pool);
  if (!pool) agc_out_of_memory();
  pool->size = size ? size : 1;
  pool->workers = calloc(pool->size, sizeof(worker));
  if (!pool->workers) agc_out_of_memory();
  pool->threads = agc_threads_new(pool->size);
  pool->finished = finished;
  pool->refs = 1;
  if (uv_mutex_init(&pool->lock) != 0) {
    agc_threads_free(pool->threads);
    free(pool->workers);
    free(pool);
    return NULL;
  }
  if (uv_cond_init(&pool->wake) != 0) {
    uv_mutex_destroy(&pool->lock);
    agc_threads_free(pool->threads);
    free(pool->workers);
    free(pool);
    return NULL;
  }
  pool->done = agc_inbox_open(loop, deliver, pool);
  if (!pool->done) {
    destroy(pool);
    return NULL;
  }
  agc_inbox_keep(pool->done, false);
  return pool;
}

bool agc_compute_submit(agc_compute *pool, void (*work)(void *item), void *item) {
  agc_request *entry = malloc(sizeof *entry);
  if (!entry) agc_out_of_memory();
  *entry = (agc_request){NULL, 0, item, 0, work};
  uv_mutex_lock(&pool->lock);
  if (pool->last)
    pool->last->next = entry;
  else
    pool->first = entry;
  pool->last = entry;
  pool->queued++;
  /* A new thread when the queue holds more items than threads wait for: a woken thread leaves `idle` only once it has
     the lock, so a burst of items still finds threads to start. The pool grows to its size under load and no further. */
  if (pool->queued > pool->idle && pool->started < pool->size) {
    uint32_t k = pool->started;
    pool->workers[k] = (worker){pool, false, false};
    if (agc_thread_start(pool->threads, k, serve, &pool->workers[k])) {
      pool->started++;
      pool->refs++;
    }
  }
  if (pool->started == 0) {
    pool->first = pool->last = NULL;
    pool->queued = 0;
    uv_mutex_unlock(&pool->lock);
    free(entry);
    return false;
  }
  uv_cond_signal(&pool->wake);
  uv_mutex_unlock(&pool->lock);
  if (pool->running++ == 0) agc_inbox_keep(pool->done, true);
  return true;
}

void agc_compute_close(agc_compute *pool) {
  uv_mutex_lock(&pool->lock);
  pool->closed = true;
  /* Items that no thread took never run: the run is over. */
  for (agc_request *item = pool->first, *next; item; item = next) {
    next = item->next;
    free(item);
  }
  pool->first = pool->last = NULL;
  pool->queued = 0;
  uv_cond_broadcast(&pool->wake);
  uint32_t started = pool->started;
  for (uint32_t k = 0; k < started; k++) pool->workers[k].join = !pool->workers[k].busy;
  uv_mutex_unlock(&pool->lock);
  /* An idle thread ends at once. A thread inside a native call cannot be stopped: it is detached, ends after the call
     and drops the result, and the last thread out frees the pool. */
  for (uint32_t k = 0; k < started; k++) {
    if (pool->workers[k].join)
      agc_thread_join(pool->threads, k);
    else
      agc_thread_detach(pool->threads, k);
  }
  agc_inbox_close(pool->done);
  uv_mutex_lock(&pool->lock);
  bool last = let_go(pool);
  uv_mutex_unlock(&pool->lock);
  if (last) destroy(pool);
}

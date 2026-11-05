/*
 * The compute pool: the threads that run the work of a job that agc_io_compute started (a native call of a `compute
 * def`, or a KDF derivation of vm/crypto.c), apart from the libuv pool, which takes only bounded work
 * (docs/vm/14-core-invariants.md §14.1). At most one thread per scheduler, started on demand; items run in the order
 * they came. A thread never touches GC memory, and an item that ends goes back to the loop's thread through the
 * pool's own inbox, or, for an item that a scheduler gave directly (agc_compute_submit_direct), to the pool's `ended`
 * callback on the pool thread. Core layer. Design: docs/vm/16-architecture.md §16.9, "Compute pool".
 */
#include "core.h"

#include <stdlib.h>
#include <uv.h>

/* The `kind` of a queue entry that a scheduler submitted (agc_compute_submit_direct); 0 is a loop's item. */
#define DIRECT 1

typedef struct {
  agc_compute *pool;
  /* Under the pool's lock: the thread runs an item now. `join`: it was idle when the pool closed, so the close joins
     it. */
  bool busy, join;
} worker;

/* malloc memory, no GC pointer. `lock` guards the queue, the counts, the workers' flags and `closed`; `queued` is the
   length of the queue, `idle` the threads waiting for an item; `refs` counts the loop's hold and one per started
   thread, and the last one out frees the pool. `running` (items given and not yet
   finished) belongs to the loop's thread, which alone may ref or unref the inbox's handle. `direct` counts the direct
   items given and not yet ended (any thread), which the loop's thread reads for its stall check instead. */
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
  void (*ended)(void *item);
  uint64_t running;
  _Atomic uint64_t direct;
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
    if (item->kind == DIRECT && pool->ended) {
      /* Under the lock, like the post: once the close has set `closed`, nobody takes the end any more. The count
         drops after `ended` has published the end, so a stall check never sees neither. */
      if (!pool->closed) pool->ended(item->subject);
      free(item);
      atomic_fetch_sub_explicit(&pool->direct, 1, memory_order_seq_cst);
    } else if (pool->closed) {
      if (item->kind == DIRECT) atomic_fetch_sub_explicit(&pool->direct, 1, memory_order_seq_cst);
      free(item);
    } else {
      /* A direct item after agc_compute_end_direct ends as the loop's own (its count already moved to `running`). */
      if (item->kind == DIRECT) atomic_fetch_sub_explicit(&pool->direct, 1, memory_order_seq_cst);
      agc_inbox_post(pool->done, item);
    }
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

agc_compute *agc_compute_open(struct uv_loop_s *loop, uint32_t size, void (*finished)(void *item),
                              void (*ended)(void *item)) {
  agc_compute *pool = calloc(1, sizeof *pool);
  if (!pool) agc_out_of_memory();
  pool->size = size ? size : 1;
  pool->workers = calloc(pool->size, sizeof(worker));
  if (!pool->workers) agc_out_of_memory();
  pool->threads = agc_threads_new(pool->size);
  pool->finished = finished;
  pool->ended = ended;
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

/* Queues ENTRY and starts a thread when it needs one, under the lock (held at the call, dropped by the caller on
   success, which then calls wake_one). False, with the lock dropped and ENTRY freed, when no thread exists and none can
   start. */
static bool enqueue(agc_compute *pool, agc_request *entry) {
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
  return true;
}

/* After the unlock, so the thread it wakes does not wait for the lock at once. Only a thread that waits needs it: a
   busy one takes the item when it comes back for the next. */
static void wake_one(agc_compute *pool, bool waiting) {
  if (waiting) uv_cond_signal(&pool->wake);
}

static agc_request *new_entry(int kind, void (*work)(void *item), void *item) {
  agc_request *entry = malloc(sizeof *entry);
  if (!entry) agc_out_of_memory();
  *entry = (agc_request){NULL, kind, item, 0, work};
  return entry;
}

bool agc_compute_submit(agc_compute *pool, void (*work)(void *item), void *item) {
  agc_request *entry = new_entry(0, work, item);
  uv_mutex_lock(&pool->lock);
  if (!enqueue(pool, entry)) return false;
  bool waiting = pool->idle > 0;
  uv_mutex_unlock(&pool->lock);
  wake_one(pool, waiting);
  if (pool->running++ == 0) agc_inbox_keep(pool->done, true);
  return true;
}

/* Any thread: the item does not go back through the loop's thread, so it touches neither `running` nor the inbox. The
   count goes up under the lock, before the item is queued, so it is never below the items a thread may still end, and
   agc_compute_end_direct counts exactly the items it turns over. */
bool agc_compute_submit_direct(agc_compute *pool, void (*work)(void *item), void *item) {
  agc_request *entry = new_entry(DIRECT, work, item);
  uv_mutex_lock(&pool->lock);
  if (!pool->ended) {
    uv_mutex_unlock(&pool->lock);
    free(entry);
    return false;
  }
  atomic_fetch_add_explicit(&pool->direct, 1, memory_order_seq_cst);
  if (!enqueue(pool, entry)) {
    atomic_fetch_sub_explicit(&pool->direct, 1, memory_order_seq_cst);
    return false;
  }
  bool waiting = pool->idle > 0;
  uv_mutex_unlock(&pool->lock);
  wake_one(pool, waiting);
  return true;
}

/* Under the lock, so each direct item still queued or running is counted here exactly when serve has not ended it
   yet: those now go through the inbox, which keeps the loop alive until the last one is back (the end of the run
   waits for a call that still holds a resource by running the loop). */
void agc_compute_end_direct(agc_compute *pool) {
  uv_mutex_lock(&pool->lock);
  pool->ended = NULL;
  uint64_t left = atomic_load_explicit(&pool->direct, memory_order_seq_cst);
  uv_mutex_unlock(&pool->lock);
  if (left && pool->running == 0) agc_inbox_keep(pool->done, true);
  pool->running += left;
}

bool agc_compute_direct_busy(agc_compute *pool) {
  return atomic_load_explicit(&pool->direct, memory_order_seq_cst) != 0;
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

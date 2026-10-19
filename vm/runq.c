/*
 * The global run queue: the ready tasks, one FIFO shared by every scheduler
 * (docs/vm/16-architecture.md §16.3). An intrusive list through `agc_task.next`
 * and one mutex. Core layer.
 *
 * It includes <uv.h> only for `uv_mutex_t`, libuv's portable mutex: the VM has no other mutex type that builds on
 * Windows too, and the layer rule that keeps libuv to the loop and the stream services (docs/vm/15-layers.md §15.5,
 * rule 5) lists this file for that one type.
 */
#include "core.h"

#include <uv.h>

/* GC memory (agc_runq_new): the list links tasks, and a head that malloc memory held would hide them from the
   collector (docs/vm/16-architecture.md §16.5, "GC rule"). `solo` is true while one thread uses the queue: it takes no
   lock then, which is what one scheduler costs. */
struct agc_runq {
  uv_mutex_t lock;
  uv_cond_t wake;
  agc_task *first, *last;
  bool solo, ended;
};

agc_runq *agc_runq_new(void) {
  agc_runq *q = agc_alloc(sizeof *q);
  if (uv_mutex_init(&q->lock) != 0 || uv_cond_init(&q->wake) != 0) agc_out_of_memory();
  q->solo = true;
  return q;
}

/* From here on every push, pop and remove takes the lock. The caller runs it before the second thread exists, so
   thread creation orders this write before that thread's first read of `solo`. */
void agc_runq_share(agc_runq *q) { q->solo = false; }

static void link_last(agc_runq *q, agc_task *t) {
  t->next = NULL;
  if (q->last)
    q->last->next = t;
  else
    q->first = t;
  q->last = t;
}

/* The caller has set the state of the task already. The link is written under the lock, so whoever pops the task sees
   everything the pusher wrote to it, and the signal comes after the unlock (§16.3, "Wake after publish"). */
void agc_runq_push(agc_runq *q, agc_task *t) {
  if (q->solo) {
    link_last(q, t);
    return;
  }
  uv_mutex_lock(&q->lock);
  link_last(q, t);
  uv_mutex_unlock(&q->lock);
  uv_cond_signal(&q->wake);
}

static agc_task *take_first(agc_runq *q) {
  agc_task *t = q->first;
  if (!t) return NULL;
  q->first = t->next;
  if (!q->first) q->last = NULL;
  t->next = NULL;
  return t;
}

/* One task, never a batch: the other schedulers would idle with work waiting. NULL when the queue is empty. */
agc_task *agc_runq_pop(agc_runq *q) {
  if (q->solo) return take_first(q);
  uv_mutex_lock(&q->lock);
  agc_task *t = take_first(q);
  uv_mutex_unlock(&q->lock);
  return t;
}

/* The pop of an idle scheduler: waits until a task is queued or the run has ended, and returns NULL only for the end.
   A solo queue has no other thread to push, so it never waits and returns NULL when empty. The wait is a loop that
   tests the queue and the flag again: a condvar may return with no signal, and Boehm's suspend signals interrupt it.
   Both are tested under the lock that the pusher and agc_runq_end take, so no wake falls between the test and the
   wait (§16.3, "Idle schedulers"). An ended queue returns NULL even if tasks are left: the run is over. */
agc_task *agc_runq_wait(agc_runq *q) {
  if (q->solo) return q->ended ? NULL : take_first(q);
  uv_mutex_lock(&q->lock);
  while (!q->first && !q->ended) uv_cond_wait(&q->wake, &q->lock);
  agc_task *t = q->ended ? NULL : take_first(q);
  uv_mutex_unlock(&q->lock);
  return t;
}

/* The run is over: every agc_runq_wait returns NULL, now and later. The flag changes under the lock, as the wait
   reads it, and the broadcast comes after the unlock. */
void agc_runq_end(agc_runq *q) {
  if (q->solo) {
    q->ended = true;
    return;
  }
  uv_mutex_lock(&q->lock);
  q->ended = true;
  uv_mutex_unlock(&q->lock);
  uv_cond_broadcast(&q->wake);
}

static bool unlink_from(agc_runq *q, const agc_task *t) {
  agc_task *previous = NULL;
  for (agc_task *k = q->first; k; previous = k, k = k->next) {
    if (k != t) continue;
    if (previous)
      previous->next = k->next;
    else
      q->first = k->next;
    if (q->last == k) q->last = previous;
    k->next = NULL;
    return true;
  }
  return false;
}

/* Takes a task out of the middle of the queue (a cancel of a ready task). O(n), under the lock. False when the task
   is not in the queue, which for a READY task means a waker set the state and has not pushed yet. */
bool agc_runq_remove(agc_runq *q, const agc_task *t) {
  if (q->solo) return unlink_from(q, t);
  uv_mutex_lock(&q->lock);
  bool found = unlink_from(q, t);
  uv_mutex_unlock(&q->lock);
  return found;
}

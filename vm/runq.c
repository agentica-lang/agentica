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
  agc_task *first, *last;
  bool solo;
};

agc_runq *agc_runq_new(void) {
  agc_runq *q = agc_alloc(sizeof *q);
  if (uv_mutex_init(&q->lock) != 0) agc_out_of_memory();
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
   everything the pusher wrote to it (§16.3, "Wake after publish"). */
void agc_runq_push(agc_runq *q, agc_task *t) {
  if (q->solo) {
    link_last(q, t);
    return;
  }
  uv_mutex_lock(&q->lock);
  link_last(q, t);
  uv_mutex_unlock(&q->lock);
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

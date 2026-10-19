/*
 * The global run queue: the ready tasks, one FIFO shared by every scheduler
 * (docs/vm/16-architecture.md §16.3). An intrusive list through `agc_task.next`,
 * one mutex and one condition variable. Core layer.
 */
#include "core.h"

#include <uv.h>

/* GC memory (agc_runq_new): the list links tasks, and a head that malloc memory held would hide them from the
   collector (docs/vm/16-architecture.md §16.5, "GC rule"). `waiting` counts the schedulers inside agc_runq_wait, so a
   push signals only when somebody can hear it. */
struct agc_runq {
  uv_mutex_t lock;
  uv_cond_t wake;
  agc_task *first, *last;
  uint32_t waiting;
  bool ended;
};

agc_runq *agc_runq_new(void) {
  agc_runq *q = agc_alloc(sizeof *q);
  if (uv_mutex_init(&q->lock) != 0 || uv_cond_init(&q->wake) != 0) agc_out_of_memory();
  return q;
}

/* The caller has set the state of the task already. The link is written before the unlock, so whoever pops the task
   sees everything the pusher wrote to it. The wake comes after the unlock (§16.3, "Wake after publish"). */
void agc_runq_push(agc_runq *q, agc_task *t) {
  t->next = NULL;
  uv_mutex_lock(&q->lock);
  if (q->last)
    q->last->next = t;
  else
    q->first = t;
  q->last = t;
  bool wake = q->waiting != 0;
  uv_mutex_unlock(&q->lock);
  if (wake) uv_cond_signal(&q->wake);
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
  uv_mutex_lock(&q->lock);
  agc_task *t = take_first(q);
  uv_mutex_unlock(&q->lock);
  return t;
}

/* Like agc_runq_pop, but waits for a task. NULL only after agc_runq_end. The test and the wait are under one lock, so
   a push after the unlock cannot slip between them, and the loop covers a wake with no push (spurious, or a signal
   that Boehm's stop-the-world interrupted). */
agc_task *agc_runq_wait(agc_runq *q) {
  uv_mutex_lock(&q->lock);
  while (!q->first && !q->ended) {
    q->waiting++;
    uv_cond_wait(&q->wake, &q->lock);
    q->waiting--;
  }
  agc_task *t = take_first(q);
  uv_mutex_unlock(&q->lock);
  return t;
}

/* Wakes every scheduler in agc_runq_wait; they return the tasks that are left, then NULL. The flag changes under the
   lock: set outside it, the wake could fall between a waiter's test and its wait and be lost. */
void agc_runq_end(agc_runq *q) {
  uv_mutex_lock(&q->lock);
  q->ended = true;
  uv_mutex_unlock(&q->lock);
  uv_cond_broadcast(&q->wake);
}

/* Takes a task out of the middle of the queue (a cancel of a ready task). O(n), under the lock. */
bool agc_runq_remove(agc_runq *q, const agc_task *t) {
  bool found = false;
  uv_mutex_lock(&q->lock);
  agc_task *previous = NULL;
  for (agc_task *k = q->first; k; previous = k, k = k->next) {
    if (k != t) continue;
    if (previous)
      previous->next = k->next;
    else
      q->first = k->next;
    if (q->last == k) q->last = previous;
    k->next = NULL;
    found = true;
    break;
  }
  uv_mutex_unlock(&q->lock);
  return found;
}

/* The first task, left in place: for tests that look at the queue. With other threads popping it means nothing. */
agc_task *agc_runq_peek(agc_runq *q) {
  uv_mutex_lock(&q->lock);
  agc_task *t = q->first;
  uv_mutex_unlock(&q->lock);
  return t;
}

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

/* The longest single condvar wait of agc_runq_wait_until. */
#define WAIT_SLICE_MS UINT64_C(3600000)
/* The most CPU pauses between two looks of a spinning scheduler: the steps double up to it (agc_runq_spin). */
#define SPIN_PAUSES_MAX 32u

/* One CPU pause of a spinning scheduler: `pause` on x86 and `yield` on AArch64 and on ARMv6K and later (older ARM has
   no such hint) tell the core that this is a busy wait (less power, the other hyperthread runs); elsewhere it is a
   compiler barrier only. Every compiler the VM builds with
   (GCC, Clang, llvm-mingw) takes these builtins and this asm. */
#if defined(__x86_64__) || defined(__i386__)
#define CPU_PAUSE() __builtin_ia32_pause()
#elif defined(__aarch64__) || (defined(__arm__) && (__ARM_ARCH >= 7 || defined(__ARM_ARCH_6K__) || \
                                                    defined(__ARM_ARCH_6KZ__)))
#define CPU_PAUSE() __asm__ __volatile__("yield" ::: "memory")
#else
#define CPU_PAUSE() atomic_signal_fence(memory_order_seq_cst)
#endif

/* GC memory (agc_runq_new): the list links tasks, and a head that malloc memory held would hide them from the
   collector (docs/vm/16-architecture.md §16.5, "GC rule"). `solo` is true while one thread uses the queue: it takes no
   lock then, which is what one scheduler costs. */
struct agc_runq {
  uv_mutex_t lock;
  uv_cond_t wake;
  agc_task *first, *last;
  bool solo;
  /* Set under the lock; a spinning scheduler reads it without (agc_runq_spin). */
  _Atomic bool ended;
  /* Work for a scheduler that is not a task (the end of a detached job, §16.11): set under the lock, so a waiter sees it
     in its test, and read without it at the turn boundary of a busy scheduler. */
  _Atomic bool nudged;
  /* The stall check of several schedulers (docs/vm/16-architecture.md §16.9, "Stall"): `count` schedulers use the
     queue and `idle` of them wait in it; `epoch` grows each time one leaves its wait. All three change under the lock.
     The one that makes every scheduler idle calls `on_idle`, which wakes the I/O thread to look. */
  uint32_t count, idle;
  uint64_t epoch;
  void (*on_idle)(void *data);
  void *on_idle_data;
  /* The spin of an idle scheduler before it waits (docs/vm/16-architecture.md §16.9, "Wakes between schedulers"). At
     most `spin_max` schedulers spin at once, each for `spin_ns`; spin_max is 0 (no spin) until agc_runq_spin_setup.
     `spinning` counts them, and `work` says whether the shared queue holds a task: the spinners poll it, not the lock.
     A push reads `spinning` under the lock (sequentially consistent, like the spinner's increment and decrement) and
     skips the condvar signal when a scheduler spins. No wake is lost: a spinner that left before that read is seen as
     gone, so the push signals; one that leaves after it takes the lock after the push's unlock (the push held it at
     the read), so its wait finds the task, and one that keeps spinning sees `work`. `signals` counts the signals that
     pushes sent (agc_runq_stats). */
  uint32_t spin_max;
  uint64_t spin_ns;
  _Atomic uint32_t spinning;
  _Atomic bool work;
  uint64_t signals;
};

agc_runq *agc_runq_new(void) {
  agc_runq *q = agc_alloc(sizeof *q);
  if (uv_mutex_init(&q->lock) != 0 || uv_cond_init(&q->wake) != 0) agc_out_of_memory();
  q->solo = true;
  return q;
}

/* From here on every push, pop and remove takes the lock. The caller runs it before the second thread exists, so
   thread creation orders this write before that thread's first read of `solo`. */
void agc_runq_share(agc_runq *q) {
  q->solo = false;
  atomic_store_explicit(&q->work, q->first != NULL, memory_order_relaxed);
}

/* After a change of the list of a shared queue, under the lock. A push stores `true` with the order of the protocol
   (see agc_runq); a removal may be relaxed, since the lock orders it with the pushes. */
static void note_work(agc_runq *q) { atomic_store_explicit(&q->work, q->first != NULL, memory_order_relaxed); }

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
static void push(agc_runq *q, agc_task *t, bool own) {
  if (q->solo) {
    link_last(q, t);
    return;
  }
  uv_mutex_lock(&q->lock);
  /* An own push into an empty queue neither signals nor tells the spinners: the pusher pops the task next
     (agc_runq_push_own), and a scheduler that stops spinning still finds it under the lock in its wait. */
  bool alone = own && !q->first;
  link_last(q, t);
  if (alone) {
    uv_mutex_unlock(&q->lock);
    return;
  }
  /* A spinner takes the task, or finds it under this lock when it stops spinning: no futex wake. `spinning` is read
     before `work` is published, so a spinner cannot see the task and leave between the two and cost a spare signal. */
  bool wake = atomic_load_explicit(&q->spinning, memory_order_seq_cst) == 0;
  atomic_store_explicit(&q->work, true, memory_order_seq_cst);
  if (wake) q->signals++;
  uv_mutex_unlock(&q->lock);
  if (wake) uv_cond_signal(&q->wake);
}

void agc_runq_push(agc_runq *q, agc_task *t) { push(q, t, false); }

/* The push of the task whose turn just ended on the calling scheduler, when that scheduler pops the queue next (its
   runnext slot is empty). If the queue was empty, the task is the first one it pops, so no other scheduler is woken for
   it: one CPU-bound task that yields at every turn would otherwise wake an idle scheduler per turn and move between
   cores (#627). A queue that already held tasks signals as agc_runq_push does: the caller pops the first of those, and
   this task needs a scheduler of its own. */
void agc_runq_push_own(agc_runq *q, agc_task *t) { push(q, t, true); }

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
  if (t) note_work(q);
  uv_mutex_unlock(&q->lock);
  return t;
}

/* The pop of an idle scheduler: waits until a task is queued or the run has ended, and returns NULL only for the end.
   A solo queue has no other thread to push, so it never waits and returns NULL when empty. The wait is a loop that
   tests the queue and the flag again: a condvar may return with no signal, and Boehm's suspend signals interrupt it.
   Both are tested under the lock that the pusher and agc_runq_end take, so no wake falls between the test and the
   wait (§16.3, "Idle schedulers"). An ended queue returns NULL even if tasks are left: the run is over. A nudge
   (agc_runq_nudge) also ends the wait with NULL when no task is queued; the caller tells the two apart with
   agc_runq_take_nudge. */
static bool must_wait(const agc_runq *q) {
  return !q->first && !atomic_load_explicit(&q->ended, memory_order_relaxed) &&
         !atomic_load_explicit(&q->nudged, memory_order_relaxed);
}

/* The task a waiting or spinning scheduler leaves with, under the lock: none once the run has ended. When it leaves
   with a task, more are queued, others wait and nobody spins, it passes the wake on (*CHAIN, signalled by the caller
   after the unlock): a spinner absorbs the signals of every push it sees, and this chain wakes one parked scheduler
   per task taken until the queue is empty or a scheduler spins again. */
static agc_task *take_waited(agc_runq *q, bool *chain) {
  *chain = false;
  if (atomic_load_explicit(&q->ended, memory_order_relaxed)) return NULL;
  agc_task *t = take_first(q);
  if (!t || q->solo) return t;
  note_work(q);
  *chain = q->first && q->idle && atomic_load_explicit(&q->spinning, memory_order_seq_cst) == 0;
  if (*chain) q->signals++;
  return t;
}

/* The end of a wait or a spin: unlocks, then sends the chained wake if take_waited asked for one. */
static agc_task *leave_with(agc_runq *q, agc_task *t, bool chain) {
  uv_mutex_unlock(&q->lock);
  if (chain) uv_cond_signal(&q->wake);
  return t;
}

/* Under the lock: the caller is about to wait. */
static void enter_idle(agc_runq *q) {
  if (++q->idle == q->count && q->on_idle) q->on_idle(q->on_idle_data);
}

static void leave_idle(agc_runq *q) {
  q->idle--;
  q->epoch++;
}

agc_task *agc_runq_wait(agc_runq *q) {
  bool chain;
  if (q->solo) return take_waited(q, &chain);
  uv_mutex_lock(&q->lock);
  if (must_wait(q)) {
    enter_idle(q);
    while (must_wait(q)) uv_cond_wait(&q->wake, &q->lock);
    leave_idle(q);
  }
  agc_task *t = take_waited(q, &chain);
  return leave_with(q, t, chain);
}

/* The wait of an idle scheduler that has a timer: as agc_runq_wait, but it also returns NULL once agc_clock_ms reaches
   DUE_MS, with no task (docs/vm/16-architecture.md §16.9, "Timers"). The caller tells the end, a nudge and the deadline
   apart by asking the queue and the clock. Only the scheduler that owns the nearest deadline waits timed; the others wait
   untimed, so one deadline does not wake every idle scheduler. A solo queue never waits. */
agc_task *agc_runq_wait_until(agc_runq *q, uint64_t due_ms) {
  bool chain;
  if (q->solo) return take_waited(q, &chain);
  uv_mutex_lock(&q->lock);
  bool idle = false;
  while (must_wait(q)) {
    uint64_t now = agc_clock_ms();
    if (now >= due_ms) break;
    if (!idle) enter_idle(q);
    idle = true;
    /* At most an hour per wait, so the nanoseconds never overflow; the loop waits again for the rest. */
    uint64_t left = due_ms - now < WAIT_SLICE_MS ? due_ms - now : WAIT_SLICE_MS;
    (void)uv_cond_timedwait(&q->wake, &q->lock, left * UINT64_C(1000000));
  }
  if (idle) leave_idle(q);
  agc_task *t = take_waited(q, &chain);
  return leave_with(q, t, chain);
}

/* Sets the spin of idle schedulers: at most MAX of them spin at once, each for BUDGET_NS. Called before the scheduler
   threads start; a queue that is never set up never spins (one scheduler, the C tests). */
void agc_runq_spin_setup(agc_runq *q, uint32_t max, uint64_t budget_ns) {
  q->spin_max = max;
  q->spin_ns = budget_ns;
}

/* Joins the spinners if fewer than spin_max spin. */
static bool join_spinners(agc_runq *q) {
  uint32_t n = atomic_load_explicit(&q->spinning, memory_order_relaxed);
  do {
    if (n >= q->spin_max) return false;
  } while (!atomic_compare_exchange_weak_explicit(&q->spinning, &n, n + 1, memory_order_seq_cst,
                                                  memory_order_relaxed));
  return true;
}

/* Something for a spinner to stop for: a task, a nudge or the end. */
static bool spin_found(agc_runq *q) {
  return atomic_load_explicit(&q->work, memory_order_seq_cst) ||
         atomic_load_explicit(&q->nudged, memory_order_relaxed) ||
         atomic_load_explicit(&q->ended, memory_order_relaxed);
}

/* The busy wait of an idle scheduler before it waits on the condvar: it polls `work` with growing runs of CPU pauses
   (1, 2, 4, ... SPIN_PAUSES_MAX between two looks), never a system sleep, until a task shows up or spin_ns has passed.
   It leaves the spinners before it takes the lock, so a push from then on signals or is found by its wait. Its take
   starts the chained wake of take_waited: the pushes it absorbed sent no signal. NULL when it found no task (the
   caller waits, and that wait returns at once on a nudge or the end); also NULL at once when spinning is off or
   spin_max spin. */
agc_task *agc_runq_spin(agc_runq *q) {
  if (q->solo || !join_spinners(q)) return NULL;
  uint64_t start = uv_hrtime();
  unsigned pauses = 1;
  bool found;
  while (!(found = spin_found(q)) && uv_hrtime() - start < q->spin_ns) {
    for (unsigned k = 0; k < pauses; k++) CPU_PAUSE();
    if (pauses < SPIN_PAUSES_MAX) pauses *= 2;
  }
  atomic_fetch_sub_explicit(&q->spinning, 1, memory_order_seq_cst);
  if (!found) return NULL;
  uv_mutex_lock(&q->lock);
  bool chain;
  agc_task *t = take_waited(q, &chain);
  return leave_with(q, t, chain);
}

agc_runq_counts agc_runq_stats(agc_runq *q) {
  uv_mutex_lock(&q->lock);
  agc_runq_counts c = {atomic_load(&q->spinning), q->idle, q->signals};
  uv_mutex_unlock(&q->lock);
  return c;
}

/* Asks one scheduler to run the service work (agc_io_service). The flag is set under the lock and the signal comes
   after the unlock; one waiter is enough, because the service takes the whole list. */
void agc_runq_nudge(agc_runq *q) {
  if (q->solo) {
    atomic_store_explicit(&q->nudged, true, memory_order_relaxed);
    return;
  }
  uv_mutex_lock(&q->lock);
  atomic_store_explicit(&q->nudged, true, memory_order_relaxed);
  uv_mutex_unlock(&q->lock);
  uv_cond_signal(&q->wake);
}

bool agc_runq_nudged(const agc_runq *q) { return atomic_load_explicit(&q->nudged, memory_order_relaxed); }

/* True for the one caller that clears the flag. It clears before it takes the work, and the work was published before
   the nudge, so a nudge that falls after the clear is seen by the next waiter. */
bool agc_runq_take_nudge(agc_runq *q) {
  if (q->solo) return atomic_exchange_explicit(&q->nudged, false, memory_order_relaxed);
  uv_mutex_lock(&q->lock);
  bool was = atomic_exchange_explicit(&q->nudged, false, memory_order_relaxed);
  uv_mutex_unlock(&q->lock);
  return was;
}

/* The run is over: every agc_runq_wait returns NULL, now and later. The flag changes under the lock, as the wait
   reads it, and the broadcast comes after the unlock. */
void agc_runq_end(agc_runq *q) {
  if (q->solo) {
    atomic_store_explicit(&q->ended, true, memory_order_relaxed);
    return;
  }
  uv_mutex_lock(&q->lock);
  atomic_store_explicit(&q->ended, true, memory_order_relaxed);
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
  if (found) note_work(q);
  uv_mutex_unlock(&q->lock);
  return found;
}

/* A scheduler thread starts (or failed to start) using the queue. */
void agc_runq_add_scheduler(agc_runq *q) {
  uv_mutex_lock(&q->lock);
  q->count++;
  uv_mutex_unlock(&q->lock);
}

void agc_runq_drop_scheduler(agc_runq *q) {
  uv_mutex_lock(&q->lock);
  q->count--;
  uv_mutex_unlock(&q->lock);
}

/* FN runs under the queue's lock, so it must take no lock of the VM: the I/O thread's wake (uv_async_send) takes none.
   Set before the first scheduler thread starts. */
void agc_runq_on_idle(agc_runq *q, void (*fn)(void *data), void *data) {
  q->on_idle = fn;
  q->on_idle_data = data;
}

/* True when every scheduler waits in an empty queue with no nudge and the run has not ended; EPOCH says when, for
   agc_runq_still_quiet. While that holds no scheduler can make work, so whatever else the caller then finds idle stays
   idle, unless the epoch moved: a scheduler woke in between. */
bool agc_runq_quiet(agc_runq *q, uint64_t *epoch) {
  uv_mutex_lock(&q->lock);
  bool quiet = q->count && q->idle == q->count && must_wait(q);
  *epoch = q->epoch;
  uv_mutex_unlock(&q->lock);
  return quiet;
}

bool agc_runq_still_quiet(agc_runq *q, uint64_t epoch) {
  uv_mutex_lock(&q->lock);
  bool quiet = q->epoch == epoch && q->idle == q->count && must_wait(q);
  uv_mutex_unlock(&q->lock);
  return quiet;
}

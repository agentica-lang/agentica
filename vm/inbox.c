/*
 * The inbox of the I/O thread: a locked multi-producer queue of requests that the one consumer takes whole, and the
 * uv_async_t that wakes its loop. Core layer. Design: docs/vm/16-architecture.md §16.3 and §16.4.
 *
 * It includes <uv.h> for the mutex and the async handle (docs/vm/15-layers.md §15.5, rule 5). The entries are
 * malloc'd by the poster and freed by the handler; the inbox links them and keeps no GC pointer.
 */
#include "core.h"

#include <stdlib.h>
#include <uv.h>

struct agc_inbox {
  uv_mutex_t lock;
  uv_async_t wake;
  agc_request *first, *last;
  agc_inbox_fn handle;
  void *owner;
};

/* The loop's thread. The whole list is taken in one lock and handled outside it, so a producer never waits for a
   handler and the consumer keeps no remainder (§16.3, "Single-consumer queues"). Says whether there was a list. The
   loop calls it from the wake; the owner calls it where the loop will not: an inbox that is not kept alive does not
   make a loop with nothing else in it run, so agc_io_poll and the end of the run call it themselves. */
bool agc_inbox_run(agc_inbox *in) {
  uv_mutex_lock(&in->lock);
  agc_request *list = in->first;
  in->first = in->last = NULL;
  uv_mutex_unlock(&in->lock);
  if (!list) return false;
  in->handle(in->owner, list);
  return true;
}

static void woken(uv_async_t *wake) {
  agc_inbox *in = wake->data;
  (void)agc_inbox_run(in);
}

static void closed(uv_handle_t *handle) {
  agc_inbox *in = handle->data;
  uv_mutex_destroy(&in->lock);
  free(in);
}

/* Call it on the thread that runs LOOP, before any other thread posts. The handle is ref'd (it keeps the loop alive)
   until agc_inbox_keep says otherwise. NULL when libuv cannot make the handle. */
agc_inbox *agc_inbox_open(struct uv_loop_s *loop, agc_inbox_fn handle, void *owner) {
  agc_inbox *in = calloc(1, sizeof *in);
  if (!in) agc_out_of_memory();
  if (uv_mutex_init(&in->lock) != 0) {
    free(in);
    return NULL;
  }
  if (uv_async_init(loop, &in->wake, woken) != 0) {
    uv_mutex_destroy(&in->lock);
    free(in);
    return NULL;
  }
  in->wake.data = in;
  in->handle = handle;
  in->owner = owner;
  return in;
}

/* Says whether the inbox keeps the loop alive. A loop with an idle inbox and nothing else has no work to wait for,
   so the end of a run un-refs it (docs/vm/10-io-multicore.md §10.2.3, "The I/O thread blocks in its loop"). Loop's
   thread only: uv_ref and uv_unref are not thread safe. */
void agc_inbox_keep(agc_inbox *in, bool keep) {
  if (keep)
    uv_ref((uv_handle_t *)&in->wake);
  else
    uv_unref((uv_handle_t *)&in->wake);
}

/* Any thread. Wake after publish: the entry is complete before the lock, it is linked under the lock, and only after
   the unlock does the poster wake the consumer, so a handler that runs on that wake sees everything the poster wrote
   (§16.3). uv_async_send coalesces calls, which is why the handler takes the whole list. */
void agc_inbox_post(agc_inbox *in, agc_request *entry) {
  entry->next = NULL;
  uv_mutex_lock(&in->lock);
  if (in->last)
    in->last->next = entry;
  else
    in->first = entry;
  in->last = entry;
  uv_mutex_unlock(&in->lock);
  uv_async_send(&in->wake);
}

/* The loop's thread, once no thread posts any more and none is still inside agc_inbox_post: libuv allows no
   uv_async_send on a handle that is closing, and a poster may still be in it after its request was handled. The
   requests still queued are handled first: each holds a reference that only its handler gives back. */
void agc_inbox_close(agc_inbox *in) {
  (void)agc_inbox_run(in);
  uv_close((uv_handle_t *)&in->wake, closed);
}

/* Any thread: wakes the loop's thread with no request, so that it looks at the run again (the end of the run, every
   scheduler idle). */
void agc_inbox_wake(agc_inbox *in) { uv_async_send(&in->wake); }

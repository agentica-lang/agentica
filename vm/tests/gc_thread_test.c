/*
 * Boehm with threads (docs/vm/10-io-multicore.md §10.2.3, "GC"): threads that libuv starts register with the
 * collector, allocate, and are scanned and stopped by collections that any of them starts. Each thread keeps its list
 * head only in a local variable, so a collector that missed its stack would free live nodes, and the list check after
 * would fail. Also: agc_init's heap divisor and floor, and a collector abort's line. No collector under sanitizers.
 */
#include "../value.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <uv.h>
#if !defined(_WIN32) && !defined(AGC_NO_GC)
#include <gc.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#endif
#if defined(_WIN32) && !defined(AGC_NO_GC)
#define GC_THREADS
#include <gc.h>
#include <windows.h>
/* gc.h makes CreateThread register the new thread; the watchdog below must stay unknown to the collector. */
#undef CreateThread
#endif

#define THREADS 4
#define NODES 20000
#define ROUNDS 5

typedef struct node {
  struct node *next;
  uint64_t value;
} node;

static _Atomic int finished;
static _Atomic bool failed;

/* Builds NODES nodes holding SEED + k, collects between rounds, and checks every node. */
static void build_and_check(uint64_t seed) {
  node *head = NULL;
  for (uint64_t k = 0; k < NODES; k++) {
    node *n = agc_alloc(sizeof *n);
    n->next = head;
    n->value = seed + k;
    head = n;
    if (k % (NODES / ROUNDS) == 0) agc_gc_collect();
  }
  uint64_t expect = seed + NODES;
  for (const node *n = head; n; n = n->next) {
    if (n->value != --expect) atomic_store(&failed, true);
  }
  if (expect != seed) atomic_store(&failed, true);
}

static void work(void *arg) {
  if (!agc_gc_thread_enter()) {
    atomic_store(&failed, true);
    return;
  }
  build_and_check((uint64_t)(uintptr_t)arg * 1000000u);
  atomic_fetch_add(&finished, 1);
  agc_gc_thread_leave();
}

#if defined(_WIN32) && !defined(AGC_NO_GC)
/* #528: on Windows a collection stops the other threads with SuspendThread, wherever they are, so one may hold the
   process heap's lock. Boehm's mark phase (GC_mark_some, built with GCC) sets a SIGSEGV handler with signal(), and the
   UCRT's signal() mallocs the thread's own action table the first time a thread calls it, so a thread's first
   collection waited for ever on that lock. Here a new registered thread, which has never collected, collects, and
   right before the world stops (GC_EVENT_PRE_STOP_WORLD) another registered thread takes the heap lock (HeapLock),
   so the collection stops it holding the lock: the collection must finish. Nothing here mallocs while the lock is
   held, and a hang fails the test from a watchdog thread with Win32 calls only. */
static HANDLE holder_in, collector_in, dog_in, take_heap, heap_held, heap_free, collect_go, collect_done;
static _Atomic bool armed;

static void before_stop(GC_EventType event) {
  if (event != GC_EVENT_PRE_STOP_WORLD || !atomic_exchange(&armed, false)) return;
  SetEvent(take_heap);
  WaitForSingleObject(heap_held, INFINITE);
}

static void hold_heap(void *arg) {
  (void)arg;
  if (!agc_gc_thread_enter()) atomic_store(&failed, true);
  SetEvent(holder_in);
  WaitForSingleObject(take_heap, INFINITE);
  HeapLock(GetProcessHeap());
  SetEvent(heap_held);
  WaitForSingleObject(heap_free, INFINITE);
  HeapUnlock(GetProcessHeap());
  agc_gc_thread_leave();
}

static void collect_once(void *arg) {
  (void)arg;
  if (!agc_gc_thread_enter()) atomic_store(&failed, true);
  SetEvent(collector_in);
  WaitForSingleObject(collect_go, INFINITE);
  agc_gc_collect();
  SetEvent(collect_done);
  agc_gc_thread_leave();
}

/* The watchdog is a thread the collector does not know, so a collection that hangs does not stop it as it stops the
   main thread. */
static DWORD WINAPI watchdog(LPVOID arg) {
  (void)arg;
  SetEvent(dog_in);
  if (WaitForSingleObject(collect_done, 20000) == WAIT_OBJECT_0) return 0;
  static const char text[] = "gc_thread_test: a collection hung while a stopped thread held the heap lock\n";
  DWORD written;
  WriteFile(GetStdHandle(STD_ERROR_HANDLE), text, sizeof text - 1, &written, NULL);
  TerminateProcess(GetCurrentProcess(), 1);
  return 1;
}

static void collect_beside_a_held_heap(void) {
  HANDLE *events[] = {&holder_in, &collector_in, &dog_in, &take_heap,
                      &heap_held, &heap_free, &collect_go, &collect_done};
  for (size_t k = 0; k < sizeof events / sizeof events[0]; k++) {
    *events[k] = CreateEventW(NULL, TRUE, FALSE, NULL);
    assert(*events[k]);
  }
  uv_thread_t collector, holder;
  assert(uv_thread_create(&collector, collect_once, NULL) == 0);
  assert(uv_thread_create(&holder, hold_heap, NULL) == 0);
  /* Both are registered first: a registration waits for the collector's lock, which the collection holds. */
  WaitForSingleObject(holder_in, INFINITE);
  WaitForSingleObject(collector_in, INFINITE);
  HANDLE dog = CreateThread(NULL, 0, watchdog, NULL, 0, NULL);
  assert(dog);
  /* A starting thread may take the heap lock (thread attach), so it runs before the lock is held. */
  WaitForSingleObject(dog_in, INFINITE);
  GC_set_on_collection_event(before_stop);
  atomic_store(&armed, true);
  SetEvent(collect_go);
  WaitForSingleObject(collect_done, INFINITE);
  /* The hook ran (the world was stopped); the holder is let go either way, so a failure never hangs the join. */
  assert(!atomic_load(&armed));
  SetEvent(take_heap);
  SetEvent(heap_free);
  assert(uv_thread_join(&holder) == 0);
  assert(uv_thread_join(&collector) == 0);
  GC_set_on_collection_event(NULL);
  WaitForSingleObject(dog, INFINITE);
  CloseHandle(dog);
  for (size_t k = 0; k < sizeof events / sizeof events[0]; k++) CloseHandle(*events[k]);
}
#endif

#if !defined(_WIN32) && !defined(AGC_NO_GC)
/* The abort function agc_init sets, called with MESSAGE in a child: it must exit 70 with LINE alone on stderr. The
   function is read before the fork: GC_get_abort_func takes libgc's lock, which a child must not wait on. */
static void gc_abort_ends_with(const char *message, const char *line) {
  GC_abort_func on_abort = GC_get_abort_func();
  int out[2];
  assert(pipe(out) == 0);
  fflush(NULL);
  pid_t pid = fork();
  assert(pid >= 0);
  if (pid == 0) {
    dup2(out[1], 2);
    on_abort(message);
    _exit(0);
  }
  close(out[1]);
  char text[256];
  size_t n = 0;
  ssize_t got;
  while (n < sizeof text - 1 && (got = read(out[0], text + n, sizeof text - 1 - n)) > 0) n += (size_t)got;
  text[n] = 0;
  close(out[0]);
  int status = 0;
  assert(waitpid(pid, &status, 0) == pid);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 70);
  assert(strcmp(text, line) == 0);
}

/* libgc's aborts for memory the system refused are the out-of-memory line (#1384), one per prefix of on_gc_abort; any
   other stays a GC fault. */
static void gc_aborts(void) {
  static const char *const out_of_memory[] = {
      "Insufficient memory for main local_mark_stack",  "Insufficient space for /proc read",
      "Failed to allocate memory for thread registering", "Could not allocate memory for procedure stack",
      "Could not map memory for procedure stack",       "Cannot allocate executable pages",
      "Not enough memory to process remapping"};
  for (size_t k = 0; k < sizeof out_of_memory / sizeof out_of_memory[0]; k++)
    gc_abort_ends_with(out_of_memory[k], "agentica: out of memory\n");
  gc_abort_ends_with("Failed to create key for local allocator", "agentica: internal GC error\n");
  gc_abort_ends_with("Too many heap sections", "agentica: internal GC error\n");
  gc_abort_ends_with("Insufficient", "agentica: internal GC error\n");
}
#endif

int main(void) {
  agc_init();
#if !defined(_WIN32) && !defined(AGC_NO_GC)
  gc_aborts();
#endif
#ifndef AGC_NO_GC
  /* agc_init grows the heap with divisor 2 (vm/value.c) unless the environment names another. */
  if (!getenv("GC_FREE_SPACE_DIVISOR")) assert(GC_get_free_space_divisor() == 2);
  /* It also starts the heap at 32 MB unless the environment sets a size. */
  if (!getenv("GC_INITIAL_HEAP_SIZE") && !getenv("AGENTICA_GC_HEAP")) assert(GC_get_heap_size() >= (size_t)32 << 20);
#endif
  size_t bytes = 1;
  assert(agc_gc_heap_parse("0", &bytes) && bytes == 0);
  assert(agc_gc_heap_parse("33554432", &bytes) && bytes == (size_t)32 << 20);
  assert(agc_gc_heap_parse("32M", &bytes) && bytes == (size_t)32 << 20);
  assert(agc_gc_heap_parse("4k", &bytes) && bytes == 4096);
  assert(agc_gc_heap_parse("1024G", &bytes) && bytes == (size_t)1 << 40);
  static const char *bad[] = {"", "M", "-1", "1025G", "32X", "32MB", " 32M", "1099511627777", "99999999999999999999"};
  for (size_t k = 0; k < sizeof bad / sizeof bad[0]; k++) assert(!agc_gc_heap_parse(bad[k], &bytes));
  agc_gc_allow_threads();
#if defined(_WIN32) && !defined(AGC_NO_GC)
  collect_beside_a_held_heap();
  assert(!atomic_load(&failed));
#endif
  uv_thread_t threads[THREADS];
  for (uintptr_t k = 0; k < THREADS; k++) assert(uv_thread_create(&threads[k], work, (void *)(k + 1)) == 0);
  build_and_check(0);
  for (size_t k = 0; k < THREADS; k++) assert(uv_thread_join(&threads[k]) == 0);
  assert(!atomic_load(&failed) && atomic_load(&finished) == THREADS);
  /* The collector still works for the main thread once the others have left. */
  build_and_check(7);
  agc_gc_collect();
  puts("gc thread tests passed");
  return 0;
}

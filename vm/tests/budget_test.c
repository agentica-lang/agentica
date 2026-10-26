/*
 * Allocation budget: under AGC_NO_GC, an allocation past twice the limit of
 * agc_set_alloc_limit longjmps once; one past the limit only marks the run, and
 * agc_alloc_limit_check (the next step) jumps; agc_release_all clears both.
 */
#include "../core.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
  agc_init();
#ifdef AGC_NO_GC
  jmp_buf over;
  static volatile int jumps = 0;
  switch (setjmp(over)) {
    case 0:
      agc_set_alloc_limit(&over, 4096);
      assert(agc_alloc(1024));
      agc_alloc(8192);
      assert(0);
      break;
    case 1:
      jumps++;
      assert(jumps == 1);
      break;
    default: assert(0);
  }
  agc_release_all();
  static volatile int checks = 0, allocated = 0;
  switch (setjmp(over)) {
    case 0:
      agc_set_alloc_limit(&over, 4096);
      assert(agc_alloc(3000) && !agc_alloc_over_limit());
      allocated = 1;
      assert(agc_alloc(3000) && agc_alloc_over_limit());
      allocated = 2;
      agc_alloc_limit_check();
      assert(0);
      break;
    case 1:
      // Both allocations returned, so the jump came from agc_alloc_limit_check, not from agc_alloc.
      checks++;
      assert(checks == 1 && allocated == 2);
      break;
    default: assert(0);
  }
  agc_release_all();
  assert(!agc_alloc_over_limit());
  agc_alloc_limit_check();
  unsigned char *p = agc_alloc(1 << 20);
  assert(p[0] == 0 && p[(1 << 20) - 1] == 0);
#endif
  puts("budget tests passed");
  return 0;
}

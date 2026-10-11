#include "../agc.h"

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
  unsigned char *p = agc_alloc(1 << 20);
  assert(p[0] == 0 && p[(1 << 20) - 1] == 0);
#endif
  puts("budget tests passed");
  return 0;
}

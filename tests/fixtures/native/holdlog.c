/* A library that shows whether it is loaded (tests/test_vm_native.py, Native.load): the loader runs the constructor
   when it maps the library and the destructor when the last hold is given back, and the file "hold.log" of the working
   folder exists in between. POSIX only: a DLL would need DllMain, and the test skips Windows. */
#include <stdio.h>
#include <unistd.h>

__attribute__((constructor)) static void mapped(void) {
  FILE *log = fopen("hold.log", "w");
  if (log) fclose(log);
}

__attribute__((destructor)) static void unmapped(void) { unlink("hold.log"); }

int hold_probe(void) { return 1; }

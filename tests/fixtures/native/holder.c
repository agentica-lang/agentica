/* The other holder of a library (tests/test_vm_native.py, Native.load): opens the library at PATH on its own, calls FN
   while that hold is taken and gives the hold back, as a probe of Native.function? does between its open and its
   close. POSIX only, like holdlog.c. */
#include <dlfcn.h>
#include <stddef.h>

int holder_around(const char *path, int (*fn)(int)) {
  void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!lib) return -1;
  int result = fn(1);
  dlclose(lib);
  return result;
}

/* A stand-in C compiler (tests/test_prop_cache_compiler.py): it prints the path of its own executable, so the test
   sees which file a start by name ran. */
#include <stdio.h>

#ifdef _WIN32
#include <windows.h>
#elif defined(__APPLE__)
#include <mach-o/dyld.h>
#include <stdint.h>
#else
#include <unistd.h>
#endif

int main(void) {
  char path[4096];
#ifdef _WIN32
  DWORD n = GetModuleFileNameA(NULL, path, sizeof path);
  if (n == 0 || n >= sizeof path) return 2;
#elif defined(__APPLE__)
  uint32_t size = sizeof path;
  if (_NSGetExecutablePath(path, &size) != 0) return 2;
#else
  ssize_t n = readlink("/proc/self/exe", path, sizeof path - 1);
  if (n < 0) return 2;
  path[n] = '\0';
#endif
  puts(path);
  return 0;
}

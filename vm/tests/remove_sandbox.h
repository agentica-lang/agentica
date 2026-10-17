/* Physical container-boundary check for destructive filesystem test binaries. */
#ifndef AGC_TEST_REMOVE_SANDBOX_H
#define AGC_TEST_REMOVE_SANDBOX_H

#include <stdio.h>
#include <string.h>

static int agc_test_has_mount_option(const char *options, const char *wanted) {
  size_t length = strlen(wanted);
  for (const char *part = options; part != NULL && *part;) {
    const char *end = strchr(part, ',');
    if (end == NULL) end = part + strlen(part);
    if ((size_t)(end - part) == length && memcmp(part, wanted, length) == 0) return 1;
    part = *end == ',' ? end + 1 : NULL;
  }
  return 0;
}

static int agc_test_remove_sandbox(void) {
  FILE *mounts = fopen("/proc/self/mountinfo", "r");
  if (mounts == NULL) return 0;
  int root_read_only = 0, source_read_only = 0, temp_is_tmpfs = 0;
  char line[8192], mountpoint[256], options[256], filesystem[64];
  while (fgets(line, sizeof line, mounts) != NULL) {
    if (sscanf(line, "%*s %*s %*s %*s %255s %255s", mountpoint, options) != 2) continue;
    char *separator = strstr(line, " - ");
    if (separator == NULL || sscanf(separator + 3, "%63s", filesystem) != 1) continue;
    if (strcmp(mountpoint, "/") == 0 && agc_test_has_mount_option(options, "ro")) root_read_only = true;
    if (strcmp(mountpoint, "/source") == 0 && agc_test_has_mount_option(options, "ro")) source_read_only = true;
    if (strcmp(mountpoint, "/tmp") == 0 && strcmp(filesystem, "tmpfs") == 0) temp_is_tmpfs = true;
  }
  fclose(mounts);
  if (root_read_only && source_read_only && temp_is_tmpfs) return 1;
  fprintf(stderr, "destructive filesystem test requires a read-only Docker root/source and /tmp tmpfs\n");
  return 0;
}

#endif

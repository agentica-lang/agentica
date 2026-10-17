/* Physical scratch-boundary checks for destructive filesystem test binaries. */
#ifndef AGC_TEST_REMOVE_SANDBOX_H
#define AGC_TEST_REMOVE_SANDBOX_H

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define AGC_TEST_SEP(c) ((c) == '/' || (c) == '\\')
static char agc_test_path_char(char c) { return (char)tolower((unsigned char)(AGC_TEST_SEP(c) ? '\\' : c)); }
#else
#define AGC_TEST_SEP(c) ((c) == '/')
static char agc_test_path_char(char c) { return c; }
#endif

static size_t agc_test_trim_path(const char *path) {
  size_t length = strlen(path);
  while (length > 1 && AGC_TEST_SEP(path[length - 1])) length--;
  return length;
}

static int agc_test_path_equal(const char *left, const char *right) {
  size_t left_len = agc_test_trim_path(left), right_len = agc_test_trim_path(right);
  if (left_len != right_len) return 0;
  for (size_t k = 0; k < left_len; k++) {
    if (agc_test_path_char(left[k]) != agc_test_path_char(right[k])) return 0;
  }
  return 1;
}

static int agc_test_path_within(const char *path, const char *root) {
  size_t path_len = agc_test_trim_path(path), root_len = agc_test_trim_path(root);
  if (path_len <= root_len) return 0;
  for (size_t k = 0; k < root_len; k++) {
    if (agc_test_path_char(path[k]) != agc_test_path_char(root[k])) return 0;
  }
  return AGC_TEST_SEP(path[root_len]);
}

#ifdef __linux__
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

static int agc_test_docker_mounts(void) {
  FILE *mounts = fopen("/proc/self/mountinfo", "r");
  if (mounts == NULL) return 0;
  int root_read_only = 0, source_read_only = 0, temp_is_tmpfs = 0;
  char line[8192], mountpoint[256], options[256], filesystem[64];
  while (fgets(line, sizeof line, mounts) != NULL) {
    if (sscanf(line, "%*s %*s %*s %*s %255s %255s", mountpoint, options) != 2) continue;
    char *separator = strstr(line, " - ");
    if (separator == NULL || sscanf(separator + 3, "%63s", filesystem) != 1) continue;
    if (strcmp(mountpoint, "/") == 0 && agc_test_has_mount_option(options, "ro")) root_read_only = 1;
    if (strcmp(mountpoint, "/source") == 0 && agc_test_has_mount_option(options, "ro")) source_read_only = 1;
    if (strcmp(mountpoint, "/tmp") == 0 && strcmp(filesystem, "tmpfs") == 0) temp_is_tmpfs = 1;
  }
  fclose(mounts);
  return root_read_only && source_read_only && temp_is_tmpfs;
}
#endif

static int agc_test_remove_sandbox(const char *scratch) {
  const char *mode = getenv("AGENTICA_REMOVE_TEST_MODE");
  if (!scratch || !*scratch) {
    fprintf(stderr, "destructive filesystem tests require an explicit scratch root\n");
    return 0;
  }
  if (strcmp(mode ? mode : "", "actions") == 0) {
    const char *runner = getenv("RUNNER_TEMP");
    const char *test_scratch = getenv("AGENTICA_REMOVE_TEST_SCRATCH");
    const char *actions = getenv("GITHUB_ACTIONS");
    const char *environment = getenv("AGENTICA_ACTIONS_RUNNER_ENVIRONMENT");
    if (runner && *runner && test_scratch && *test_scratch && actions && strcmp(actions, "true") == 0 &&
        environment && strcmp(environment, "github-hosted") == 0 &&
        agc_test_path_within(test_scratch, runner) &&
        (agc_test_path_equal(scratch, test_scratch) || agc_test_path_within(scratch, test_scratch)))
      return 1;
    fprintf(stderr, "destructive filesystem test scratch must be below per-run RUNNER_TEMP storage\n");
    return 0;
  }
  if (strcmp(mode ? mode : "", "docker") == 0) {
#ifdef __linux__
    if (agc_test_docker_mounts() && agc_test_path_within(scratch, "/tmp")) return 1;
#endif
    fprintf(stderr, "local destructive filesystem tests require read-only Docker mounts and /tmp tmpfs\n");
    return 0;
  }
  fprintf(stderr, "destructive filesystem tests require the local Docker or Actions runner launcher\n");
  return 0;
}

#endif

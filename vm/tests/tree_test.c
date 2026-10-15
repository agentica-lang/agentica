/*
 * The directory tree remover: links inside the tree go as links and their
 * targets survive, a link as the root is refused, missing and non-directory
 * roots, the names it refuses, and the depth limit.
 */
#include "../services.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define PATH_SIZE 4096

/* Writes base/name into out; the return value is checked, so a long path fails the test, not the format. */
static size_t join(char out[PATH_SIZE], const char *base, const char *name) {
  int n = snprintf(out, PATH_SIZE, "%s/%s", base, name);
  assert(n > 0 && n < PATH_SIZE);
  return (size_t)n;
}

static void make_dir(const char *base, const char *name) {
  char path[PATH_SIZE];
  join(path, base, name);
  assert(mkdir(path, 0700) == 0);
}

static void make_file(const char *base, const char *name) {
  char path[PATH_SIZE];
  join(path, base, name);
  int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
  assert(fd >= 0);
  assert(write(fd, "data", 4) == 4);
  close(fd);
}

static void make_link(const char *base, const char *name, const char *target) {
  char path[PATH_SIZE];
  join(path, base, name);
  assert(symlink(target, path) == 0);
}

static bool exists(const char *base, const char *name) {
  char path[PATH_SIZE];
  struct stat info;
  join(path, base, name);
  return lstat(path, &info) == 0;
}

static int remove_tree_at(const char *base, const char *name) {
  char path[PATH_SIZE];
  join(path, base, name);
  return agc_remove_tree(path);
}

/* `levels` directories, base/name and then "d" inside each, one in the other. */
static void make_chain(const char *base, const char *name, int levels) {
  char path[PATH_SIZE];
  size_t len = join(path, base, name);
  assert(mkdir(path, 0700) == 0);
  for (int k = 1; k < levels; k++) {
    assert(len + 3 < PATH_SIZE);
    memcpy(path + len, "/d", 3);
    len += 2;
    assert(mkdir(path, 0700) == 0);
  }
}

static void test_links_are_removed_not_followed(const char *base) {
  char outside[PATH_SIZE];
  join(outside, base, "outside");
  make_dir(base, "outside");
  make_file(base, "outside/keep.txt");
  make_dir(base, "outside/keep-dir");
  make_dir(base, "tree");
  make_dir(base, "tree/sub");
  make_dir(base, "tree/sub/deeper");
  make_file(base, "tree/sub/deeper/f.txt");
  make_file(base, "tree/top.txt");
  make_link(base, "tree/to-dir", outside);
  make_link(base, "tree/sub/to-file", "../../outside/keep.txt");
  make_link(base, "tree/dangling", "/does/not/exist");
  assert(remove_tree_at(base, "tree") == 0);
  assert(!exists(base, "tree"));
  assert(exists(base, "outside/keep.txt"));
  assert(exists(base, "outside/keep-dir"));
}

static void test_a_link_root_is_refused(const char *base) {
  char outside[PATH_SIZE];
  join(outside, base, "outside");
  make_link(base, "root-link", outside);
  int rc = remove_tree_at(base, "root-link");
  assert(rc == ENOTDIR || rc == ELOOP);
  /* A trailing slash must not make the kernel follow the link. */
  rc = remove_tree_at(base, "root-link/");
  assert(rc == ENOTDIR || rc == ELOOP);
  assert(exists(base, "root-link"));
  assert(exists(base, "outside/keep.txt"));
  char link[PATH_SIZE];
  join(link, base, "root-link");
  assert(unlink(link) == 0);
}

static void test_bad_roots(const char *base) {
  assert(remove_tree_at(base, "missing") == ENOENT);
  make_file(base, "plain.txt");
  assert(remove_tree_at(base, "plain.txt") == ENOTDIR);
  assert(exists(base, "plain.txt"));
  assert(agc_remove_tree("/") == AGC_TREE_REFUSED);
  assert(agc_remove_tree("//") == AGC_TREE_REFUSED);
  assert(agc_remove_tree(".") == AGC_TREE_REFUSED);
  assert(agc_remove_tree("..") == AGC_TREE_REFUSED);
  assert(agc_remove_tree("") == AGC_TREE_REFUSED);
  assert(remove_tree_at(base, ".") == AGC_TREE_REFUSED);
  assert(remove_tree_at(base, "outside/..") == AGC_TREE_REFUSED);
  assert(remove_tree_at(base, "outside/../") == AGC_TREE_REFUSED);
  assert(exists(base, "outside/keep.txt"));
}

static void test_depth_limit(const char *base) {
  make_chain(base, "fits", AGC_TREE_MAX_DEPTH);
  assert(remove_tree_at(base, "fits") == 0);
  assert(!exists(base, "fits"));

  make_chain(base, "deep", AGC_TREE_MAX_DEPTH + 1);
  assert(remove_tree_at(base, "deep") == AGC_TREE_TOO_DEEP);
  assert(exists(base, "deep"));
  /* Clean up from the middle, so that each call stays within the limit. */
  char path[PATH_SIZE];
  size_t len = join(path, base, "deep");
  for (int k = 0; k < AGC_TREE_MAX_DEPTH / 2; k++) {
    memcpy(path + len, "/d", 3);
    len += 2;
  }
  assert(agc_remove_tree(path) == 0);
  assert(remove_tree_at(base, "deep") == 0);
  assert(!exists(base, "deep"));
}

int main(void) {
  const char *tmp = getenv("TMPDIR");
  char base[PATH_SIZE];
  int n = snprintf(base, sizeof base, "%s/agc-tree-test-XXXXXX", tmp && *tmp ? tmp : "/tmp");
  assert(n > 0 && n < PATH_SIZE);
  assert(mkdtemp(base));
  test_links_are_removed_not_followed(base);
  test_a_link_root_is_refused(base);
  test_bad_roots(base);
  test_depth_limit(base);
  assert(remove_tree_at(base, "outside") == 0);
  char plain[PATH_SIZE];
  join(plain, base, "plain.txt");
  assert(unlink(plain) == 0);
  assert(rmdir(base) == 0);
  puts("tree tests passed");
  return 0;
}

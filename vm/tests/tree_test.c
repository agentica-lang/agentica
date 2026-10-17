/*
 * The tree remover. Real removals run with the working directory in a fresh scratch directory, on paths inside it;
 * the names that must be refused are only asked of agc_tree_refused, so a regression cannot delete a real tree.
 * This binary defines openat and unlinkat: they swap a directory for a link at the worst moment, and play a file
 * system that lies, refuses or is interrupted.
 */
#define _GNU_SOURCE
#include "../services.h"
#include "remove_sandbox.h"

#include <stdio.h>

#ifdef __linux__
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define PATH_SIZE 4096

/* What the interposed calls do; all zero passes every call through. */
typedef struct {
  char base[PATH_SIZE];
  bool swap_armed, lie, stick, vanish_rmdir, vanish_open;
  int swaps, interrupts;
} traps;

static traps trap;

/* Just before tree.c opens an entry named "swap", the directory is moved to base/away and a link to base/outside
   takes its name: a walk that followed links would now empty base/outside. */
static void swap_in_link(int dir_fd, const char *name) {
  char away[PATH_SIZE], outside[PATH_SIZE];
  int a = snprintf(away, sizeof away, "%s/away", trap.base);
  int o = snprintf(outside, sizeof outside, "%s/outside", trap.base);
  assert(a > 0 && a < PATH_SIZE && o > 0 && o < PATH_SIZE);
  assert(renameat(dir_fd, name, AT_FDCWD, away) == 0);
  assert(symlinkat(outside, dir_fd, name) == 0);
  trap.swap_armed = false;
  trap.swaps++;
}

/* Both openat and __openat_2 are defined: gcc's tree.c calls openat, and a fortified clang build (-O2
   -D_FORTIFY_SOURCE=2, as the release build) calls __openat_2, which in glibc's headers calls openat again.
   Both go through this one function, which makes the system call itself, so neither can call the other. */
static int trapped_openat(int dir_fd, const char *name, int flags, unsigned int mode) {
  if (dir_fd != AT_FDCWD && trap.swap_armed && strcmp(name, "swap") == 0) swap_in_link(dir_fd, name);
  if (dir_fd != AT_FDCWD && trap.vanish_open && strcmp(name, "gone") == 0)
    assert(syscall(SYS_unlinkat, dir_fd, name, AT_REMOVEDIR) == 0);
  return (int)syscall(SYS_openat, dir_fd, name, flags, mode);
}

int openat(int dir_fd, const char *name, int flags, ...) {
  unsigned int mode = 0;
  if (flags & (O_CREAT | O_TMPFILE)) {
    va_list args;
    va_start(args, flags);
    mode = va_arg(args, unsigned int);
    va_end(args);
  }
  return trapped_openat(dir_fd, name, flags, mode);
}

// glibc's own name for the checked openat.
int __openat_2(int dir_fd, const char *name, int flags) { // NOLINT(readability-identifier-naming)
  return trapped_openat(dir_fd, name, flags, 0);
}

int unlinkat(int dir_fd, const char *name, int flags) {
  if (trap.lie && flags == 0 && strcmp(name, "liar") == 0) {
    errno = ENOENT;
    return -1;
  }
  if (trap.stick && flags == 0 && strcmp(name, "stuck") == 0) {
    errno = EPERM;
    return -1;
  }
  if (trap.vanish_rmdir && (flags & AT_REMOVEDIR) && strcmp(name, "gone") == 0)
    assert(syscall(SYS_unlinkat, dir_fd, name, AT_REMOVEDIR) == 0);
  if (trap.interrupts > 0 && strcmp(name, "flaky") == 0) {
    trap.interrupts--;
    errno = EINTR;
    return -1;
  }
  return (int)syscall(SYS_unlinkat, dir_fd, name, flags);
}

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

static bool is_link(const char *base, const char *name) {
  char path[PATH_SIZE];
  struct stat info;
  join(path, base, name);
  return lstat(path, &info) == 0 && S_ISLNK(info.st_mode);
}

static int remove_tree_at(const char *base, const char *name, char **failed) {
  char path[PATH_SIZE];
  join(path, base, name);
  return agc_remove_tree(path, failed);
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

static int open_fds(void) {
  DIR *dir = opendir("/proc/self/fd");
  assert(dir);
  int count = 0;
  while (readdir(dir)) count++;
  closedir(dir);
  return count;
}

static void test_refused_names_by_the_predicate_only(const char *base) {
  (void)base;
  const char *refused[] = {"", "/", "//", ".", "..", "./", "../", "/.", "/..", "a/.", "a/..", "a/../", "a//..//",
                           "/a/.."};
  const char *allowed[] = {"a", "/a", "a/b", "./a", "../a", "a/.b", "a/..b", "a/b.", "...", ".hidden", "a/.../"};
  for (size_t k = 0; k < sizeof refused / sizeof refused[0]; k++) assert(agc_tree_refused(refused[k]));
  for (size_t k = 0; k < sizeof allowed / sizeof allowed[0]; k++) assert(!agc_tree_refused(allowed[k]));
}

static void test_the_remover_asks_the_predicate_first(const char *base) {
  make_dir(base, "guarded");
  make_dir(base, "guarded/a");
  make_file(base, "guarded/a/keep.txt");
  /* The target of each is base/guarded: the scratch directory is all a regression could remove. */
  char *failed = (char *)"unset";
  assert(remove_tree_at(base, "guarded/a/..", &failed) == AGC_TREE_REFUSED);
  assert(failed == NULL);
  assert(remove_tree_at(base, "guarded/a/../", NULL) == AGC_TREE_REFUSED);
  assert(remove_tree_at(base, "guarded/.", NULL) == AGC_TREE_REFUSED);
  assert(exists(base, "guarded/a/keep.txt"));
  assert(remove_tree_at(base, "guarded", &failed) == 0);
  assert(failed == NULL);
  assert(!exists(base, "guarded"));
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
  assert(remove_tree_at(base, "tree", NULL) == 0);
  assert(!exists(base, "tree"));
  assert(exists(base, "outside/keep.txt"));
  assert(exists(base, "outside/keep-dir"));
}

static void test_a_link_root_is_refused(const char *base) {
  char outside[PATH_SIZE];
  join(outside, base, "outside");
  make_link(base, "root-link", outside);
  int rc = remove_tree_at(base, "root-link", NULL);
  assert(rc == ENOTDIR || rc == ELOOP);
  /* A trailing slash must not make the kernel follow the link. */
  rc = remove_tree_at(base, "root-link/", NULL);
  assert(rc == ENOTDIR || rc == ELOOP);
  assert(is_link(base, "root-link"));
  assert(exists(base, "outside/keep.txt"));
  char link[PATH_SIZE];
  join(link, base, "root-link");
  assert(unlink(link) == 0);
  assert(remove_tree_at(base, "outside", NULL) == 0);
}

static void test_bad_roots(const char *base) {
  char *failed = (char *)"unset";
  assert(remove_tree_at(base, "missing", &failed) == ENOENT);
  assert(failed == NULL);
  make_file(base, "plain.txt");
  assert(remove_tree_at(base, "plain.txt", NULL) == ENOTDIR);
  assert(exists(base, "plain.txt"));
  char plain[PATH_SIZE];
  join(plain, base, "plain.txt");
  assert(unlink(plain) == 0);
}

static void test_depth_limit(const char *base) {
  make_chain(base, "fits", AGC_TREE_MAX_DEPTH);
  assert(remove_tree_at(base, "fits", NULL) == 0);
  assert(!exists(base, "fits"));

  make_chain(base, "deep", AGC_TREE_MAX_DEPTH + 1);
  assert(remove_tree_at(base, "deep", NULL) == AGC_TREE_TOO_DEEP);
  assert(exists(base, "deep"));
  /* Clean up from the middle, so that each call stays within the limit. */
  char path[PATH_SIZE];
  size_t len = join(path, base, "deep");
  for (int k = 0; k < AGC_TREE_MAX_DEPTH / 2; k++) {
    memcpy(path + len, "/d", 3);
    len += 2;
  }
  assert(agc_remove_tree(path, NULL) == 0);
  assert(remove_tree_at(base, "deep", NULL) == 0);
  assert(!exists(base, "deep"));
}

/* The main race: a directory the walk found is replaced by a link before it is opened. The link stays, what it
   names is untouched, and the walk ends with ENOTEMPTY (the entry could not be removed as a directory, and a pass
   that removed nothing is the end). Without O_NOFOLLOW the walk empties base/outside; without the skip of an
   entry that turned into a link the error would be ENOTDIR or ELOOP. */
static void test_a_directory_swapped_for_a_link_is_not_followed(const char *base) {
  make_dir(base, "outside");
  make_dir(base, "outside/inner");
  make_file(base, "outside/keep.txt");
  make_file(base, "outside/inner/keep2.txt");
  make_dir(base, "victim");
  make_dir(base, "victim/swap");
  make_dir(base, "victim/swap/deeper");
  make_file(base, "victim/swap/deeper/f.txt");
  assert(snprintf(trap.base, sizeof trap.base, "%s", base) < PATH_SIZE);
  trap.swap_armed = true;
  trap.swaps = 0;
  assert(remove_tree_at(base, "victim", NULL) == ENOTEMPTY);
  assert(trap.swaps == 1);
  assert(exists(base, "outside/keep.txt"));
  assert(exists(base, "outside/inner/keep2.txt"));
  assert(is_link(base, "victim/swap"));
  assert(exists(base, "away/deeper/f.txt"));
  /* With the swap spent, the same tree goes, the link as a link. */
  assert(remove_tree_at(base, "victim", NULL) == 0);
  assert(exists(base, "outside/keep.txt"));
  assert(remove_tree_at(base, "away", NULL) == 0);
  assert(remove_tree_at(base, "outside", NULL) == 0);
}

/* A failure inside the tree names the entry; a failure of the root names nothing, since the caller has it. */
static void test_a_failure_inside_the_tree_names_the_entry(const char *base) {
  make_dir(base, "named");
  make_dir(base, "named/a");
  make_dir(base, "named/a/b");
  make_file(base, "named/a/b/stuck");
  make_file(base, "named/a/b/other");
  trap.stick = true;
  char *failed = NULL;
  assert(remove_tree_at(base, "named", &failed) == EPERM);
  char want[PATH_SIZE];
  join(want, base, "named/a/b/stuck");
  assert(failed && strcmp(failed, want) == 0);
  free(failed);
  trap.stick = false;
  assert(remove_tree_at(base, "named", &failed) == 0);
  assert(failed == NULL);
}

/* Real permissions: a directory the user cannot write into stops the walk at its first entry. Root ignores the
   mode bits, so the case is skipped there. */
static void test_a_directory_without_write_permission_stops_the_walk(const char *base) {
  if (geteuid() == 0) {
    puts("tree test: EACCES case skipped (running as root)");
    return;
  }
  make_dir(base, "locked");
  make_dir(base, "locked/sub");
  make_file(base, "locked/sub/f.txt");
  char sub[PATH_SIZE];
  join(sub, base, "locked/sub");
  assert(chmod(sub, 0500) == 0);
  char *failed = NULL;
  assert(remove_tree_at(base, "locked", &failed) == EACCES);
  char want[PATH_SIZE];
  join(want, base, "locked/sub/f.txt");
  assert(failed && strcmp(failed, want) == 0);
  free(failed);
  assert(exists(base, "locked/sub/f.txt"));
  assert(chmod(sub, 0700) == 0);
  assert(remove_tree_at(base, "locked", NULL) == 0);
}

/* A name that readdir lists and unlinkat says is gone, again and again: not progress, so the walk must end. */
static void test_a_file_system_that_lies_ends_the_walk(const char *base) {
  make_dir(base, "lies");
  make_file(base, "lies/liar");
  trap.lie = true;
  assert(remove_tree_at(base, "lies", NULL) == ENOTEMPTY);
  trap.lie = false;
  assert(remove_tree_at(base, "lies", NULL) == 0);
}

static void test_an_interrupted_call_is_repeated(const char *base) {
  make_dir(base, "slow");
  make_file(base, "slow/flaky");
  trap.interrupts = 1;
  assert(remove_tree_at(base, "slow", NULL) == 0);
  assert(trap.interrupts == 0);
  assert(!exists(base, "slow"));
}

/* A subdirectory that someone else removes while the walk is inside the tree is gone, which is what the walk wants:
   neither the final rmdir of it nor its open is an error, and the rest of the tree goes. */
static void test_a_subdirectory_that_vanishes_is_not_an_error(const char *base) {
  for (int phase = 0; phase < 2; phase++) {
    make_dir(base, "vanish");
    make_dir(base, "vanish/gone");
    make_file(base, "vanish/aa");
    make_file(base, "vanish/zz");
    trap.vanish_rmdir = phase == 0;
    trap.vanish_open = phase == 1;
    assert(remove_tree_at(base, "vanish", NULL) == 0);
    trap.vanish_rmdir = trap.vanish_open = false;
    assert(!exists(base, "vanish"));
  }
}

/* Runs a case and checks that it left no descriptor open, whether it ended in success or in an error. */
static void run_case(void (*test)(const char *), const char *base) {
  int before = open_fds();
  test(base);
  assert(open_fds() == before);
}

int main(void) {
  if (!agc_test_remove_sandbox()) return 1;
  /* A walk that never ends fails the test instead of hanging the build. */
  alarm(60);
  const char *tmp = getenv("TMPDIR");
  char base[PATH_SIZE];
  int n = snprintf(base, sizeof base, "%s/agc-tree-test-XXXXXX", tmp && *tmp ? tmp : "/tmp");
  assert(n > 0 && n < PATH_SIZE);
  assert(base[0] == '/');
  assert(mkdtemp(base));
  char home[PATH_SIZE];
  assert(getcwd(home, sizeof home));
  assert(chdir(base) == 0);
  run_case(test_refused_names_by_the_predicate_only, base);
  run_case(test_the_remover_asks_the_predicate_first, base);
  run_case(test_links_are_removed_not_followed, base);
  run_case(test_a_link_root_is_refused, base);
  run_case(test_bad_roots, base);
  run_case(test_depth_limit, base);
  run_case(test_a_directory_swapped_for_a_link_is_not_followed, base);
  run_case(test_a_failure_inside_the_tree_names_the_entry, base);
  run_case(test_a_directory_without_write_permission_stops_the_walk, base);
  run_case(test_a_file_system_that_lies_ends_the_walk, base);
  run_case(test_an_interrupted_call_is_repeated, base);
  run_case(test_a_subdirectory_that_vanishes_is_not_an_error, base);
  assert(chdir(home) == 0);
  assert(agc_remove_tree(base, NULL) == 0);
  puts("tree tests passed");
  return 0;
}
#else
int main(void) {
  puts("tree tests skipped");
  return 0;
}
#endif

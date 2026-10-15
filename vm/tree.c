/*
 * Removal of a directory tree that never follows a symbolic link (Linux only):
 * the root and every sub-directory are opened with openat(O_NOFOLLOW |
 * O_DIRECTORY) and each entry is deleted with unlinkat on its parent's
 * descriptor, so a link in the tree, or one swapped in while the walk runs, is
 * removed as a link and what it names is never touched. A mount point inside
 * the tree is crossed, as rm -rf does. No VM state; Path.remove in files.c runs
 * it on a pool thread. Service layer. Design: docs/vm/02-reference-behavior.md.
 */
#include "services.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#ifdef __linux__
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>

/* One open directory of the walk. `removed` counts the entries this pass deleted; `name` is the directory's
   name in its parent (unused for the root). */
typedef struct {
  DIR *dir;
  size_t removed;
  char name[NAME_MAX + 1];
} level;

static bool is_dots(const char *name) { return strcmp(name, ".") == 0 || strcmp(name, "..") == 0; }

/* The three calls below can return EINTR on a network file system and never on a local one, and each is safe to
   repeat. */
static int remove_at(int parent, const char *name, int flags) {
  int rc;
  do {
    rc = unlinkat(parent, name, flags);
  } while (rc != 0 && errno == EINTR);
  return rc;
}

static int open_dir(int parent, const char *name, DIR **dir) {
  int fd;
  do {
    fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  } while (fd < 0 && errno == EINTR);
  if (fd < 0) return errno;
  *dir = fdopendir(fd);
  if (*dir) return 0;
  int err = errno;
  close(fd);
  return err;
}

/* NULL with errno 0 at the end of the directory, NULL with an errno on a failure. */
static const struct dirent *next_entry(DIR *dir) {
  const struct dirent *entry;
  do {
    errno = 0;
    entry = readdir(dir);
  } while (!entry && errno == EINTR);
  return entry;
}

static void close_levels(level *levels, size_t top) {
  for (size_t k = 0; k <= top; k++) closedir(levels[k].dir);
}

/* The root, the names of levels 1..top, then `entry` unless it is NULL, joined with '/'. NULL when malloc fails:
   the error is then reported without the entry. */
static char *entry_path(const char *root, const level *levels, size_t top, const char *entry) {
  size_t len = strlen(root) + (entry ? strlen(entry) + 1 : 0);
  for (size_t k = 1; k <= top; k++) len += strlen(levels[k].name) + 1;
  char *path = malloc(len + 1);
  if (!path) return NULL;
  size_t used = strlen(root);
  memcpy(path, root, used);
  for (size_t k = 1; k <= top + (entry ? 1 : 0); k++) {
    const char *part = k <= top ? levels[k].name : entry;
    size_t part_len = strlen(part);
    path[used++] = '/';
    memcpy(path + used, part, part_len);
    used += part_len;
  }
  path[used] = '\0';
  return path;
}

/* Empties and removes the directory at levels[0] with an explicit stack, so the depth of the tree decides
   nothing about the C stack. Each directory is read in passes: POSIX does not say whether readdir still returns
   the entries that follow one that was just unlinked, so a pass that removed something is repeated until
   rmdir succeeds, and a pass that removed nothing ends the walk with ENOTEMPTY. That rule also ends a walk over
   a file system that lists a name it cannot remove: an ENOENT from unlinkat is not progress. On a failure inside
   the tree, *failed is the path of the entry (or of the directory) that failed. The root is removed by its path:
   rmdir only takes an empty directory, so a path swapped at this point costs nothing. */
static int walk(const char *root, level *levels, char **failed) {
  int rc = open_dir(AT_FDCWD, root, &levels[0].dir);
  if (rc) return rc;
  size_t top = 0;
  const char *culprit = NULL;
  for (;;) {
    level *at = &levels[top];
    const struct dirent *entry = next_entry(at->dir);
    if (entry) {
      if (is_dots(entry->d_name)) continue;
      int dir_fd = dirfd(at->dir);
      /* unlinkat never follows a link, and Linux answers EISDIR for a directory. */
      if (remove_at(dir_fd, entry->d_name, 0) == 0) {
        at->removed++;
        continue;
      }
      if (errno == ENOENT) continue;
      if (errno != EISDIR) {
        culprit = entry->d_name;
        rc = errno;
        break;
      }
      if (top + 1 == AGC_TREE_MAX_DEPTH) {
        rc = AGC_TREE_TOO_DEEP;
        break;
      }
      DIR *child;
      rc = open_dir(dir_fd, entry->d_name, &child);
      /* The entry became a link or a file, or went away, after unlinkat said directory: leave it. If something
         else in this directory was removed in this pass, the next pass meets the entry again; if not, the pass
         ends with ENOTEMPTY, so an entry that keeps changing cannot make the walk loop. */
      if (rc == ELOOP || rc == ENOTDIR || rc == ENOENT) {
        rc = 0;
        continue;
      }
      if (rc) {
        culprit = entry->d_name;
        break;
      }
      size_t name_len = strlen(entry->d_name);
      if (name_len >= sizeof levels[top].name) {
        closedir(child);
        culprit = entry->d_name;
        rc = ENAMETOOLONG;
        break;
      }
      top++;
      levels[top].dir = child;
      levels[top].removed = 0;
      memcpy(levels[top].name, entry->d_name, name_len + 1);
      continue;
    }
    if (errno) {
      rc = errno;
      break;
    }
    int gone = remove_at(top ? dirfd(levels[top - 1].dir) : AT_FDCWD, top ? at->name : root, AT_REMOVEDIR);
    /* A directory that someone else removed is gone, which is what the walk wants, but it is not our progress. */
    if (gone == 0 || errno == ENOENT) {
      closedir(at->dir);
      if (top == 0) return 0;
      top--;
      if (gone == 0) levels[top].removed++;
      continue;
    }
    if ((errno == ENOTEMPTY || errno == EEXIST) && at->removed > 0) {
      rewinddir(at->dir);
      at->removed = 0;
      continue;
    }
    rc = errno;
    break;
  }
  if (rc > 0 && failed && (top > 0 || culprit)) *failed = entry_path(root, levels, top, culprit);
  close_levels(levels, top);
  return rc;
}

int agc_remove_tree(const char *path, char **failed) {
  if (failed) *failed = NULL;
  if (agc_tree_refused(path)) return AGC_TREE_REFUSED;
  /* Trailing slashes are cut: "link/" would make the kernel follow "link". */
  size_t len = strlen(path);
  while (len > 1 && path[len - 1] == '/') len--;
  char *root = malloc(len + 1);
  level *levels = calloc(AGC_TREE_MAX_DEPTH, sizeof(level));
  int rc = ENOMEM;
  if (root && levels) {
    memcpy(root, path, len);
    root[len] = '\0';
    rc = walk(root, levels, failed);
  }
  free(levels);
  free(root);
  return rc;
}
#else
int agc_remove_tree(const char *path, char **failed) {
  (void)path;
  if (failed) *failed = NULL;
  return ENOSYS;
}
#endif

/* A pure function, kept apart from the walk, so a test can try every name that must never be removed without
   removing anything. The last component (trailing slashes ignored) has to name the tree itself: "/" and "" have
   none, "." and ".." name a directory by where it is, and ".." is a way to climb out of the tree. */
bool agc_tree_refused(const char *path) {
  size_t len = strlen(path);
  while (len > 0 && path[len - 1] == '/') len--;
  size_t start = len;
  while (start > 0 && path[start - 1] != '/') start--;
  size_t last = len - start;
  if (last == 0) return true;
  return (last == 1 && path[start] == '.') || (last == 2 && path[start] == '.' && path[start + 1] == '.');
}

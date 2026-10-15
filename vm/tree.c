/*
 * Removal of a directory tree that never follows a symbolic link (Linux only):
 * the root and every sub-directory are opened with openat(O_NOFOLLOW |
 * O_DIRECTORY) and each entry is deleted with unlinkat on its parent's
 * descriptor, so a link in the tree, or one swapped in while the walk runs, is
 * removed as a link and what it names is never touched. One function,
 * agc_remove_tree, for Path.remove in files.c; it runs on a pool thread and
 * uses no VM state. Service layer. Design: docs/vm/02-reference-behavior.md §2.8.
 */
#include "services.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#ifdef __linux__
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>

/* One open directory of the walk. `seen` and `removed` count the entries of the
   current pass; `name` is the entry's name in its parent (unused for the root). */
typedef struct {
  DIR *dir;
  size_t seen, removed;
  char name[NAME_MAX + 1];
} level;

static bool is_dots(const char *name) { return strcmp(name, ".") == 0 || strcmp(name, "..") == 0; }

/* The final component of the path must name the tree itself, so "/", "." and
   ".." (the last one a way to climb out of it) are never removed. */
static bool refused(const char *path, size_t len) {
  size_t start = len;
  while (start > 0 && path[start - 1] != '/') start--;
  size_t last = len - start;
  if (last == 0) return true;
  return (last == 1 && path[start] == '.') || (last == 2 && path[start] == '.' && path[start + 1] == '.');
}

static int open_dir(int parent, const char *name, DIR **dir) {
  int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return errno;
  *dir = fdopendir(fd);
  if (*dir) return 0;
  int err = errno;
  close(fd);
  return err;
}

static void close_levels(level *levels, size_t top) {
  for (size_t k = 0; k <= top; k++) closedir(levels[k].dir);
}

/* Empties and removes the directory at levels[0] with an explicit stack, so the
   depth of the tree decides nothing about the C stack. Each directory is read
   in passes: POSIX does not say whether readdir still returns the entries that
   follow one that was just unlinked, so a pass that removed something is
   repeated until rmdir succeeds, and a pass that removed nothing ends the walk. */
static int walk(const char *root, level *levels) {
  int rc = open_dir(AT_FDCWD, root, &levels[0].dir);
  if (rc) return rc;
  size_t top = 0;
  for (;;) {
    level *at = &levels[top];
    errno = 0;
    const struct dirent *entry = readdir(at->dir);
    if (entry) {
      if (is_dots(entry->d_name)) continue;
      at->seen++;
      int dir_fd = dirfd(at->dir);
      /* unlinkat never follows a link, and Linux answers EISDIR for a directory. */
      if (unlinkat(dir_fd, entry->d_name, 0) == 0 || errno == ENOENT) {
        at->removed++;
        continue;
      }
      if (errno != EISDIR) {
        rc = errno;
        break;
      }
      if (top + 1 == AGC_TREE_MAX_DEPTH) {
        rc = AGC_TREE_TOO_DEEP;
        break;
      }
      DIR *child;
      rc = open_dir(dir_fd, entry->d_name, &child);
      /* The entry turned into a link or a file after unlinkat said directory:
         leave it, the next pass meets it again (and the walk ends if it keeps
         changing, since a pass without progress is an error). */
      if (rc == ELOOP || rc == ENOTDIR) {
        rc = 0;
        continue;
      }
      if (rc) break;
      size_t name_len = strlen(entry->d_name);
      if (name_len >= sizeof levels[top].name) {
        closedir(child);
        rc = ENAMETOOLONG;
        break;
      }
      top++;
      levels[top].dir = child;
      levels[top].seen = levels[top].removed = 0;
      memcpy(levels[top].name, entry->d_name, name_len + 1);
      continue;
    }
    if (errno) {
      rc = errno;
      break;
    }
    int gone = top ? unlinkat(dirfd(levels[top - 1].dir), at->name, AT_REMOVEDIR) : rmdir(root);
    if (gone == 0) {
      closedir(at->dir);
      if (top == 0) return 0;
      top--;
      levels[top].removed++;
      continue;
    }
    if ((errno == ENOTEMPTY || errno == EEXIST) && at->removed > 0) {
      rewinddir(at->dir);
      at->seen = at->removed = 0;
      continue;
    }
    rc = errno;
    break;
  }
  close_levels(levels, top);
  return rc;
}

int agc_remove_tree(const char *path) {
  size_t len = strlen(path);
  while (len > 1 && path[len - 1] == '/') len--;
  if (refused(path, len)) return AGC_TREE_REFUSED;
  /* Trailing slashes are cut: "link/" would make the kernel follow "link". */
  char *root = malloc(len + 1);
  level *levels = calloc(AGC_TREE_MAX_DEPTH, sizeof(level));
  int rc = ENOMEM;
  if (root && levels) {
    memcpy(root, path, len);
    root[len] = '\0';
    rc = walk(root, levels);
  }
  free(levels);
  free(root);
  return rc;
}
#else
int agc_remove_tree(const char *path) {
  (void)path;
  return ENOSYS;
}
#endif

/* A scratch directory for file tests, shared so the setup is written once. */
#ifndef AGC_SCRATCH_DIR_H
#define AGC_SCRATCH_DIR_H

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <uv.h>

/* A fresh empty directory, made with mkdtemp under the OS temporary
   directory: DIRECTORY (room for 4300 chars) receives its path and REQ the
   finished request. Unlink the entries when done, then remove it with
   uv_fs_rmdir and clean the request. */
static inline void agc_test_scratch(char *directory, uv_fs_t *req, const char *tag) {
  char temporary[4096];
  size_t size = sizeof temporary;
  assert(uv_os_tmpdir(temporary, &size) == 0);
  char pattern[4300];
  assert(snprintf(pattern, sizeof pattern, "%s/agentica-%s-XXXXXX", temporary, tag) > 0);
  assert(uv_fs_mkdtemp(NULL, req, pattern, NULL) == 0);
  /* The request carries the made path; the template is not reliable. */
  assert(strlen(req->path) < 4300);
  memcpy(directory, req->path, strlen(req->path) + 1);
  uv_fs_req_cleanup(req);
}

#endif

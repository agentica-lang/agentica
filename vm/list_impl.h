#ifndef AGC_LIST_IMPL_H
#define AGC_LIST_IMPL_H

#include <stdlib.h>

#include "value.h"

struct agc_list {
  size_t len;
  agc_value items[];
};

static inline size_t list_len(const agc_list *l) { return l->len; }

static inline agc_value list_get(const agc_list *l, size_t i) {
  if (i >= l->len) abort();
  return l->items[i];
}

#endif

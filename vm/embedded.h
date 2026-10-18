/*
 * The data that the single binary carries: the compiled front end, the std/
 * sources and the two programs of `agentica test` (its runner and its default
 * step program). make generates embedded.s, which .incbin's the files and
 * defines these two symbols; agentica.c is the only reader. Driver header.
 * Design: docs/future/18-front-end-language.md §18.8 and docs/vm/08-loader-and-cli.md.
 */
#ifndef AGC_EMBEDDED_H
#define AGC_EMBEDDED_H

#include <stdint.h>

/* The start of the data. Every offset below is from here. */
extern const uint8_t agc_embedded_data[];

/* Numbers, 64 bits each, fixed when the file is assembled:
 *   [0] [1]    offset and length of the front end (a .agcb file)
 *   [2] [3]    offset and length of the BDD runner (a .agcb file); the length is 0 in the first binary of the bootstrap
 *   [4] [5]    offset and length of the default step program of `agentica test` (a .agcb file); 0 as well there
 *   [6]        the number of std/ sources, N
 *   [7 + 3k]   offset of the path of source k, a NUL-terminated name relative to stdlib/ ("bdd/gherkin.agc")
 *   [8 + 3k]   offset of the text of source k
 *   [9 + 3k]   length of the text of source k */
extern const uint64_t agc_embedded_index[];

#endif

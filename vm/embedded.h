/*
 * The data that the single binary carries: the compiled front end and the
 * std/ sources. make generates embedded.S, which .incbin's the files and
 * defines these two symbols; agentica.c is the only reader. Driver header.
 * Design: docs/future/35-self-hosting.md §35.6 and docs/vm/08-loader-and-cli.md.
 */
#ifndef AGC_EMBEDDED_H
#define AGC_EMBEDDED_H

#include <stdint.h>

/* The start of the data. Every offset below is from here. */
extern const uint8_t agc_embedded_data[];

/* Numbers, 64 bits each, fixed when the file is assembled:
 *   [0] [1]    offset and length of the front end (a .agcb file)
 *   [2]        the number of std/ sources, N
 *   [3 + 3k]   offset of the path of source k, a NUL-terminated name relative to stdlib/ ("bdd/gherkin.agc")
 *   [4 + 3k]   offset of the text of source k
 *   [5 + 3k]   length of the text of source k */
extern const uint64_t agc_embedded_index[];

#endif

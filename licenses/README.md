# Licenses

Agentica is licensed under the Apache License 2.0 with the LLVM exception (SPDX:
`Apache-2.0 WITH LLVM-exception`). See [`LICENSE`](../LICENSE) and
[`NOTICE`](../NOTICE).

- If you redistribute Agentica, as source or binaries, changed or not, keep
  `LICENSE` and `NOTICE` with it and mark files you changed (Apache-2.0 section
  4 has the full conditions).
- Programs you write in Agentica are yours; this license does not cover them.
  When compiling your program puts parts of Agentica into the compiled output
  (for example an imported `std/` module linked into your `.agcb`), the LLVM
  exception lets you ship that output without Agentica's `LICENSE` and `NOTICE`.
  Shipping Agentica itself with your program (`agentica`) is redistribution:
  keep `LICENSE` and `NOTICE` with it. If you combine Agentica with GPLv2
  software and a court finds a part of this license in conflict with GPLv2, the
  exception also lets you set that part aside for the combined software.
- Third-party components keep their own licenses, and the LLVM exception does
  not cover them; their notices apply wherever they are shipped:
  - the Boehm GC (`vm/third_party/bdwgc`): the Boehm-GC license, with its notice
    in `README.QUICK`;
  - libuv (`vm/third_party/libuv`): MIT, with BSD-2-Clause and ISC parts in its
    `LICENSE-extra`;
  - yyjson (`vm/third_party/yyjson`): MIT;
  - the Unicode character data in `vm/unicode_data.c`, derived from the Unicode
    Character Database (Unicode 17.0, determined by counting the graphic and
    format code points of Racket 9.3's tables): Unicode License v3;
  - picohttpparser (`vm/third_party/picohttpparser`): MIT or the Perl license
    (dual), with its notice at the top of `picohttpparser.h`;
  - OpenSSL 3 (`vm/third_party/openssl`): Apache-2.0, with its license in
    `LICENSE.txt`;
  - libffi (`vm/third_party/libffi`, built into the Linux x86_64 binary for the
    native calls): MIT, with its license in `LICENSE`;
  - zlib (`vm/third_party/zlib`, v1.3.1, codec sources used by `Zlib`):
    zlib license, with its license in `LICENSE`;

Every release archive (Linux, macOS and Windows) ships these notices in
`licenses/`: `bdwgc/NOTICE`, `libuv/LICENSE` and `LICENSE-extra`,
`yyjson/LICENSE`, `picohttpparser/LICENSE` (the notice from
`picohttpparser.h`), `openssl/LICENSE.txt`, `libffi/LICENSE`, `zlib/LICENSE`,
`unicode/LICENSE.txt` (also in this repository). All of these libraries are built into the program, so no archive
carries a library file of its own.

# Agentica

Agentica is a small language with Ruby-like syntax and static types. Programs are checked before they run, and values are immutable. A Racket front end checks and compiles each program to bytecode, and a VM written in C runs it.

- [Language reference](docs/grammar.md)
- [Documentation site](https://sonic182.github.io/agentica/): the guide, the tour and the library. [Getting started](https://sonic182.github.io/agentica/getting-started/) covers the command-line options, exit codes and error messages.
- [Examples](examples/README.md)
- [Roadmap](docs/roadmap/README.md)
- [License](LICENSE)

## Requirements

- Racket CS 9.3 or newer
- A C11 compiler (gcc or clang) and `make`
- On Linux, OpenSSL 3 with its headers and `pkg-config` (Debian and Ubuntu: `libssl-dev pkg-config`). Or set `AGENTICA_OPENSSL=vendored` to build OpenSSL from its submodule, which needs Perl 5 and takes a few minutes.

The release archive for Linux x86-64 needs none of this. See the [install guide](https://sonic182.github.io/agentica/getting-started/).

## Build

```sh
git submodule update --init
make exe
```

This writes `dist/agentica` and the VM next to it, `dist/agentica-vm`. Pass `AGENTICA_OPENSSL=vendored` to every make command, or export it.

To run from the source tree instead, run `make vm` and then `raco make src/main.rkt`. Then `racket src/main.rkt file.agc` runs a program. Run `raco make` again after you change the code.

## Hello world

```sh
dist/agentica examples/hello.agc
# hello
```

## Test

```sh
make test                                # all Racket tests, after building the VM
make test TESTS="tests/lexer-test.rkt"   # some files
make vm-test                             # the C tests
```

## License

Apache-2.0 WITH LLVM-exception. See [LICENSE](LICENSE), [NOTICE](NOTICE) and [licenses/README.md](licenses/README.md) for the conditions and the third-party components.

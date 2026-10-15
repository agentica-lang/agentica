# Agentica

Agentica is a small, statically typed language with Ruby-like syntax, checked before it runs. A Racket front end compiles each program to bytecode, and a C VM runs it.

Docs: [language reference](docs/grammar.md) · [agent reference](.agents/skills/agentica-programming/SKILL.md) · [VM design](docs/vm/) · [roadmap](docs/roadmap/) · [planned syntax](docs/future/) · [site](https://sonic182.github.io/agentica/) · [examples](examples/README.md)

## Requirements

Linux, Racket CS 9.3 or newer, a C11 compiler, `make`, OpenSSL 3, and libgc 8.2 or newer with `pkg-config` (or `AGENTICA_GC=vendored` to build libgc from the submodule). See the [install guide](https://sonic182.github.io/agentica/getting-started/).

## Build

```sh
git submodule update --init
make exe
```

This writes `dist/agentica` and `dist/agentica-vm`, and next to them
`dist/agentica-bdd-driver.agcb`, the program that `agentica test` runs.

## Hello world

```sh
dist/agentica examples/hello.agc
# hello
```

## Test

```sh
make test                                # all Racket tests, after building the VM
make test TESTS="tests/parser-test.rkt"   # some files
make vm-test                             # the C tests
```

## License

Apache-2.0 WITH LLVM-exception. See [LICENSE](LICENSE), [NOTICE](NOTICE) and [licenses/README.md](licenses/README.md).

# Agentica

Agentica is a small, statically typed language with Ruby-like syntax, checked before it runs. A front end written in Agentica compiles each program to bytecode, and a C VM runs it. Both are one binary, `agentica`.

Docs: [language reference](docs/grammar.md) · [agent reference](.agents/skills/agentica-programming/SKILL.md) · [VM design](docs/vm/) · [roadmap](docs/roadmap/) · [planned syntax](docs/future/) · [site](https://sonic182.github.io/agentica/) · [examples](examples/README.md)

## Requirements

Linux, a C11 compiler, `make`, OpenSSL 3, and libgc 8.2 or newer with `pkg-config` (or `AGENTICA_GC=vendored` to build libgc from the submodule). See the [install guide](https://sonic182.github.io/agentica/getting-started/).

## Build

```sh
git submodule update --init
make
```

This writes `dist/agentica`, the only program: the VM with the front end and the
standard modules inside. It is built from the compiled front end checked in as
`bootstrap/stage0.agcb`, so the build needs only a C toolchain. `agentica run -- FILE.agcb`
runs a compiled program.

## Hello world

```sh
dist/agentica examples/hello.agc
# hello
```

## Test

```sh
make test                                      # all tests, after building the binary (Python unittest)
make test TESTS="tests/test_spec_checker.py"   # some files
make vm-test                                   # the C tests
```

## License

Apache-2.0 WITH LLVM-exception. See [LICENSE](LICENSE), [NOTICE](NOTICE) and [licenses/README.md](licenses/README.md).

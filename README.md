# Agentica

Agentica is a small, statically typed language with Ruby-like syntax, checked
before it runs. A front end written in Agentica compiles each program to
bytecode, and a C VM runs it. Both are one binary, `agentica`.

**[Read the documentation →](https://agentica-lang.github.io/agentica/)**

Contributor resources: [language specification](docs/grammar.md) · [agent
reference](.agents/skills/agentica-programming/SKILL.md) · [VM design](docs/vm/)
· [roadmap](docs/roadmap/) · [planned syntax](docs/future/) ·
[examples](examples/README.md)

## Install

Each release has an archive per system, with `bin/agentica` and the licenses:
`linux-x86_64` and `linux-arm64` (glibc 2.28 or newer), `macos-x86_64` and
`macos-arm64` (macOS 12 or newer), and
`windows-x86_64` (Windows 10 or newer), with one `SHA256SUMS` file. Unpack one
and put its `bin` folder on your `PATH`. The archives are not signed or
notarized; the [install
guide](https://agentica-lang.github.io/agentica/getting-started/) says what
macOS and Windows show for that.

## Requirements to build

A C11 compiler and `make`. On Linux also OpenSSL 3 and libgc 8.2 or newer with
`pkg-config` (or `AGENTICA_GC=vendored` to build libgc from the submodule).
macOS needs the Xcode command line tools; Windows needs MSYS2 UCRT64 with GCC.
See the install guide.

## Build

```sh
git submodule update --init
make
```

This writes `dist/agentica`, the only program: the VM with the front end and the
standard modules inside. The build starts from the compiled front end checked in
as `bootstrap/stage0.agcb`, so it needs only a C toolchain. To run compiled
bytecode, use `dist/agentica run -- FILE.agcb`.

## Hello world

```sh
dist/agentica examples/hello.agc
# hello
```

## Test

```sh
make test                                      # all tests, after building the binary (pytest)
make test TESTS="tests/test_spec_checker.py"   # some files
make vm-test                                   # the C tests
```

## License

Apache-2.0 WITH LLVM-exception. See [LICENSE](LICENSE), [NOTICE](NOTICE) and
[licenses/README.md](licenses/README.md).

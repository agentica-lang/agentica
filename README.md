# Agentica

Agentica is Ruby with static types: Ruby-like syntax, every program checked
before it runs, and values that never change in place. It comes with tasks that
run on every core, HTTP, TLS and WebSockets, packages and C native modules. A
front end written in Agentica compiles each program to bytecode, and a C VM runs
it. Both are one binary, `agentica`.

**[Read the documentation →](https://agentica-lang.github.io/agentica/)**

Contributor resources: [language specification](docs/grammar.md) · [agent
reference](.agents/skills/agentica-programming/SKILL.md) · [VM design](docs/vm/)
· [planned designs](docs/future/) ·
[issues](https://github.com/agentica-lang/agentica/issues) ·
[examples](examples/README.md)

## Install

Each release has an archive per system (Linux and macOS on x86-64 and arm64,
Windows on x86-64), with `bin/agentica` and the licenses. Unpack one and put
its `bin` folder on your `PATH`. The [install
guide](https://agentica-lang.github.io/agentica/getting-started/) lists the
archives, the minimum system versions and the requirements to build.

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

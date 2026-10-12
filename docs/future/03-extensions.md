## 3. Extensions without a normative grammar

| Extension | Direction | Pending decisions |
|---|---|---|
| Function generics | Reuse functions with different types | Syntax, inference, and constraints |
| Closures and methods | Blocks and methods on builtin types are specified in [section 11](11-ruby-ergonomics.md#11-ruby-style-ergonomics); standalone lambdas are planned in [section 25.5](25-ruby-typed-idioms.md#255-standalone-lambdas); user methods and mixins were decided against ([section 25.13](25-ruby-typed-idioms.md#2513-decided-against-part-c)) | Standalone lambdas (§25.5) |
| Modules | Group behavior and split programs into files | Import, visibility, cycles; re-exports are planned in [section 25.2](25-ruby-typed-idioms.md#252-re-exports); module attachment (section 7) was decided against ([section 25.13](25-ruby-typed-idioms.md#2513-decided-against-part-c)) |
| C FFI | Safe wrappers over native calls | Pointers, ownership, ABI, and calls from the interpreter |
| Async and fibers | Suspend execution on I/O; initially one thread. See [section 8](08-concurrency.md#8-concurrency-and-parallelism) | API, cancellation, and error propagation |
| Actors | Own messages and mailboxes | Syntax, isolation, shared values, and supervision |


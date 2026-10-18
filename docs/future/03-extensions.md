## 3. Extensions without a normative grammar

- **Extension:** Function generics
  - **Direction:** Reuse functions with different types
  - **Pending decisions:** Syntax, inference, and constraints

- **Extension:** Closures and methods
  - **Direction:** Blocks and methods on builtin types are specified in
    `grammar.md`; standalone lambdas are planned in [section
    25.5](25-ruby-typed-idioms.md#255-standalone-lambdas);
    user methods and mixins were decided against ([section
    25.13](25-ruby-typed-idioms.md#2513-decided-against-part-c))
  - **Pending decisions:** None open: standalone lambdas are planned (§25.5);
    methods on user types were decided against (§25.13)

- **Extension:** Modules
  - **Direction:** Group behavior and split programs into files
  - **Pending decisions:** Import, visibility, cycles; re-exports are planned in
    [section 25.2](25-ruby-typed-idioms.md#252-re-exports); module attachment
    (section 7) was decided against ([section
    25.13](25-ruby-typed-idioms.md#2513-decided-against-part-c))

- **Extension:** C FFI
  - **Direction:** Safe wrappers over native calls
  - **Pending decisions:** Pointers, ownership, ABI, and calls from the
    interpreter

- **Extension:** Async and fibers
  - **Direction:** Suspend execution on I/O; initially one thread. See [section
    27](27-iteration-and-concurrency.md#27-iteration-and-concurrent-collections)
  - **Pending decisions:** API, cancellation, and error propagation

- **Extension:** Actors
  - **Direction:** Own messages and mailboxes
  - **Pending decisions:** Syntax, isolation, shared values, and supervision


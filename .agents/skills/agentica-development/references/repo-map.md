# Repository map, file by file

One line per file of `compiler/`, `vm/`, `tests/`, `stdlib/` and `docs/`. The
short tree is in `AGENTS.md`; read this to find which file owns something.

```text
bootstrap/        # stage0.agcb: a checked-in stage2 the build starts from (make stage0 refreshes it; references/ci.md)
compiler/         # the front end in Agentica (§18.3, one stage per PR); lexer, parser, modules, linker, checker, lowering, bytecode writer and BDD driver so far; agentica.toml holds its [style] (lines at most 119 characters)
  source.agc token.agc diagnostic.agc  # Position and Span, Token and its Value, Diagnostic and Outcome[T]
  lexer.agc       # lex: String -> Outcome[List[Token]]; 
  unicode.agc unicode_table.agc  # graphic? and the char write form for LEX-UNEXPECTED-CHAR; the table is hand-edited data (from Racket's `char-graphic?`, Unicode 17.0)
  source_file.agc # read: a whole file as strict UTF-8 text in chunks, or the place of the first invalid byte; invalid_utf8 is the LEX-INVALID-UTF8 diagnostic
  lex.agc lex_text.agc  # entry: prints the text form of the tokens of each file argument
  text.agc        # quote, span_text, diagnostic_line: the shared pieces of both text forms
  ast.agc         # the AST structs and enums, with a node id on every node
  parse_base.agc parser.agc  # parse: List[Token] -> Result[Program](parse_base: Env, packed diagnostics, types, patterns; parser: expressions, statements, declarations)
  parse.agc parse_text.agc  # entry: prints the text form of the tree of each file argument
  modules.agc     # load: root path -> every module, read in a fixed order (explicit stack), with CHECK-IMPORT-*, CHECK-DECL-ORDER, CHECK-REDEFINED-NAME
  resolve_import.agc import_path.agc  # std/, pkg/ and relative import resolution, and the import path rules
  resolve.agc rewrite.agc  # resolve: the linked name of a name; rewrite: the declarations of a file with linked names
  linker.agc      # link_file: Linking.Done(Linked) | Failed(Failure); program(): the flat Program for the checker
  declarations.agc suggest.agc link_env.agc link_failure.agc  # declaration helpers and CHECK-DECL-ORDER; did_you_mean; Env and Settings; Site and packed failures with a file
  types.agc builtin_model.agc builtins.agc builtins_data.agc  # the Type enum; builtin data structs and the Rule enum; Catalog (lookups by name); the rows, edited by hand
  catalog.agc catalog_text.agc  # entry: prints the text form of the catalog, then the answer to each probe argument
  link.agc link_text.agc  # entry: prints the text form of the linked program of each root file argument (flags: --stdlib=, --agentica-path=, --xdg-data-home=, --home=, --ids)
  check_state.agc check_types.agc check_failure.agc  # the checker: Cx and St, type operations and unification, packed Problems with their notes
  check_register.agc check_stmt.agc check_expr.agc  # declarations and main; functions, blocks, statements, case; expressions and operators (CHECK-TOO-DEEP)
  check_call.agc check_method.agc  # calls, enum constructors, struct construction and update; methods and fields (Resolved by node id)
  check_rules.agc check_list.agc check_collections.agc check_args.agc  # the rule of each builtin
  defaults.agc check_defaults.agc  # default parameter values: the Shape of a function and how a call fills it (shared by the checker and the lowering); CHECK-DEFAULT-ORDER, CHECK-DEFAULT-VALUE and the type of a default
  check_const.agc const_walk.agc  # module constants: order, CHECK-CONSTANT-CYCLE, the value and type rules; the children and reads of an initializer
  check_help.agc check_names.agc check_flow.agc check_unused.agc  # help texts, method names, what a body returns, CHECK-UNUSED-VALUE
  check_tables.agc  # method tables and foreign-name helps as data, edited by hand
  prelude.agc prelude_data.agc check_prelude.agc  # the compiler prelude (stages.md): read, parse and check the stdlib/prelude/ functions a program calls; the table of prelude rows, by hand; the checker rule of a call of one
  checker.agc     # check(linked, settings): Checking.Done(Checked: types by node id, resolved, the prelude files and their bodies) | Failed(Problem)
  check.agc check_text.agc  # entry: prints the text form of checking each root file argument
  ir.agc lower_tables.agc lower_state.agc  # lowering: the IR as data, the lowering tables, Cx and Fx (the function being lowered)
  lower_expr.agc lower_data.agc lower_stmt.agc  # expressions and calls; list, map, enum, struct and update chunks; functions, blocks, statements
  lower_scan.agc lower_const.agc lower_program.agc  # what a function uses; module constants (plan, inlined literals, <start>); struct and enum tables
  lowering.agc    # lower(linked, checked, catalog): Lowered.Done(Ir.Program) | Failed(Problem), function table
  lower.agc lower_text.agc  # entry: prints the text form of lowering each root file argument (flags as check.agc, and --burn=N)
  bytecode_tables.agc bytecode_bytes.agc bytecode_pool.agc  # bytecode writer: format constants and opcode numbers, little-endian integers, UTF-8 and chunk lists, interned tables
  bytecode_spans.agc bytecode_types.agc bytecode_function.agc bytecode_failure.agc  # the span table, the Types and Decodable sections, one function (constants, updates, builtins, labels), BYTECODE- problems
  bytecode_writer.agc  # write(root_dir, program, version): Written.Done(bytes) | Failed(Problem), the sections in file order; the version is an input, never a constant
  bdd_driver.agc  # the BDD driver (§18.3, port step 7), part of the front end: run(options, settings) -> Ending, the tests compiled into the run directory; the runner and default steps come from the binary (`compiler/embedded/`)
  bdd_options.agc bdd_report.agc bdd_files.agc bdd_source_root.agc  # the arguments (driver options, then the user's words); the usage and infrastructure reports; private 0600 writes in pieces; the VM's --source-root of a file
  bdd_discover.agc bdd_compile.agc bdd_rundir.agc bdd_runner.agc  # the walk over the test paths; file -> Compiled.Bytes | Rejected(Problem); the temporary directory, lock and sweep; the runner as a captured child and its report file
  embedded/runner.agc embedded/steps.agc  # not stage inputs: the roots of the BDD runner and the default step program, compiled by `make` with stage2 and embedded in the binary
  diagnostic_json.agc  # the --json object of a Problem
  diagnostic_plain.agc diagnostic_ai.agc save_file.agc  # the plain text of a Problem and its --ai text; a file written in pieces (compile -o)
  pipeline.agc  # read_root, check_file, build, compile: link, check, lower and write, shared by the CLI and the BDD driver
  cli.agc  # the command line (§18.3, port step 8a): run(settings, words, hand_off) -> exit status; test calls the BDD driver in process, which starts `settings.self_path run ...`; a later `run` word is a usage error
  cli_options.agc cli_help.agc cli_text.agc cli_reply.agc cli_launch.agc  # the options; help; the fixed texts; what a command answers; Launch
  bytecode.agc    # entry: `ROOT -o OUT` for each file; writes the .agcb and prints `wrote N bytes` or the ERROR line (flags as lower.agc, and `--version=V` for the header)
  front_end.agc front_end_inputs.agc front_end_cli.agc  # the front end of the single binary (§18.2, 8b): `--version V [--stdlib DIR] [--self PATH] -- WORDS`, then front_end_cli.agc runs cli.agc over FrontEnd.hand_off; make's stages build it
vm/               # the C11 bytecode VM, linked into dist/agentica; layers in references/vm.md
  value.h         # values and the agc_ value API, shared by all layers (references/vm-core.md)
  port.h          # what services call into the core: park, wake, jobs, handles (references/vm-core.md)
  core.h          # the core types and entry points (references/vm-core.md)
  services.h      # the service exports (references/vm-core.md)
  list_impl.h     # private list layout: list.c, interp.c and vm/tests/list_test.c only (references/vm-core.md)
  value.c         # values and memory; the only file that includes gc.h or calls GC_* (references/vm-core.md, references/vm-c.md)
  text.c          # text forms of values and debug text (references/vm-core.md)
  map.c           # persistent HAMT maps (references/vm-core.md)
  list.c          # opaque persistent lists (references/vm-core.md)
  loader.c        # .agcb loader validation (references/vm-core.md)
  interp.c        # the interpreter: one turn of a task, budgets (references/vm-core.md)
  builtins.c      # core builtins (references/vm-core.md)
  builtin_tables.c # the list of every builtin table (references/vm-core.md)
  strings.c       # String builtins (references/vm-core.md)
  numbers.c       # Int and Float builtins, bit builtins, Time (references/vm-core.md)
  random.c        # the xoshiro256** generator (references/vm-core.md)
  json.c          # the JSON parser and builtins (references/vm-core.md)
  json_value.c    # the Json value: nodes, encoder, builders (references/vm-core.md)
  json_typed.c    # typed decode and schema (references/vm-core.md)
  equal.c         # agc_equal, the deep compare Test.eq uses (references/vm-core.md)
  diag.c          # plain, --ai and --json diagnostics; the stack trace of a runtime error (references/vm-core.md)
  unicode_data.c  # frozen write-escape ranges and case maps, checked-in data (references/vm-core.md)
  trace.c         # trace points and categories (AGC_TRACE) (references/vm-builtins.md)
  trace.h         # the trace categories (references/vm-builtins.md)
  launch.c launch.h  # shared by both runs of agentica.c: the option parser, seeds, a runtime from a program, SIGPIPE, the end of the run and the exit code (references/vm-io.md)
  agentica.c      # the binary's main: `run` (the VM with its flags), else the front end in a first runtime, retired at the hand-off, then the program in a second (references/vm-core.md)
  embedded.h      # the symbols of the generated embedded.s: the front end, the BDD runner and step program, and the std/ sources (references/vm-build.md)
  loop.c          # libuv event loop and resource registry (references/vm-io.md)
  files.c         # File, Dir and Path builtins (Linux) (references/vm-io.md)
  tree.c          # agc_tree_refused and agc_remove_tree for Path.remove: a tree walk that never follows a link (references/vm-io.md)
  input.c         # the only stdin reader (references/vm-io.md)
  output.c        # stdout and stderr writers (references/vm-io.md)
  stdio_posix.c   # the Linux and macOS side of output.c: how a descriptor is written, one target, notice memory stream (references/vm-io.md)
  stdio_windows.c # the Windows side: pool thread for files and consoles, libuv pipe, CompareObjectHandles (references/vm-io.md)
  duplex.c        # child channel framing, limits and locks, over one or two libuv streams (references/vm-net.md)
  duplex_os.h     # the channel ends that differ by system: the pair, the marker, how a child takes them
  duplex_posix.c  # the POSIX side: one socket pair on fd 3, marker "3"
  duplex_windows.c # the Windows side: a pipe per direction on fd 3 and 4, marker "3,4"
  process.c       # Process builtins, System.env and System.pid (references/vm-net.md)
  process_os.h    # command search rules that differ by system (references/vm-io.md)
  process_posix.c # the POSIX side of process_os.h: every file may run, PATH splits at ':'
  process_windows.c # the Windows side: .exe and .com only, ';' and quoted PATH entries, refused names
  stream.c        # input buffer and write path shared by processes and TCP (references/vm-net.md)
  tcp.c           # TCP and TLS builtins on libuv handles (references/vm-net.md)
  net.h           # tcp.c connection object for other C modules (references/vm-net.md)
  tls.h           # TLS adapter types (references/vm-net.md)
  tls_openssl.c   # the only file that includes OpenSSL (references/vm-net.md)
  http_parse.h    # HTTP head adapter (references/vm-net.md)
  http_pico.c     # the only file that includes picohttpparser (references/vm-net.md)
  http_body.c     # HTTP body decoder (references/vm-net.md)
  http_fields.h   # header lists and byte buffers for HTTP (references/vm-net.md)
  http_fields.c   # their implementation (references/vm-net.md)
  http_client.c   # HttpWire client builtins (references/vm-net.md)
  http_server.c   # HttpWire server builtins (references/vm-net.md)
  logger.c        # LogRegistry builtins over vm->rt->log, the std/logger registry (references/library-notes.md)
  front_end.c     # FrontEnd.hand_off and FrontEnd.std_source, guarded by rt->front_end (references/vm-builtins.md)
  task.c          # scheduler, task cancellation, Task builtins (references/vm-tasks.md)
  runq.c          # the locked global run queue (references/vm-tasks.md)
  inbox.c         # the I/O thread's inbox: a locked queue and a uv_async_t (references/vm-tasks.md)
  task_map.c      # Task.map: a stepper on the caller that starts, times and cancels the items (references/vm-tasks.md)
  channel.c       # Channel builtins (references/vm-tasks.md)
  testing.c       # Test builtins for unit tests (references/vm-tasks.md)
  fuzz.c          # agc_fuzz_one (references/vm-build.md)
  fuzz_main.c     # the mutation driver (references/vm-build.md)
  tools/          # check-layers.sh and its self-test, gen-embedded.sh (references/vm-build.md)
  third_party/bdwgc        # Boehm GC submodule pinned to v8.2.12, built from extra/gc.c with AGENTICA_GC=vendored (the Linux default links the system libgc)
  third_party/yyjson       # yyjson submodule pinned to 0.13.0, only its reader (JSON.parse)
  third_party/libuv        # libuv submodule pinned to v1.53.0, built by the Makefile on Linux
  third_party/picohttpparser # picohttpparser submodule pinned to v1.4 (HTTP heads)
  third_party/openssl      # OpenSSL submodule pinned to openssl-3.5.9; AGENTICA_OPENSSL=vendored builds it static per mode into build/vm/<mode>/openssl (needs Perl); the default links the system OpenSSL 3
  tests/          # C tests, plain asserts (references/vm-tests.md)
    budget_test.c        # budgets and turn costs
    channel_test.c       # Channel builtins called directly
    each_line_test.c     # File.each_line steps that bytecode cannot reach
    float_text_test.c    # Float text forms
    gc_thread_test.c     # threads registered with Boehm
    http_parse_test.c    # HTTP head parser
    json_test.c          # JSON parser and builtins
    list_test.c          # opaque lists at the 32-way boundaries
    loader_test.c        # loader rules, one assert per rule
    loop_test.c          # loop and resource registry
    map_test.c           # persistent maps
    output_test.c        # stdout and stderr writers
    process_test.c       # Process builtins
    random_test.c        # the generator
    runq_test.c          # the global run queue
    inbox_test.c         # the inbox: many producers, no lost wake, close
    outcome_test.c       # job outcome (set once) and reference count, on threads
    job_test.c           # a job on the loop: timer against completion, cancel, request from a thread
    task_wake_test.c     # wake against the park path, on threads
    stack_test.c         # stack traces
    string_test.c        # String builtins
    task_cancel_test.c   # task cancellation
    text_test.c          # text forms
    tls_test.c           # TLS adapter
    trace_test.c         # trace points
tests/            # pytest modules (test_<area>.py; existing unittest.TestCase modules remain supported); the lists of references/vm-tests.md say which covers what
  test_spec_<area>.py  # pytest language rules through the CLI (code and span from --json, never message text); shared helpers live in spec_support.py. Covers lexer, parser, module linker, checker, bytecode writer and diagnostic text.
  test_cli_forms.py  # pytest: CLI goldens; `make goldens` rewrites fixtures/cli/forms.json (references/ci.md)
  test_modules.py  # pytest: programs of several files, pkg roots, JSON and step handlers through the CLI (references/language-notes.md)
  test_examples.py  # pytest: examples/*.agc, rejected fragments, CLI exit codes; slow: malformed algorithm inputs (references/stages.md)
  test_frontend_<lexer|parser|modules|check|lower|catalog|bytecode>.py  # pytest: Agentica stages against frozen outputs and goldens; frontend_support.py and frontend_cases.py hold helpers; test_frontend_refreeze.py covers tools/refreeze.py (references/frontend.md)
  test_process.py  # pytest: Process builtins on the VM, every way a run ends (references/vm-net.md)
  test_process_bdd.py  # pytest: Process in agentica test; apart from test_process.py until it runs on Windows
  test_process_windows.py  # pytest, native Windows only: the exit pair libuv reports for a stopped child (references/ci.md)
  test_process_lifecycle.py  # pytest: a child is gone when its owner ends, the run is stopped or the driver of its VM is killed, on every system (references/vm-tests.md)
  test_std_toml.py  # unittest: std/toml against toml-test and tomllib, encoder, limits (references/library-notes.md)
  test_filesystem.py  # pytest: File and Path programs on the VM (references/vm-io.md)
  vm_diff_support.py  # the golden harness: fixtures, sidecars, sweeps, `make goldens` (references/vm-build.md)
  test_vm_diff_{1..8}.py  # unittest: shards of the golden tests; shard 8 is the VM command line, the product CLI and the process, signal and path cases (references/vm-build.md)
  test_vm_latency.py  # unittest: the latency check, run alone by make vm-latency (references/vm-tasks.md)
  test_vm_task_map.py  # unittest: the timing cases of Task.map, run alone by make vm-task-map (references/vm-tasks.md)
  test_style_line_width.py  # unittest: [style] max_line_width of compiler/agentica.toml and stdlib/agentica.toml (references/frontend.md)
  test_vm_style.py  # unittest: types at the top, no static prototypes, header size (references/vm-c.md)
  test_vm_trace.py  # unittest: traced runs keep exit code, stdout and stderr (references/vm-builtins.md)
  test_vm_tcp.py  # unittest: the VM TCP builtins against Node peers (references/vm-tests.md)
  test_vm_http.py  # unittest: std/http against independent peers (references/vm-tests.md)
  test_vm_logger.py  # unittest: std/logger: the default line, the async example, the Python peer (references/library-notes.md)
  test_vm_stop.py  # unittest: the exit path under stop signals (references/vm-tests.md)
  test_vm_channel.py  # unittest: a socket handed to a worker over a Channel (references/vm-tests.md)
  test_vm_stdout.py  # unittest: stdout and stderr on the loop (references/vm-tests.md)
  test_vm_stack.py  # unittest: stack-trace stderr in the three formats (references/vm-tests.md)
  test_vm_file_lines.py  # pytest: File.each_line on the VM (references/vm-tests.md)
  test_vm_os.py   # unittest: the OS builtins of the BDD driver port, with real contention between VMs (references/vm-tests.md)
  test_single_binary.py  # unittest: dist/agentica: the exit status and problems of a source file, `agentica run`, the guarded FrontEnd builtins, the options of the hand-off, --front-end with fixtures/single-binary/front.agc (references/vm-tests.md); the fixed point is a CI step, not a test
  test_stdlib_modules.py  # unittest: stdlib/MODULES names each stdlib/ source once (no binary needed)
  test_stdlib_prelude.py  # pytest: the prelude table, stdlib/prelude/ files and Python peer agree; no O(n) builtin in a loop
  test_vm_test_protocol.py  # unittest: a Python peer plays a test runner over the child channel (references/vm-tests.md)
  test_vm_child_channel.py  # pytest: the child channel on its own, against a Node peer, on every system (references/vm-tests.md)
  test_vm_child_channel_posix.py  # pytest: pinned descriptors and a shell child, Linux only (references/vm-tests.md)
  test_vm_tls.py  # unittest: the VM TLS builtins against independent peers (references/vm-tests.md)
  test_vm_monotonic.py  # unittest: Time.monotonic_ns against Python's clock
  test_vm_bits.py  # unittest: spans of the Int and Float bit builtin errors (references/library-notes.md)
  agentica_test.py  # unittest helpers: paths, VM and CLI, run with timeout, temp dirs, @slow (references/ci.md)
  test_std_binary.py  # unittest: std/binary on the VM (references/library-notes.md)
  test_site_examples.py  # pytest: agentica blocks in site/content run or check through the CLI; fast: four pages, slow: all (references/site.md)
  test_stdlib_distribution.py  # unittest: a copy of the binary alone still finds std/ and runs `agentica test` (references/ci.md)
  test_platform_bootstrap.py  # pytest: native bootstrap contracts, without shells or repository runtime files (references/ci.md)
  test_windows_metadata_and_locks.py  # pytest: Windows metadata values and file locks, on the native Windows runner (references/ci.md)
  test_windows_filesystem_safety.py  # pytest: Windows filesystem mutation regressions, in Docker or Actions scratch (references/ci.md)
  test_windows_console_stop.py  # pytest, native Windows only: Ctrl+Break exit 149 and a pseudo console as stdout (references/ci.md)
  test_stdlib_docs.py  # unittest: every stdlib module has a module doc and export docs, read from the source text (references/stages.md)
  test_bdd.py  # pytest: agentica test over the CLI: step programs, isolation (references/bdd.md)
  test_bdd_cleanup.py  # pytest: destructive cleanup in the Docker/Actions scratch (references/bdd.md)
  test_bdd_integration.py  # pytest: programs under test, limits, seed, cleanup; slow: large outputs and killed driver (references/bdd.md)
  test_unit_test.py  # unittest: agentica test on *_test.agc files; slow: the test timeout, stderr flood, endless print, flooding listing (references/bdd.md)
  std/            # *_test.agc unit tests of the std/ modules
  fixtures/       # golden fixtures and independent Node.js and Python peers; toml/ (std/toml inputs, driver.agc, misc.agc), toml-test/ (vendored, MIT)
  bdd/            # feature specs and step handlers run by make test-bdd (references/bdd.md)
  eval/           # agent evaluation runner, not part of make test (references/bench-eval.md)
stdlib/                 # std/ modules written in Agentica, embedded in the single binary; MODULES lists them (an explicit registry keyed "std/<path>.agc")
  prelude/list.agc prelude/map.agc  # the compiler prelude: the bodies of List and Map methods (find, group_by ...); not modules, no program imports them (references/stages.md)
  queue.agc http.agc binary.agc logger.agc toml.agc    # std/queue, std/http, std/binary, std/logger, std/toml
  bdd.agc         # std/bdd: the step API of agentica test (BDD.step, BDD.run, the context, the predefined steps)
  bdd/gherkin.agc bdd/match.agc  # internal to agentica test: Gherkin parsing and step matching; see references/bdd.md
  test/report.agc test/runner.agc test/units.agc test/child.agc  # internal to agentica test: the report, the runner, the test-file runner and the child-channel record helpers, shared by unit tests and BDD
examples/               # small programs per feature; examples/README.md lists them
tools/
  refreeze.py     # rewrites the frozen front-end goldens from the Agentica stages (references/frontend.md)
  jscpd/          # the pinned copy-paste checker (make dup-check)
docs/
  grammar.md   # index of the language grammar
  grammar/     # the language definition, one file per section; the source of truth
  future/      # planned syntax, not implemented (one file per section)
  roadmap/     # phases and the active checklist (README.md: current order and rules)
  vm/          # bytecode VM design (phase 7): IR, bytecode, C values, safety rules, PR plan
```

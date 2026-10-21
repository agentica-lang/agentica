# Repository map

Which folder or file owns something. The short tree is in `AGENTS.md`; `ls` and
`rg` give the full file lists, so this map names a file only when it carries a
contract or a placement rule.

```text
Makefile, mk/     # the build: the root has the defaults, the shared variables and `help`; mk/vm.mk the C VM and its modes, bootstrap.mk the stages and dist/agentica, test.mk the Python tests, vm-test.mk the C tests and VM checks, windows.mk, release.mk, site.mk; the include order in the Makefile matters
bootstrap/        # stage0.agcb: a checked-in stage2 the build starts from (make stage0 refreshes it; references/ci.md)
compiler/         # the front end in Agentica (§18.3): one folder per context, a new file goes in the folder of its context; agentica.toml holds its [style] (lines at most 119 characters); imports across folders are relative (`../syntax/types`)
  front_end.agc  # the entry point of the front end of the single binary (the Makefile builds this file; make's stages build it)
  app/  # the command line, the pipeline and the replies
    pipeline.agc  # build, compile: lower and write after analysis/front.agc has linked and checked; shared by the CLI and the BDD driver
    cli.agc  # run(settings, words, hand_off) -> exit status; test calls the BDD driver in process, which starts `settings.self_path run ...`; a later `run` word is a usage error
    cli_options.agc cli_help.agc cli_doc.agc cli_query.agc cli_text.agc cli_reply.agc cli_launch.agc  # the options; help; doc (prints docs/'s model); the query commands (outline: prints query/'s model); the fixed texts; what a command answers (Reply, Answer); Launch
    front_end_inputs.agc front_end_cli.agc  # the front end of the single binary (§18.2): `--version V [--stdlib DIR] [--self PATH] -- WORDS`, then front_end_cli.agc runs cli.agc over FrontEnd.hand_off
  analysis/  # the semantic queries, once (§39, `std/analysis`): the CLI and the library both call it, so they cannot drift
    front.agc  # read_root, check_file, query_file, stage_problem, link_problem: read, link and check, shared by the CLI, the BDD driver and the queries
    analysis.agc  # check, checked, outline, type_at, refs, symbol over Env.Settings (the Workspace holds any unsaved buffers): data of model.agc or the first Problem
    model.agc convert.agc  # the plain answers (Outline, TypeAt, Checked; no enum) and the conversion from the stages' own types
    session.agc  # the immutable Session of stdlib/analysis.agc: the settings and the buffers; no cache yet
  io/  # the adapter to the machine: the only code that reads files and the environment for the stages (app/ and bdd/ do their own I/O)
    host.agc  # workspace_with(std_source): the real Workspace over the std/ reader it is given; workspace(): for `--stdlib` runs; process_env(): the Env of this process
    stdin_buffer.agc  # take(): the standard input as a buffer; over(): a Workspace with it as one file (modules/overlay.agc)
    source_reader.agc  # read, read_shown: a whole file as strict UTF-8 text in chunks (the rules are in syntax/source_file.agc)
  syntax/  # source text, tokens, lexer, parser, AST
    source_file.agc  # Read (Text | Invalid | Unreadable) and the UTF-8 rules; invalid_utf8 is the LEX-INVALID-UTF8 diagnostic
    unicode.agc unicode_table.agc  # graphic? and the char write form for LEX-UNEXPECTED-CHAR; the table is hand-edited data (Unicode 17.0)
    text.agc        # quote, span_text, diagnostic_line: the shared pieces of both text forms
    suggest.agc     # did_you_mean and closest_among, for unknown names (the linker, the checker, the catalog and the help call them)
    prelude_name.agc  # PRELUDE_PREFIX and prelude_name: the names of the prelude files and functions (the linker, the checker and lowering use them)
    types.agc       # the Type enum and its helpers (the AST, the checker, the catalog, lowering and the writer import it)
    parse_base.agc parser.agc  # parse_base: Env, packed diagnostics, types, patterns; parser: expressions, statements, declarations
    lex.agc lex_text.agc parse.agc parse_text.agc  # entries: print the text form of the tokens and the tree of each file argument
  modules/  # file reading, import resolution, the linker
    workspace.agc   # Workspace: the port of the stages to the machine, a record of function values (built in io/host.agc)
    modules.agc     # load: root path -> every module, read in a fixed order (explicit stack), with CHECK-IMPORT-*, CHECK-DECL-ORDER, CHECK-REDEFINED-NAME
    resolve_import.agc import_path.agc  # std/, pkg/ and relative import resolution, and the import path rules; std/internal/ is for std modules only; `--stdlib DIR` reads std/internal/compiler/X from DIR/../compiler/X
    overlay.agc     # buffers (text in memory for files) over a Workspace: `check --stdin` is one, std/analysis any number
    resolve.agc rewrite.agc  # resolve: the linked name of a name; rewrite: the declarations of a file with linked names
    linker.agc      # link_file: Linking.Done(Linked) | Failed(Failure); program(): the flat Program for the checker
    link_env.agc    # Env and Settings (with the Workspace)
    link.agc link_text.agc  # entry: prints the text form of the linked program of each root file argument (flags: --stdlib=, --agentica-path=, --xdg-data-home=, --xdg-cache-home=, --home=, --local-app-data=, --ids)
  packages/  # §45: the manifest, the lock and the package cache (core: no I/O, only the Workspace)
    project.agc manifest.agc lock.agc  # the nearest agentica.toml and its lock checks (PKG-LOCK-*); the manifest and the lock as data with PKG-*-INVALID at a key path
    package_import.agc package_cache.agc package_hash.agc  # which pkg/<name>/ imports are packages, the hash check, the stored name; the cache folder of a commit; the hash of the .agc files (Crypto.sha256)
  check/  # the checker, constants and defaults
    check_state.agc check_types.agc  # Cx and St, type operations and unification
    check_call.agc check_method.agc  # calls, enum constructors, struct construction and update; methods and fields (Resolved by node id)
    check_rules.agc check_list.agc check_collections.agc check_args.agc  # the rule of each builtin
    defaults.agc check_defaults.agc  # default parameter values: the Shape of a function and how a call fills it (shared by the checker and the lowering)
    check_const.agc const_walk.agc  # module constants: order, CHECK-CONSTANT-CYCLE, the value and type rules; the children and reads of an initializer
    check_tables.agc  # method tables and foreign-name helps as data, edited by hand
    check_prelude.agc prelude_files.agc  # the checker rule of a call of a prelude function; Prelude.attach: read, parse and check the stdlib/prelude/ functions a program calls (stages.md)
    checker.agc     # check(linked, settings): Checking.Done(Checked: types by node id, resolved, the prelude files and their bodies) | Failed(Problem)
  catalog/  # the builtin catalog (imports only syntax/)
    builtin_model.agc builtins.agc builtins_data.agc  # builtin data structs and the Rule enum; Catalog (lookups by name); the rows, edited by hand
    catalog_json.agc  # the JSON of a builtin and of the catalog: `agentica help --json` and the `help` of `type-at` print it
    prelude_data.agc  # the table of prelude rows (stages.md), by hand
  lower/  # the IR and lowering
    ir.agc lower_tables.agc lower_state.agc  # the IR as data, the lowering tables (VM_BUILTINS), Cx and Fx (the function being lowered)
    lowering.agc    # lower(linked, checked, catalog): Lowered.Done(Ir.Program) | Failed(Problem), function table
  bytecode/  # the bytecode writer
    bytecode_tables.agc  # format constants and opcode numbers
    bytecode_writer.agc  # write(program, version): Written.Done(bytes) | Failed(Problem), the sections in file order; the version is an input, never a constant
    bytecode.agc    # entry: `ROOT -o OUT` for each file; writes the .agcb and prints `wrote N bytes` or the ERROR line (flags as lower.agc, and `--version=V` for the header)
  diagnostics/  # the diagnostic record and its plain, JSON and AI text
    diagnostic.agc  # Diagnostic and Outcome[T]
    problem.agc  # the packed Problem with its notes (pack, unpack), which every stage returns as its error
    diagnostic_model.agc diagnostic_json.agc diagnostic_read.agc  # the diagnostic as plain data; its JSON (--json); and back from JSON (Analysis.diagnostic)
  docs/  # `agentica doc` (§32.5): lex and parse one module, then its exported API with the `##` docs (imports only syntax/ and diagnostics/)
  query/  # the query commands (§39): `agentica outline` parses one file and lists its declarations, private ones too; `agentica type-at` checks it and answers for a position; `agentica symbol` links the files under its paths and finds a name; `agentica refs` links them (or FILE and its paths), checks them and lists the uses of a name or of the name at a position (imports docs/, modules/, check/, catalog/ and syntax/)
  bdd/  # the `agentica test` driver
    bdd_driver.agc  # run(options, settings) -> Ending, the tests compiled into the run directory; the runner and default steps come from the binary (`compiler/embedded/`)
  embedded/runner.agc embedded/steps.agc  # not stage inputs: the roots of the BDD runner and the default step program, compiled by `make` with stage2 and embedded in the binary
vm/               # the C11 bytecode VM, linked into dist/agentica; layers in references/vm.md
  # the file-by-file list is the "Files" section of references/vm-core.md and the vm-io, vm-net, vm-tasks and vm-builtins references (the "Read next" table of vm.md)
  value.h port.h core.h services.h  # the layer headers (references/vm.md "Which layer")
  list_impl.h     # private list layout: list.c, interp.c and vm/tests/list_test.c only
  value.c         # values and memory; the only file that includes gc.h or calls GC_*
  *_os.h *_posix.c *_windows.c  # a system difference sits behind an `_os.h` header with one file per system (duplex, process, system, net; stdio, tls_trust)
  agentica.c      # the binary's main: `run` (the VM with its flags), else the front end in a first runtime, retired at the hand-off, then the program in a second
  embedded.h      # the symbols of the generated embedded.s: the front end, the BDD runner and step program, and the std/ sources (references/vm-build.md)
  tools/          # check-layers.sh and its self-test, gen-embedded.sh (references/vm-build.md)
  third_party/    # submodules bdwgc, yyjson (only its reader), libuv, picohttpparser, openssl (pins: docs/vm/10-dependencies-and-platforms.md); AGENTICA_GC=vendored and AGENTICA_OPENSSL=vendored build bdwgc and OpenSSL (Perl needed), the Linux default links the system libgc and OpenSSL 3
  tests/          # C tests, plain asserts (references/vm-tests.md)
tests/            # pytest modules (test_<area>.py; existing unittest.TestCase modules remain supported); references/vm-tests.md says which covers what
  test_spec_<area>.py  # pytest language rules through the CLI (code and span from --json, never message text); shared helpers live in spec_support.py. Covers lexer, parser, module linker, checker, bytecode writer and diagnostic text.
  test_frontend_<lexer|parser|modules|check|lower|catalog|bytecode>.py  # pytest: Agentica stages against frozen outputs and goldens; frontend_support.py and frontend_cases.py hold helpers; test_frontend_refreeze.py covers tools/refreeze.py (references/frontend.md)
  test_cli_forms.py  # pytest: CLI goldens; `make goldens` rewrites fixtures/cli/forms.json (references/ci.md)
  test_vm_diff_{1..8}.py  # unittest: shards of the golden tests; shard 8 is the VM command line, the product CLI and the process, signal and path cases; vm_diff_support.py is the harness (references/vm-build.md)
  test_vm_latency.py test_vm_task_map.py  # unittest: run alone by make vm-latency and make vm-task-map
  test_style_core_purity.py  # the stage folders of compiler/ never call File, Dir, Path (but join), System, Process or FrontEnd (references/frontend.md)
  test_style_line_width.py  # [style] max_line_width of compiler/agentica.toml and stdlib/agentica.toml
  test_vm_style.py  # types at the top, no static prototypes, header size (references/vm-c.md)
  test_stdlib_modules.py  # stdlib/MODULES names each stdlib/ source once; stdlib/CORE is what std/analysis imports (no binary needed)
  test_std_analysis.py  # std/analysis against the CLI's --json on the same files (a driver program in fixtures/analysis/)
  test_stdlib_prelude.py  # the prelude table, stdlib/prelude/ files and Python peer agree; no O(n) builtin in a loop
  test_stdlib_docs.py  # every stdlib module has a module doc and export docs, read from the source text
  test_conformance.py  # every test module is in an area of tools/conformance.py or excluded with a reason; the report's rules (references/ci.md)
  test_site_examples.py  # agentica blocks in site/content run or check through the CLI; fast: four pages, slow: all (references/site.md)
  test_bdd*.py test_unit_test.py  # agentica test over the CLI (references/bdd.md)
  agentica_test.py  # unittest helpers: paths, VM and CLI, run with timeout, temp dirs, @slow (references/ci.md)
  std/            # *_test.agc unit tests of the std/ modules
  fixtures/       # golden fixtures and independent Node.js and Python peers; toml/ (std/toml inputs), toml-test/ (vendored, MIT)
  bdd/            # feature specs and step handlers run by make test-bdd (references/bdd.md)
  eval/           # agent evaluation runner, not part of make test (references/bench-eval.md)
stdlib/                 # std/ modules written in Agentica, embedded in the single binary; MODULES lists them (an explicit registry keyed "std/<path>.agc"); CORE lists the files of compiler/ that std/analysis compiles into a program, carried as std/internal/compiler/<path>
  prelude/        # the compiler prelude: the bodies of List, Map and Lazy methods; not modules, no program imports them (references/stages.md)
  bdd/ test/      # internal to agentica test: Gherkin parsing and step matching; the report, the runner, the test-file runner and the child-channel record helpers (references/bdd.md)
examples/               # small programs per feature; examples/README.md lists them
tools/                  # refreeze.py (references/frontend.md), jscpd/ (the pinned copy-paste checker, make dup-check), conformance.py, release.py, release-check.sh (references/ci.md)
docs/
  grammar.md   # index of the language grammar
  grammar/     # the language definition, one file per section; the source of truth
  future/      # planned syntax, not implemented (one file per section)
  roadmap/     # phases and the active checklist (README.md: current order and rules)
  vm/          # bytecode VM design (phase 7): IR, bytecode, C values, safety rules, PR plan
```

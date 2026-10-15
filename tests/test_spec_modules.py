"""Module rules of the language, through the CLI (ported from tests/modules-test.rkt).

Each case writes a few source files into a temporary folder and runs `--json check` on the root file. A program that
is rejected gives its diagnostic code, and the span where the rule asks for one (file, line and column). A program that
is fine exits 0 with {"ok":true}. Message and help text are not asserted (AGENTS.md): help is only checked for being
present or absent, since a suggestion that names a private declaration is a rule of its own.
"""
import json
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from tests.agentica_test import TestCase, cli, run, vm_environment

# No AGENTICA_PATH roots and no user data folder, so only the files of a case resolve.
HERMETIC = {"AGENTICA_PATH": "", "XDG_DATA_HOME": "/nonexistent-agentica-xdg"}

# Each check is a process of about a second (Racket start-up), so a test's checks run side by side.
WORKERS = 8

MAIN = "def main() -> Void\nend\n\n"


def start(problem):
    """The (line, column) where the span of a diagnostic starts."""
    position = problem["range"]["start"]
    return position["line"], position["column"]


class ModuleRules(TestCase):
    def setUp(self):
        super().setUp()
        # A folder that holds none of the programs' files: a relative path must not resolve by accident.
        self.cwd = self.make_temp_dir("agentica-cwd-")

    def files(self, files):
        """A resolved temp folder holding the given files (name -> text; names may have folders)."""
        directory = self.make_temp_dir("agentica-modules-").resolve()
        for name, text in files.items():
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return directory

    def checks(self, cases):
        """Check several programs side by side: each case is (files, root, env), and the result is a list of
        (directory, problem) in the same order, where problem is None for a program that checks clean.

        `files` is a name -> text map, or a folder that already exists. In `env`, {dir} stands for the folder.
        """
        jobs = []
        for files, root, env in cases:
            directory = files if isinstance(files, Path) else self.files(files)
            env = {key: value.replace("{dir}", str(directory)) for key, value in (env or {}).items()}
            jobs.append((directory, root, env))

        def check(job):
            directory, root, env = job
            return run(cli() + ["--json", "check", str(directory / root)], cwd=self.cwd,
                       env=vm_environment({**HERMETIC, **env}))

        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            results = list(pool.map(check, jobs))
        return [(directory, self.problem_of(result)) for (directory, _root, _env), result in zip(jobs, results)]

    def check(self, files, root="root.agc", env=None):
        """One check (see checks()): its (directory, problem)."""
        return self.checks([(files, root, env)])[0]

    def problem_of(self, result):
        if result.code == 0:
            self.assertEqual(result.stdout, '{"ok":true}\n')
            return None
        self.assertEqual(result.code, 1, result.stderr)
        problem = json.loads(result.stderr)
        # Internal names (with the module mangling '@') must not reach a user.
        self.assertNotIn("@", json.dumps(problem))
        return problem

    def assert_rejected(self, checked, code, line=None, file=None):
        """The check fails with `code`, at `line`, and in `file` (a name of the folder) when given."""
        directory, problem = checked
        self.assertIsNotNone(problem, "the program checks clean")
        self.assertEqual(problem["code"], code)
        if line is not None:
            self.assertEqual(start(problem)[0], line)
        if file is not None:
            self.assertEqual(problem["file"], str(directory / file))
        return problem

    def test_reserved_library_namespaces_reject_traversal_and_keep_the_import_span(self):
        cases = [("std/../queue", "CHECK-IMPORT-PATH"), ("std//queue", "CHECK-IMPORT-PATH"),
                 ("std/missing", "CHECK-IMPORT-IO"), ("pkg/../outside", "CHECK-IMPORT-PATH"),
                 ("pkg/agentica-test-nonexistent-stdlib-library", "CHECK-IMPORT-IO")]
        results = self.checks([({"root.agc": 'import Q from "%s"\n' % path + MAIN}, "root.agc", None)
                               for path, _code in cases])
        for (path, code), checked in zip(cases, results):
            with self.subTest(path):
                self.assert_rejected(checked, code, line=1, file="root.agc")

    def test_pkg_imports_reject_relative_environment_roots_and_escaping_symlinks(self):
        directory = self.files({
            "root.agc": 'import Value from "pkg/value"\n' + MAIN,
            "outside.agc": "export def read() -> Int\n  return 1\nend\n\n"})
        checked = self.checks([(directory, "root.agc", {"AGENTICA_PATH": "relative"})])
        self.assert_rejected(checked[0], "CHECK-IMPORT-PATH")
        # Unix symlinks need no privilege; Windows link creation may require it, so the link case is skipped there.
        if os.name != "nt":
            (directory / "agc_libs").mkdir()
            os.symlink(directory / "outside.agc", directory / "agc_libs" / "value.agc")
            self.assert_rejected(self.checks([(directory, "root.agc", None)])[0], "CHECK-IMPORT-PATH")

    def test_imported_structs_fields_and_arity_are_checked_with_their_spans(self):
        checked = self.check({
            "a.agc": "export struct Point\n  x: Int\nend\n\n",
            "root.agc": 'import A from "a"\ndef main() -> Void\n  n: Int = A.Point(x: 1)\nend\n\n'})
        self.assert_rejected(checked, "CHECK-TYPE-MISMATCH")
        files = {
            "a.agc": "export struct Point\n  x: Int\nend\n\n"
                     "export def make(x: Int) -> Point\n  return Point(x: x)\nend\n\n",
            "root.agc": 'import A from "a"\ndef main() -> Void\n  n = A.Point(x: 1).z\nend\n\n',
            "arity.agc": 'import A from "a"\ndef main() -> Void\n  p = A.make()\nend\n\n'}
        field, arity = self.checks([(files, "root.agc", None), (files, "arity.agc", None)])
        problem = self.assert_rejected(field, "CHECK-UNKNOWN-FIELD", line=3)
        self.assertEqual(start(problem), (3, 7))
        self.assert_rejected(arity, "CHECK-ARITY")

    def test_unknown_types_and_names_in_imported_files_are_reported_in_those_files(self):
        files = {
            "bad.agc": "struct Point\n  x: Int\nend\n\nstruct Pair\n  p: Pont\nend\n\n",
            "calls.agc": "export def go() -> Int\n  return helpr()\nend\n\ndef helper() -> Int\n  return 1\nend\n\n",
            "types.agc": 'import B from "bad"\n' + MAIN,
            "funcs.agc": 'import C from "calls"\n\ndef helpe() -> Int\n  return 2\nend\n\n'
                         "def main() -> Void\n  n = C.go()\nend\n\n"}
        types, funcs = self.checks([(files, "types.agc", None), (files, "funcs.agc", None)])
        problem = self.assert_rejected(types, "CHECK-UNKNOWN-TYPE")
        self.assertEqual(start(problem), (6, 6))
        self.assertEqual(problem["file"], str(types[0] / "bad.agc"))
        self.assert_rejected(funcs, "CHECK-UNKNOWN-NAME")

    def test_module_errors_are_located_and_do_not_expose_private_declarations(self):
        module = ("struct Secret\n  value: Int\nend\n\nexport struct Public\nend\n\n"
                  "def hidden() -> Void\nend\n\n")
        cases = [
            ('import Missing from "missing"\n', "", "CHECK-IMPORT-IO"),
            ('import M from "module"\n', "  M.hidden()\n", "CHECK-IMPORT-NAME"),
            ('import M from "module"\n', "  x = M.Secret(value: 1)\n", "CHECK-IMPORT-NAME"),
            ('import M from "module"\nimport M from "module"\n', "", "CHECK-REDEFINED-NAME"),
            ('import JSON from "module"\n', "", "CHECK-REDEFINED-NAME"),
            ('import Channel from "module"\n', "", "CHECK-REDEFINED-NAME"),
            ('import Set from "module"\n', "", "CHECK-REDEFINED-NAME"),
            ('import Await from "module"\n', "", "CHECK-REDEFINED-NAME"),
            ('import M from "module.txt"\n', "", "CHECK-IMPORT-PATH"),
            ("", '  x = String.nope("a")\n', "CHECK-UNKNOWN-NAME"),
            ("", "  x = Mpa.put(1)\n", "CHECK-UNKNOWN-NAME"),
            ("", "  x = IO.nope()\n", "CHECK-UNKNOWN-NAME"),
            ("", "  x: Missing.Value = 1\n", "CHECK-IMPORT-NAME"),
        ]
        results = self.checks([({"module.agc": module,
                                 "root.agc": imports + "def main() -> Void\n" + body + "end\n\n"}, "root.agc", None)
                               for imports, body, _code in cases])
        for (imports, body, code), checked in zip(cases, results):
            with self.subTest(code=code, body=body or imports):
                self.assert_rejected(checked, code, file="root.agc")

    def test_import_paths_name_modules_without_an_extension(self):
        names = ["lib/util.agc", "lib/util.rb", 'a"b.agc', "json.tools.agc", "lib/", "..", ".", ""]
        # The import is on line 4, after the two comment lines, so its span is not the start of the file.
        results = self.checks([({
            "lib/util.agc": "export def read() -> String\n  return \"util\"\nend\n\n",
            "root.agc": "# two comment lines keep the import off line 1\n# so the span is not the file start\n\n"
                        + "import Util from %s\n" % json.dumps(name) + MAIN}, "root.agc", None)
            for name in names])
        for name, checked in zip(names, results):
            with self.subTest(name):
                problem = self.assert_rejected(checked, "CHECK-IMPORT-PATH")
                self.assertEqual(start(problem), (4, 1))

    def test_nullary_variants_need_no_parentheses_locally_and_through_an_alias(self):
        results = self.checks([
            ({"root.agc": "def main() -> Void\n  c = Color.Red\nend\n\n"}, "root.agc", None),
            ({"root.agc": "def main() -> Void\n  p: Geo.Point = nil\nend\n\n"}, "root.agc", None),
            ({"root.agc": "def main() -> Void\n  r = Result.Ok\nend\n\n"}, "root.agc", None)])
        local, geo, result = results
        self.assert_rejected(local, "CHECK-IMPORT-NAME", line=2)
        self.assert_rejected(geo, "CHECK-IMPORT-NAME")
        self.assert_rejected(result, "CHECK-IMPORT-NAME")

    def test_a_struct_update_follows_the_rules_of_construction_across_files(self):
        # A value of a struct that the other module keeps private cannot be updated: the rule of constructing it.
        problem = self.check({
            "lib.agc": "struct Hidden\n  n: Int\nend\n\nexport def hidden() -> Hidden\n  return Hidden(n: 1)\nend\n\n",
            "root.agc": 'import Lib from "lib"\n\ndef main() -> Void\n'
                        "  h = Lib.hidden()\n  x = h.with(n: 2)\nend\n\n"})
        self.assertEqual(start(self.assert_rejected(problem, "CHECK-IMPORT-NAME")), (5, 7))
        # Importing a module that only passes the struct along is not enough: the importer needs its own module.
        self.assert_rejected(self.check({
            "a.agc": "export struct P\n  n: Int\nend\n\n",
            "b.agc": 'import A from "a"\n\nexport def get() -> A.P\n  return A.P(n: 1)\nend\n\n',
            "root.agc": 'import B from "b"\n\ndef main() -> Void\n'
                        "  x = B.get().with(n: 2)\nend\n\n"}), "CHECK-IMPORT-NAME")

    def test_cycles_are_reported_in_the_file_that_closes_them(self):
        checked = self.check({
            "root.agc": 'import A from "a"\n' + MAIN,
            "a.agc": 'import Root from "root"\n'})
        self.assert_rejected(checked, "CHECK-IMPORT-CYCLE", file="a.agc")

    def test_private_imported_enums_remain_inaccessible(self):
        self.assert_rejected(self.check({
            "option.agc": "enum Option[T]\n  Some(T)\nend\n\n",
            "root.agc": 'import Domain from "option"\ndef main() -> Void\n'
                        '  value: Domain.Option[Int] = Domain.Option.Some(1)\nend\n\n'}), "CHECK-IMPORT-NAME")

    def test_removed_std_http_server_calls_are_rejected_by_name(self):
        cases = [("  HTTP.respond(1, 200, [], \"hi\", 1000)\n", True),
                 ("  HTTP.finish(1, [], 1000)\n", True),
                 ("  HTTP.nothing(1)\n", False)]
        results = self.checks([({"root.agc": 'import HTTP from "std/http"\ndef main() -> Void\n' + body + "end\n\n"},
                                "root.agc", None) for body, _help in cases])
        for (body, has_help), checked in zip(cases, results):
            with self.subTest(body):
                problem = self.assert_rejected(checked, "CHECK-IMPORT-NAME", line=3)
                self.assertEqual("help" in problem, has_help)

    def test_a_wrong_imported_name_suggests_the_closest_export_never_a_private_name(self):
        module = ("struct Secret\n  value: Int\nend\n\nexport struct Public\n  a: Int\nend\n\n"
                  "export def public() -> Void\nend\n\ndef hidden() -> Void\nend\n\n")
        # A suggestion is given for a near public name; none for a near private name or a name far from all.
        cases = [("  x = M.publc()\n", True), ("  x = M.Publik(a: 1)\n", True), ("  x: M.Publc = nil\n", True),
                 ("  x = M.hiden()\n", False), ("  x = M.Secret(value: 1)\n", False), ("  x = M.faraway()\n", False)]
        results = self.checks([({"module.agc": module,
                                 "root.agc": 'import M from "module"\ndef main() -> Void\n' + body + "end\n\n"},
                                "root.agc", None) for body, _suggests in cases])
        for (body, suggests), checked in zip(cases, results):
            with self.subTest(body):
                problem = self.assert_rejected(checked, "CHECK-IMPORT-NAME", line=3)
                self.assertEqual("help" in problem, suggests)
        # `ab` and `ac` are both one edit from `ad`. The tie-break is message detail, so only the code is checked.
        self.assert_rejected(self.check({
            "module.agc": "export def ac() -> Void\nend\n\nexport def ab() -> Void\nend\n\n",
            "root.agc": 'import M from "module"\ndef main() -> Void\n  M.ad()\nend\n\n'}), "CHECK-IMPORT-NAME")

    def test_the_std_http_and_std_logger_wrong_names_are_rejected_by_name(self):
        http, logger = self.checks([
            ({"root.agc": 'import HTTP from "std/http"\ndef main() -> Void\n  x = HTTP.gett("u")\nend\n\n'},
             "root.agc", None),
            ({"root.agc": 'import Logger from "std/logger"\ndef main() -> Void\n  Logger.warnin("x")\nend\n\n'},
             "root.agc", None)])
        self.assert_rejected(http, "CHECK-IMPORT-NAME")
        self.assert_rejected(logger, "CHECK-IMPORT-NAME")

    def test_log_registry_is_internal_to_std_logger_its_types_are_reserved_and_logger_has_no_error(self):
        declarations = ["struct LogEvent\n  n: Int\nend\n\n", "enum LogLevel\n  Loud\nend\n\n",
                        "struct LogRegistry\n  n: Int\nend\n\n"]
        results = self.checks(
            [({"root.agc": "def main() -> Void\n  x = LogRegistry.level()\nend\n\n"}, "root.agc", None),
             ({"root.agc": 'import Logger from "std/logger"\ndef main() -> Void\n  Logger.error("x")\nend\n\n'},
              "root.agc", None),
             ({"root.agc": 'import Logger from "std/logger"\ndef main() -> Void\n  Logger.err("x")\n'
                           '  level: LogLevel = Logger.level()\n'
                           '  event = LogEvent(level: level, message: "m", fields: {}, time_ms: 0, task: 1)\n'
                           '  Logger.stderr_text(event)\nend\n\n'}, "root.agc", None)]
            + [({"root.agc": declaration + MAIN}, "root.agc", None) for declaration in declarations])
        registry, error, clean = results[:3]
        self.assert_rejected(registry, "CHECK-UNKNOWN-NAME")
        self.assert_rejected(error, "CHECK-IMPORT-NAME")
        self.assertIsNone(clean[1])
        for declaration, checked in zip(declarations, results[3:]):
            with self.subTest(declaration.split()[1]):
                self.assert_rejected(checked, "CHECK-REDEFINED-NAME")

    def test_http_wire_is_internal_to_std_http_for_user_files_relative_imports_and_pkg_modules(self):
        call = 'export def go() -> Void\n  HttpWire.client(1, 1, 1, 1, "")\nend\n\n'
        roots = [("root.agc", 'import Wire from "pkg/wire"\ndef main() -> Void\n'
                              '  HttpWire.close_client(HttpWire.client(1, 1, 1, 1, ""))\nend\n\n'),
                 ("lib.agc", 'import Lib from "lib"\ndef main() -> Void\n  Lib.go()\nend\n\n'),
                 ("libs/wire.agc", 'import Wire from "pkg/wire"\ndef main() -> Void\n  Wire.go()\nend\n\n')]
        bodies = [("  x = HttpWir.client(1)\n", "CHECK-UNKNOWN-NAME"),
                  ("  x = close_clien(1)\n", "CHECK-UNKNOWN-NAME"),
                  ("  x = HTTP.exchang(1)\n", "CHECK-IMPORT-NAME")]
        names = ["HttpWire", "HttpResponse", "HttpRequest", "HttpServer", "HttpServerOptions"]
        http = 'import HTTP from "std/http"\ndef main() -> Void\n'
        results = self.checks(
            [({"root.agc": text, "lib.agc": call, "libs/wire.agc": call},
              "root.agc", {"AGENTICA_PATH": "{dir}/libs"}) for _name, text in roots]
            + [({"root.agc": 'import HTTP from "std/http"\ndef main() -> Void\n'
                             '  HTTP.close_client(Result.unwrap!(HTTP.client(HTTP.client_options())))\nend\n\n'},
                "root.agc", None)]
            + [({"root.agc": http + body + "end\n\n"}, "root.agc", None) for body, _code in bodies]
            + [({"root.agc": "struct %s\n  n: Int\nend\n\n" % name + MAIN}, "root.agc", None) for name in names])
        roots_checked, clean, body_checked, names_checked = (
            results[:3], results[3], results[4:7], results[7:])
        for (name, _text), checked in zip(roots, roots_checked):
            with self.subTest(name):
                self.assert_rejected(checked, "CHECK-UNKNOWN-NAME", file=name)
        self.assertIsNone(clean[1])
        for (body, code), checked in zip(bodies, body_checked):
            with self.subTest(body):
                self.assert_rejected(checked, code)
        for name, checked in zip(names, names_checked):
            with self.subTest(name):
                self.assert_rejected(checked, "CHECK-REDEFINED-NAME")

    def test_a_type_after_a_function_is_out_of_order_at_the_type(self):
        problem = self.check({"root.agc": "def main() -> Void\nend\n\nstruct Late\n  n: Int\nend\n\n"})
        self.assertEqual(start(self.assert_rejected(problem, "CHECK-DECL-ORDER")), (4, 1))

    def test_a_private_function_before_an_exported_one_is_out_of_order_at_the_export(self):
        results = self.checks([
            ({"root.agc": "def helper() -> Void\nend\n\nexport def api() -> Void\nend\n\n"}, "root.agc", None),
            ({"root.agc": "def helper() -> Void\nend\n\nexport struct Late\nend\n\n"}, "root.agc", None)])
        for checked in results:
            self.assertEqual(start(self.assert_rejected(checked, "CHECK-DECL-ORDER")), (4, 1))

    def test_a_private_enum_after_a_function_is_out_of_order_at_the_enum(self):
        problem = self.check({"root.agc": "def main() -> Void\nend\n\nenum Late\n  A\nend\n\n"})
        self.assertEqual(start(self.assert_rejected(problem, "CHECK-DECL-ORDER")), (4, 1))

    def test_an_import_after_a_declaration_is_out_of_order(self):
        problem = self.check({
            "lib.agc": "export def go() -> Void\nend\n\n",
            "root.agc": 'struct Early\nend\n\nimport Lib from "lib"\n'})
        self.assertEqual(start(self.assert_rejected(problem, "CHECK-DECL-ORDER")), (4, 1))

    def test_types_in_any_order_then_exports_then_private_functions_check_clean(self):
        self.assertIsNone(self.check({
            "lib.agc": "export def go() -> Void\nend\n\n",
            "root.agc": '## Module doc.\n\nimport Lib from "lib"\nimport Queue from "std/queue"\n\n'
                        "export enum Kind\n  A\nend\n\nstruct Box\n  n: Int\nend\n\n"
                        "export struct Pair\n  n: Int\nend\n\nenum Hidden\n  B\nend\n\n"
                        "export def api() -> Void\n  Lib.go()\n  helper()\nend\n\n"
                        "def helper() -> Void\nend\n\n" + MAIN})[1])

    def test_an_imported_module_is_checked_too_and_the_diagnostic_names_its_file(self):
        checked = self.check({
            "lib.agc": "def helper() -> Void\nend\n\nexport def go() -> Void\nend\n\n",
            "root.agc": 'import Lib from "lib"\ndef main() -> Void\n  Lib.go()\nend\n\n'})
        problem = self.assert_rejected(checked, "CHECK-DECL-ORDER", file="lib.agc")
        self.assertEqual(start(problem), (4, 1))

    def test_embedded_std_modules_follow_the_rule_so_importing_them_never_trips_it(self):
        names = ["std/http", "std/logger", "std/binary", "std/toml", "std/queue"]
        results = self.checks([({"root.agc": 'import M from "%s"\n' % name + MAIN}, "root.agc", None)
                               for name in names])
        for name, (_directory, problem) in zip(names, results):
            with self.subTest(name):
                self.assertIsNone(problem)

"""Module rules of the language, through the CLI.

Each case writes a few source files into a temporary folder and runs `--json check` on the root file. A program that
is rejected gives its diagnostic code, and the span where the rule asks for one (file, line and column). A program that
is fine exits 0 with {"ok":true}. Message and help text are not asserted (AGENTS.md): help is only checked for being
present or absent, since a suggestion that names a private declaration is a rule of its own.
"""
import json
import os
from pathlib import Path

import pytest

from tests.agentica_test import cli, run, vm_environment
from tests.module_support import write_module_files

# No AGENTICA_PATH roots, no user data folder (XDG_DATA_HOME, or LOCALAPPDATA on Windows) and no package cache
# (XDG_CACHE_HOME), so only the files of a case resolve.
HERMETIC = {"AGENTICA_PATH": "", "XDG_DATA_HOME": "/nonexistent-agentica-xdg",
            "XDG_CACHE_HOME": "/nonexistent-agentica-xdg", "LOCALAPPDATA": "/nonexistent-agentica-xdg"}

MAIN = "def main() -> Void\nend\n\n"


def start(problem):
    """The (line, column) where the span of a diagnostic starts."""
    position = problem["range"]["start"]
    return position["line"], position["column"]


class TestModuleRules:
    @pytest.fixture(autouse=True)
    def set_up(self, tmp_path):
        self._tmp_path = tmp_path
        self._temp_dir_count = 0
        # A folder that holds none of the programs' files: a relative path must not resolve by accident.
        self.cwd = self.make_temp_dir("agentica-cwd-")

    def make_temp_dir(self, prefix="agentica-"):
        self._temp_dir_count += 1
        path = self._tmp_path / f"{prefix}{self._temp_dir_count}"
        path.mkdir()
        return path

    def files(self, files):
        return write_module_files(self, files)

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

        results = [check(job) for job in jobs]
        return [(directory, self.problem_of(result)) for (directory, _root, _env), result in zip(jobs, results)]

    def check(self, files, root="root.agc", env=None):
        """One check (see checks()): its (directory, problem)."""
        return self.checks([(files, root, env)])[0]

    def problem_of(self, result):
        if result.code == 0:
            assert result.stdout == '{"ok":true}\n'
            return None
        assert result.code == 1, result.stderr
        problem = json.loads(result.stderr)
        # Internal names (with the module mangling '@') must not reach a user in the message or the help.
        assert "@" not in json.dumps({key: problem.get(key) for key in ("message", "help")})
        return problem

    def assert_rejected(self, checked, code, line=None, file=None):
        """The check fails with `code`, at `line`, and in `file` (a name of the folder) when given."""
        directory, problem = checked
        assert problem is not None, "the program checks clean"
        assert problem["code"] == code
        if line is not None:
            assert start(problem)[0] == line
        if file is not None:
            assert Path(problem["file"]) == directory / file
        return problem

    def test_reserved_library_namespaces_reject_traversal_and_keep_the_import_span(self):
        cases = [("std/../queue", "CHECK-IMPORT-PATH"), ("std//queue", "CHECK-IMPORT-PATH"),
                 ("std/missing", "CHECK-IMPORT-IO"), ("pkg/../outside", "CHECK-IMPORT-PATH"),
                 ("pkg/agentica-test-nonexistent-stdlib-library", "CHECK-IMPORT-IO")]
        results = self.checks([({"root.agc": 'import Q from "%s"\n' % path + MAIN}, "root.agc", None)
                               for path, _code in cases])
        for (path, code), checked in zip(cases, results):
            self.assert_rejected(checked, code, line=1, file="root.agc")

    def test_std_internal_is_private_to_std_modules_and_the_span_is_the_import(self):
        """std/internal/ holds the core that std/analysis embeds: a program may import none of it, a name that exists
        or not. The span is the import line, up to the start of the next one."""
        cases = [({"root.agc": 'import Q from "%s"\n' % path + MAIN}, "root.agc", None)
                 for path in ("std/internal/compiler/syntax/ast", "std/internal/x")]
        for directory, problem in self.checks(cases):
            self.assert_rejected((directory, problem), "CHECK-IMPORT-IO", line=1, file="root.agc")
            assert problem["range"] == {"start": {"line": 1, "column": 1}, "end": {"line": 2, "column": 1}}

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
        problem = self.assert_rejected(checked, "CHECK-TYPE-MISMATCH")
        assert problem["actual"] == "Point"
        files = {
            "a.agc": "export struct Point\n  x: Int\nend\n\n"
                     "export def make(x: Int) -> Point\n  return Point(x: x)\nend\n\n",
            "root.agc": 'import A from "a"\ndef main() -> Void\n  n = A.Point(x: 1).z\nend\n\n',
            "arity.agc": 'import A from "a"\ndef main() -> Void\n  p = A.make()\nend\n\n'}
        field, arity = self.checks([(files, "root.agc", None), (files, "arity.agc", None)])
        problem = self.assert_rejected(field, "CHECK-UNKNOWN-FIELD", line=3)
        assert start(problem) == (3, 7)
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
        assert start(problem) == (6, 6)
        assert Path(problem["file"]) == types[0] / "bad.agc"
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
            ("", "  x: Missing.Value = 1\n", "CHECK-IMPORT-NAME"),
        ]
        results = self.checks([({"module.agc": module,
                                 "root.agc": imports + "def main() -> Void\n" + body + "end\n\n"}, "root.agc", None)
                               for imports, body, _code in cases])
        for (imports, body, code), checked in zip(cases, results):
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
            problem = self.assert_rejected(checked, "CHECK-IMPORT-PATH")
            assert start(problem) == (4, 1)

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
        assert start(self.assert_rejected(problem, "CHECK-IMPORT-NAME")) == (5, 7)
        # Importing a module that only passes the struct along is not enough: the importer needs its own module.
        self.assert_rejected(self.check({
            "a.agc": "export struct P\n  n: Int\nend\n\n",
            "b.agc": 'import A from "a"\n\nexport def get() -> A.P\n  return A.P(n: 1)\nend\n\n',
            "root.agc": 'import B from "b"\n\ndef main() -> Void\n'
                        "  x = B.get().with(n: 2)\nend\n\n"}), "CHECK-IMPORT-NAME")

    def test_an_exported_constant_is_read_through_the_alias_like_an_exported_function(self):
        lib = ("HIDDEN = 5\nexport LIMIT = HIDDEN + 1\nexport NAMES = [\"a\"]\nexport CONFIG = Config(port: 80)\n\n"
               "export struct Config\n  port: Int\nend\n\n")
        header = 'import Lib from "lib"\n\ndef main() -> Void\n'
        good = ("  x = Lib.LIMIT + 1\n  puts(Lib.NAMES.size)\n  puts(Lib.CONFIG.port)\n"
                "  moved: Lib.Config = Lib.CONFIG.with(port: 81)\n  puts(\"#{Lib.LIMIT}\")\n")
        cases = [good, "  puts(Lib.HIDDEN)\n", "  puts(Lib.HIDDEN.size)\n", "  puts(Lib.MISSING)\n"]
        checked = self.checks([({"lib.agc": lib, "root.agc": header + body + "end\n"}, "root.agc", None)
                               for body in cases])
        assert checked[0][1] is None
        # A private constant, and one that does not exist, are refused like a private function, at the member.
        for refused in checked[1:]:
            assert start(self.assert_rejected(refused, "CHECK-IMPORT-NAME")) == (4, 8)
        # A constant is no function and no type.
        wrong = self.checks([({"lib.agc": lib, "root.agc": header + body + "end\n"}, "root.agc", None)
                             for body in ("  puts(Lib.LIMIT())\n", "  x: Lib.LIMIT = 1\n")])
        for checked_wrong in wrong:
            self.assert_rejected(checked_wrong, "CHECK-TYPE-MISMATCH", line=4)

    def test_a_constant_through_the_alias_sits_beside_enum_variants_and_blocks(self):
        lib = "export LIMIT = 3\nexport NAMES = [\"a\"]\n\nexport enum Shade\n  Dark\n  Light(Int)\nend\n\n"
        local = "enum Level\n  HIGH\nend\n\nenum Mix\n  Low\nend\n\n"
        header = 'import Lib from "lib"\n\n' + local + "def main() -> Void\n"
        bodies = ["  a = Lib.Shade.Dark\n  b = Lib.Shade.Light(Lib.LIMIT)\n  puts(Lib.LIMIT.to_s + a.to_s + b.to_s)\n",
                  "  puts(Lib.NAMES.map do |name| name + \"!\" end)\n"
                  "  puts(Lib.NAMES.reduce(0) do |n, name| n + 1 end)\n",
                  # A method on a variant reads the same for an all-capitals variant and a CamelCase one.
                  "  puts(Level.HIGH.to_s)\n  puts(Mix.Low.to_s)\n  puts(Lib.Shade.Dark.to_s)\n"]
        checked = self.checks([({"lib.agc": lib, "root.agc": header + body + "end\n"}, "root.agc", None)
                               for body in bodies])
        assert [problem for _directory, problem in checked] == [None, None, None]

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
            problem = self.assert_rejected(checked, "CHECK-IMPORT-NAME", line=3)
            assert ("help" in problem) == has_help

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
            problem = self.assert_rejected(checked, "CHECK-IMPORT-NAME", line=3)
            assert ("help" in problem) == suggests
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
        assert clean[1] is None
        for declaration, checked in zip(declarations, results[3:]):
            self.assert_rejected(checked, "CHECK-REDEFINED-NAME")

    def test_http_wire_is_internal_to_std_http_for_user_files_relative_imports_and_pkg_modules(self):
        call = 'export def go() -> Void\n  HttpWire.options(HttpWire.service(1, 1, 1))\nend\n\n'
        roots = [("root.agc", 'import Wire from "pkg/wire"\ndef main() -> Void\n'
                              '  HttpWire.jobs(HttpWire.service(1, 1, 1))\nend\n\n'),
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
                             '  HTTP.close_client(Result.unwrap!(HTTP.client()))\nend\n\n'},
                "root.agc", None)]
            + [({"root.agc": http + body + "end\n\n"}, "root.agc", None) for body, _code in bodies]
            + [({"root.agc": "struct %s\n  n: Int\nend\n\n" % name + MAIN}, "root.agc", None) for name in names])
        roots_checked, clean, body_checked, names_checked = (
            results[:3], results[3], results[4:7], results[7:])
        for (name, _text), checked in zip(roots, roots_checked):
            self.assert_rejected(checked, "CHECK-UNKNOWN-NAME", file=name)
        assert clean[1] is None
        for (body, code), checked in zip(bodies, body_checked):
            problem = self.assert_rejected(checked, code)
            # The hint must not name the internal HttpWire type, which the user never wrote.
            assert "HttpWire" not in json.dumps(problem)
        for name, checked in zip(names, names_checked):
            self.assert_rejected(checked, "CHECK-REDEFINED-NAME")

    def test_the_http_wire_records_are_types_only_std_can_name_and_reserve_no_user_name(self):
        uses = [("def main() -> Void\n  heads: List[HttpWire.Head] = []\nend\n\n", 2),
                ("def f(chunk: HttpWire.Chunk) -> Void\nend\n\n" + MAIN, 1)]
        own = "struct Head\n  n: Int\nend\n\nstruct Chunk\n  n: Int\nend\n\n" + MAIN
        results = self.checks([({"root.agc": text}, "root.agc", None) for text, _line in uses]
                              + [({"root.agc": own}, "root.agc", None)])
        for (_text, line), checked in zip(uses, results[:2]):
            self.assert_rejected(checked, "CHECK-UNKNOWN-NAME", line=line)
        assert results[2][1] is None

    def test_a_type_after_a_function_is_out_of_order_at_the_type(self):
        problem = self.check({"root.agc": "def main() -> Void\nend\n\nstruct Late\n  n: Int\nend\n\n"})
        assert start(self.assert_rejected(problem, "CHECK-DECL-ORDER")) == (4, 1)

    def test_a_private_function_before_an_exported_one_is_out_of_order_at_the_export(self):
        results = self.checks([
            ({"root.agc": "def helper() -> Void\nend\n\nexport def api() -> Void\nend\n\n"}, "root.agc", None),
            ({"root.agc": "def helper() -> Void\nend\n\nexport struct Late\nend\n\n"}, "root.agc", None)])
        for checked in results:
            assert start(self.assert_rejected(checked, "CHECK-DECL-ORDER")) == (4, 1)

    def test_a_private_enum_after_a_function_is_out_of_order_at_the_enum(self):
        problem = self.check({"root.agc": "def main() -> Void\nend\n\nenum Late\n  A\nend\n\n"})
        assert start(self.assert_rejected(problem, "CHECK-DECL-ORDER")) == (4, 1)

    def test_an_extern_block_with_a_resource_sits_with_the_types_as_a_whole(self):
        block = ('extern "/opt/libdb.so"\n  resource Db, free: db_close\n  def db_open() -> Db\n'
                 "  def db_ping() -> C.Int32\nend\n\n")
        plain = 'extern "/opt/libdb.so"\n  def db_stat() -> C.Int32\nend\n\n'
        mixed = ('extern "/opt/libdb.so"\n  export def db_load(path: C.String, out size: C.Int32) -> C.Int32\n'
                 "  compute def db_scan(db: C.Pointer) -> C.Int32\n  resource Db, free: db_close\nend\n\n")
        api = "export def api() -> Void\nend\n\n"
        later = "def helper() -> Void\nend\n\n"
        results = self.checks([({"root.agc": text + MAIN}, "root.agc", None) for text in (
            # The private defs of the block do not count as functions: the block goes before the exported ones.
            block + api + later,
            # After an exported function the block is out of order, at its first member.
            api + block,
            # A block with neither a resource nor a struct keeps its rule:
            # private defs come after the exported functions.
            plain + api,
            api + plain,
            # The rule is per block, also for two blocks of one library.
            block + plain + api,
            block + api + plain,
            # An exported def with an out record and a compute def, with the resource declared after them.
            mixed + api + later)])
        assert results[0][1] is None
        assert start(self.assert_rejected(results[1], "CHECK-DECL-ORDER")) == (5, 3)
        assert start(self.assert_rejected(results[2], "CHECK-DECL-ORDER")) == (5, 1)
        assert results[3][1] is None
        assert start(self.assert_rejected(results[4], "CHECK-DECL-ORDER")) == (11, 1)
        assert results[5][1] is None
        assert results[6][1] is None

    def test_an_import_after_a_declaration_is_out_of_order(self):
        problem = self.check({
            "lib.agc": "export def go() -> Void\nend\n\n",
            "root.agc": 'struct Early\nend\n\nimport Lib from "lib"\n'})
        assert start(self.assert_rejected(problem, "CHECK-DECL-ORDER")) == (4, 1)

    def test_types_in_any_order_then_exports_then_private_functions_check_clean(self):
        assert self.check({
            "lib.agc": "export def go() -> Void\nend\n\n",
            "root.agc": '## Module doc.\n\nimport Lib from "lib"\nimport Queue from "std/queue"\n\n'
                        "export enum Kind\n  A\nend\n\nstruct Box\n  n: Int\nend\n\n"
                        "export struct Pair\n  n: Int\nend\n\nenum Hidden\n  B\nend\n\n"
                        "export def api() -> Void\n  Lib.go()\n  helper()\nend\n\n"
                        "def helper() -> Void\nend\n\n" + MAIN})[1] is None

    def test_an_imported_module_is_checked_too_and_the_diagnostic_names_its_file(self):
        checked = self.check({
            "lib.agc": "def helper() -> Void\nend\n\nexport def go() -> Void\nend\n\n",
            "root.agc": 'import Lib from "lib"\ndef main() -> Void\n  Lib.go()\nend\n\n'})
        problem = self.assert_rejected(checked, "CHECK-DECL-ORDER", file="lib.agc")
        assert start(problem) == (4, 1)

    def test_embedded_std_modules_follow_the_rule_so_importing_them_never_trips_it(self):
        names = ["std/http", "std/logger", "std/binary", "std/toml", "std/queue"]
        results = self.checks([({"root.agc": 'import M from "%s"\n' % name + MAIN}, "root.agc", None)
                               for name in names])
        for name, (_directory, problem) in zip(names, results):
            assert problem is None

    def test_an_imported_alias_in_a_generic_enum_is_not_captured_by_a_parameter_named_like_a_lib_type(self):
        # `Item` is a type of lib.agc and the parameter of the enum; the alias target is read in lib.agc, so
        # neither the named nor the qualified use is a capture.
        lib = ("struct Item\n  n: Int\nend\n\n"
               "export type Items = List[Item]\n\n"
               "export type Box[T] = List[T]\n\n")
        enum = "enum E[Item]\n  V(Items, Lib.Items, Box[Item], Lib.Box[Item])\nend\n\n"
        results = self.checks([
            ({"lib.agc": lib, "root.agc": 'import Lib from "lib"\nimport {Items, Box} from "lib"\n\n' + enum + MAIN},
             "root.agc", None),
            ({"lib.agc": lib, "root.agc": 'import {Items} from "lib"\n\nenum E[Item]\n  V(Items)\nend\n\n' + MAIN},
             "root.agc", None)])
        for _directory, problem in results:
            assert problem is None

    URL = ("export struct Address\n  host: String\nend\n\n"
           "export enum Option\n  Some(Int)\n  None\nend\n\n"
           "export def parse(text: String) -> Address\n  return Address(host: text)\nend\n\n"
           "def hidden() -> Void\nend\n\n")

    def test_a_module_re_exports_what_it_imports_and_the_importer_sees_the_original_declaration(self):
        files = {
            "url.agc": self.URL,
            "mid.agc": 'import Url from "url"\n\nexport Url.parse\nexport Url.Address\nexport Url.Option\n',
            "web.agc": 'import Mid from "mid"\n\nexport Mid.parse\nexport Mid.Address\nexport Mid.Option\n',
            # One function, one type and one enum through the facade, through a chain of two and directly: a value of
            # one is a value of the others, variants and `.with` included.
            "root.agc": 'import Web from "web"\nimport Url from "url"\n\n'
                        "def main() -> Void\n"
                        '  address: Url.Address = Web.parse("a")\n'
                        "  same: Web.Address = address.with(host: \"b\")\n"
                        "  parse: Fn[String, Url.Address] = &Web.parse\n"
                        "  option: Url.Option = Web.Option.Some(1)\n"
                        "  case option\n    Web.Option.Some(n) -> puts(n)\n    Url.Option.None -> puts(0)\n  end\n"
                        "end\n\n"}
        assert self.check(files)[1] is None

    def test_a_re_export_names_an_import_alias_of_the_file_and_an_export_of_that_module(self):
        url = self.URL
        cases = [
            # (re-export lines, code, line, column of the span)
            ("export Urr.parse\n", "CHECK-IMPORT-NAME", 3, 8),
            ("export Url.parsee\n", "CHECK-IMPORT-NAME", 3, 12),
            ("export Url.hidden\n", "CHECK-IMPORT-NAME", 3, 12),
            ("export Url.parse\nexport Url.parse\n", "CHECK-REDEFINED-NAME", 4, 12),
            ("export Url.parse\n\nexport def parse() -> Void\nend\n\n", "CHECK-REDEFINED-NAME", 3, 12),
            ("export Url.Address\n\nexport struct Address\nend\n\n", "CHECK-REDEFINED-NAME", 3, 12),
        ]
        results = self.checks([({"url.agc": url, "facade.agc": 'import Url from "url"\n\n' + lines,
                                 "root.agc": 'import Facade from "facade"\n\n' + MAIN}, "root.agc", None)
                               for lines, _code, _line, _column in cases])
        for (_lines, code, line, column), checked in zip(cases, results):
            problem = self.assert_rejected(checked, code, line=line, file="facade.agc")
            assert start(problem) == (line, column)
        assert results[1][1]["help"]
        # A name imported by name has no alias to re-export through.
        by_name = self.check({"url.agc": url, "facade.agc": 'import {parse} from "url"\n\nexport Url.parse\n',
                              "root.agc": 'import Facade from "facade"\n\n' + MAIN})
        self.assert_rejected(by_name, "CHECK-IMPORT-NAME", line=3, file="facade.agc")
        clash = self.check({"url.agc": url, "facade.agc": 'import Url from "url"\nimport Address from "url"\n\n'
                                                          "export Url.Address\n",
                            "root.agc": 'import Facade from "facade"\n\n' + MAIN})
        self.assert_rejected(clash, "CHECK-REDEFINED-NAME", line=4, file="facade.agc")

    def test_a_re_export_adds_no_local_name_and_has_no_rename_or_wildcard(self):
        files = {"url.agc": self.URL}
        cases = [
            ('import Url from "url"\n\nexport Url.parse\n\ndef main() -> Void\n  parse("a")\nend\n\n',
             "CHECK-UNKNOWN-NAME"),
            ('import Url from "url"\n\nexport Url.parse as fetch\n' + MAIN, "PARSE-UNEXPECTED-TOKEN"),
            ('import Url from "url"\n\nexport Url.*\n' + MAIN, "PARSE-UNEXPECTED-TOKEN"),
        ]
        results = self.checks([({**files, "root.agc": text}, "root.agc", None) for text, _code in cases])
        for (_text, code), checked in zip(cases, results):
            self.assert_rejected(checked, code, line=3 if code.startswith("PARSE") else 6)

    def test_a_re_export_follows_the_blank_line_rule_of_imports(self):
        url = {"url.agc": self.URL}
        after_import = self.check(
            {**url, "root.agc": 'import Url from "url"\nexport Url.parse\nexport Url.Address\n' + MAIN})
        after_declaration = self.check({**url, "root.agc": 'import Url from "url"\n\nexport def api() -> Void\nend\n'
                                                           "export Url.parse\n" + MAIN})
        assert after_import[1] is None
        assert start(self.assert_rejected(after_declaration, "PARSE-MISSING-BLANK-LINE")) == (5, 1)

    def test_a_re_export_next_to_other_forms_a_doc_a_constant_a_cycle_and_its_own_alias(self):
        url = {"url.agc": self.URL}
        value = "export struct Value\n  n: Int\nend\n\n"
        cycle_url = ('import Facade from "facade"\n\n'
                     "export def parse(text: String) -> Int\n  return 1\nend\n\n")
        root = 'import Facade from "facade"\n\n' + MAIN
        cases = [
            # (files, code, file, line, column)
            ({**url, "facade.agc": 'import Url from "url"\n\n## Doc.\nexport Url.parse\n', "root.agc": root},
             "PARSE-DETACHED-DOC", "facade.agc", 3, 1),
            ({**url, "facade.agc": 'import Url from "url"\n\nLIMIT = 1\n\nexport Url.parse\n', "root.agc": root},
             "CHECK-DECL-ORDER", "facade.agc", 5, 1),
            ({"url.agc": cycle_url, "facade.agc": 'import Url from "url"\n\nexport Url.parse\n', "root.agc": root},
             "CHECK-IMPORT-CYCLE", "url.agc", 1, 1),
            ({"value.agc": value, "facade.agc": 'import Value from "value"\n\nexport Value.Value\n', "root.agc": root},
             "CHECK-REDEFINED-NAME", "facade.agc", 3, 14),
        ]
        results = self.checks([(files, "root.agc", None) for files, *_rest in cases])
        for (_files, code, file, line, column), checked in zip(cases, results):
            problem = self.assert_rejected(checked, code, line=line, file=file)
            assert start(problem) == (line, column)
        # The alias of the facade is the usual cause of the last one, so the diagnostic says what to do.
        assert results[3][1]["help"]

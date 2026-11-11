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
from tests.spec_support import check_paths

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
        The roots of one env are checked by one `--json check ROOT...` call, which gives each root the diagnostic of
        a check of that root alone.
        """
        jobs = []
        for files, root, env in cases:
            directory = files if isinstance(files, Path) else self.files(files)
            env = {key: value.replace("{dir}", str(directory)) for key, value in (env or {}).items()}
            jobs.append((directory, str(directory / root), tuple(sorted(env.items()))))
        groups = {}
        for _directory, path, env in jobs:
            groups.setdefault(env, []).append(path)
        problems = {}
        for env, paths in groups.items():
            found = check_paths(list(dict.fromkeys(paths)), cwd=self.cwd, env=vm_environment({**HERMETIC, **dict(env)}))
            problems.update(((env, path), problem) for path, problem in found.items())
        for problem in problems.values():
            # Internal names (with the module mangling '@') must not reach a user in the message or the help.
            assert "@" not in json.dumps({key: (problem or {}).get(key) for key in ("message", "help")})
        return [(directory, problems[(env, path)]) for directory, path, env in jobs]

    def check(self, files, root="root.agc", env=None):
        """One check (see checks()): its (directory, problem)."""
        return self.checks([(files, root, env)])[0]

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

    def test_a_relative_import_that_finds_no_file_has_help_at_the_import(self):
        """An import is relative to the importing file: a missing folder or file is CHECK-IMPORT-IO at the import
        line, with a help (the path tried, and the form from the importing file when the project folder has it)."""
        lib = "export def hi() -> String\n  return \"hi\"\nend\n"
        main = "\ndef main() -> Void\nend\n"
        cases = [
            ({"agentica.toml": 'name = "p"\n', "src/lib.agc": lib, "tools/x.agc": 'import L from "src/lib"\n' + main},
             "tools/x.agc"),
            ({"agentica.toml": 'name = "p"\n', "tools/x.agc": 'import L from "gone"\n' + main}, "tools/x.agc"),
        ]
        results = self.checks([(files, root, None) for files, root in cases])
        for (_files, root), checked in zip(cases, results):
            problem = self.assert_rejected(checked, "CHECK-IMPORT-IO", line=1, file=root)
            assert start(problem) == (1, 1)
            assert problem["help"]

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
            "bad.agc": "export struct Point\n  x: Int\nend\n\nstruct Pair\n  p: Pont\nend\n\n",
            "calls.agc": "export def go() -> Int\n  return helpr()\nend\n\ndef helper() -> Int\n  return 1\nend\n\n",
            "types.agc": 'import B from "bad"\n\ndef shown(p: B.Point) -> Void\nend\n\n' + MAIN,
            "funcs.agc": 'import C from "calls"\n\ndef helpe() -> Int\n  return 2\nend\n\n'
                         "def main() -> Void\n  _n = C.go()\nend\n\n"}
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
        good = ("  _x = Lib.LIMIT + 1\n  puts(Lib.NAMES.size)\n  puts(Lib.CONFIG.port)\n"
                "  _moved: Lib.Config = Lib.CONFIG.with(port: 81)\n  puts(\"#{Lib.LIMIT}\")\n")
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
                  "  puts(Lib.NAMES.reduce(0) do |n, _| n + 1 end)\n",
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
                 ("  HTTP.begin(1, 200, [], 1000)\n", True),
                 ("  HTTP.listen(\"127.0.0.1\", 0, 1)\n", True),
                 ("  HTTP.listen_stream_tls(\"127.0.0.1\", 0, 1, 2)\n", True),
                 ("  HTTP.listen_upload(\"127.0.0.1\", 0, 1)\n", True),
                 ("  HTTP.upgrade_only(1)\n", True),
                 ("  x: HTTP.UpgradeHandler = nil\n", True),
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

    def test_std_logger_exports_its_event_and_level_and_log_registry_stays_internal(self):
        """std/logger re-exports the builtin LogRegistry.Event and LogRegistry.Level as Logger.Event and Logger.Level
        (import Logger, or import {Event, Level}). LogRegistry is internal to std/, as a call, a type or a re-export,
        and the old names LogEvent and LogLevel are unknown, with a help that names the new ones."""
        uses = ('import Logger from "std/logger"\nimport {Event, Level} from "std/logger"\n\n'
                "def shown(event: Logger.Event) -> Void\n  puts(event.message)\nend\n\n"
                "def rank(level: Level) -> Int\n  case level\n    Logger.Level.Debug -> 0\n    Level.Info -> 1\n"
                "    _ -> 2\n  end\nend\n\n"
                "def main() -> Void\n  _ = Logger.attach(\"shown\", Logger.Level.Debug, &shown)\n"
                "  event: Event = Logger.Event(level: Logger.level(), message: \"m\", fields: {}, time_ms: 0, task: 1)\n"
                "  shown(event)\n  puts(rank(event.level))\nend\n\n")
        logger = 'import Logger from "std/logger"\n\n'
        in_lib = 'import Lib from "lib"\n\ndef main() -> Void\n  Lib.f()\nend\n\n'
        # (files, code, span, file of the error, whether the help must name the new type)
        cases = [
            ({"root.agc": uses}, None, None, None, False),
            ({"root.agc": "def main() -> Void\n  x = LogRegistry.level()\nend\n\n"}, "CHECK-UNKNOWN-NAME",
             ((2, 7), (2, 26)), None, False),
            ({"root.agc": "def f(e: LogRegistry.Event) -> Void\nend\n\n" + MAIN}, "CHECK-UNKNOWN-NAME",
             ((1, 10), (1, 27)), None, False),
            ({"root.agc": "export LogRegistry.Event\n\n" + MAIN}, "CHECK-UNKNOWN-NAME", ((1, 8), (1, 19)), None, False),
            ({"root.agc": logger + 'def main() -> Void\n  Logger.error("x")\nend\n\n'}, "CHECK-IMPORT-NAME", None, None,
             False),
            ({"root.agc": "def f(e: LogEvent) -> Void\nend\n\n" + MAIN}, "CHECK-UNKNOWN-TYPE", ((1, 10), (1, 18)), None,
             True),
            ({"root.agc": in_lib, "lib.agc": "export def f() -> Void\n  e: LogEvent = 1\nend\n"}, "CHECK-UNKNOWN-TYPE",
             ((2, 6), (2, 14)), "lib.agc", True),
            ({"root.agc": logger + "def main() -> Void\n  Logger.set_level(LogLevel.Info)\nend\n\n"},
             "CHECK-IMPORT-NAME", ((4, 20), (4, 33)), None, True),
            ({"root.agc": 'import {LogEvent} from "std/logger"\n\n' + MAIN}, "CHECK-IMPORT-NAME", None, None, True),
        ]
        results = self.checks([(files, "root.agc", None) for files, _code, _span, _file, _help in cases])
        for (files, code, span, file, help), checked in zip(cases, results):
            if code is None:
                assert checked[1] is None, checked[1]
                continue
            problem = self.assert_rejected(checked, code, file=file)
            if span is not None:
                found = problem["range"]
                assert ((found["start"]["line"], found["start"]["column"]),
                        (found["end"]["line"], found["end"]["column"])) == span, files
            if help:
                assert problem.get("help"), files

    def test_a_struct_or_alias_may_be_named_like_a_std_only_family_with_records_and_an_enum_may_not(self):
        """A struct or a type alias may be named LogRegistry, beside std/logger and a Logger.Event(...) of the root. An
        enum of that name stays CHECK-REDEFINED-NAME: once linked, its variant Event(...) and the builtin record
        LogRegistry.Event(...) would be the same name."""
        use = 'import Logger from "std/logger"\n\n'
        event = '  e = Logger.Event(level: Logger.Level.Info, message: "m", fields: {}, time_ms: 0, task: 1)\n'
        main = 'def main() -> Void\n  Logger.info("x")\n' + event + "  Logger.stderr_text(e)\n"
        free = [
            use + "struct LogRegistry\n  n: Int\nend\n\n" + main + "  puts(LogRegistry(n: 1).n)\nend\n\n",
            use + "type LogRegistry = Int\n\n" + main + "  x: LogRegistry = 1\n  puts(x)\nend\n\n",
        ]
        enum = use + "enum LogRegistry\n  Level\n  Event(Int)\nend\n\n" + main + "end\n\n"
        results = self.checks([({"root.agc": root}, "root.agc", None) for root in free + [enum]])
        for checked in results[:-1]:
            assert checked[1] is None, checked[1]
        found = self.assert_rejected(results[-1], "CHECK-REDEFINED-NAME")["range"]
        assert ((found["start"]["line"], found["start"]["column"]),
                (found["end"]["line"], found["end"]["column"])) == ((3, 1), (7, 1))

    def test_the_names_of_the_std_only_families_and_the_old_log_types_are_free_for_a_program(self):
        """LogEvent, LogLevel, LogRegistry (not as an enum), RegexEngine and Std reserve no name: a program may declare
        them, and an import alias may be Std, while std/regex and std/logger, which call the builtins, still work beside
        them. A call of RegexEngine outside std/ is still CHECK-UNKNOWN-NAME."""
        declarations = ("struct LogEvent\n  n: Int\nend\n\nenum LogLevel\n  Loud\nend\n\n"
                        "struct LogRegistry\n  n: Int\nend\n\nstruct RegexEngine\n  n: Int\nend\n\n")
        search = '  x = RegexEngine.search("a", [8], [0], [0], [], 2, 0)\n'
        free, aliased, engine = self.checks([
            ({"root.agc": 'import Logger from "std/logger"\nimport Regex from "std/regex"\n\n' + declarations
              + 'def main() -> Void\n  puts(Regex.match?("aa", Regex.compile("a+").unwrap!))\n  Logger.info("x")\n'
              + "  puts(RegexEngine(n: 1).n + LogEvent(n: 2).n)\n  puts(LogLevel.Loud)\nend\n\n"},
             "root.agc", None),
            ({"root.agc": 'import Std from "lib"\n\ndef main() -> Void\n  puts(Std.source(1))\nend\n\n',
              "lib.agc": "export def source(n: Int) -> Int = n\n"}, "root.agc", None),
            ({"root.agc": 'import Lib from "lib"\ndef main() -> Void\n  Lib.go()\nend\n\n',
              "lib.agc": "export def go() -> Void\n" + search + "end\n\n"}, "root.agc", None)])
        assert free[1] is None, free[1]
        assert aliased[1] is None, aliased[1]
        assert start(self.assert_rejected(engine, "CHECK-UNKNOWN-NAME", file="lib.agc")) == (2, 7)

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
        http = 'import HTTP from "std/http"\ndef main() -> Void\n  puts(HTTP.proxy_from_env("x"))\n'
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
                        "def helper() -> Void\n  _ = Queue.new()\nend\n\n" + MAIN})[1] is None

    def test_an_imported_module_is_checked_too_and_the_diagnostic_names_its_file(self):
        checked = self.check({
            "lib.agc": "def helper() -> Void\nend\n\nexport def go() -> Void\nend\n\n",
            "root.agc": 'import Lib from "lib"\ndef main() -> Void\n  Lib.go()\nend\n\n'})
        problem = self.assert_rejected(checked, "CHECK-DECL-ORDER", file="lib.agc")
        assert start(problem) == (4, 1)

    def test_embedded_std_modules_follow_the_rule_so_importing_them_never_trips_it(self):
        names = {"std/http": "client", "std/logger": "debug", "std/binary": "read_u8", "std/toml": "parse",
                 "std/queue": "new"}
        results = self.checks([({"root.agc": 'import M from "%s"\n\ndef main() -> Void\n  _f = &M.%s\nend\n' % (name, member)},
                                "root.agc", None) for name, member in names.items()])
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
                        "  _same: Web.Address = address.with(host: \"b\")\n"
                        "  _parse: Fn[String, Url.Address] = &Web.parse\n"
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

    SHAPES = ("export LIMIT = 3\n\nexport struct Square\n  side: Int\nend\n\nexport enum Shade\n  Dark\n  Light(Int)\nend\n\n"
              "export def area(s: Square) -> Int\n  return s.side * s.side\nend\n\n"
              "export def pick() -> Optional[Shade]\n  return none\nend\n\n")

    def test_an_import_alias_that_nothing_uses_is_refused_at_the_alias(self):
        shapes = {"shapes.agc": self.SHAPES, "extra.agc": "export def one() -> Int\n  return 1\nend\n\n"}
        root = 'import Shapes from "shapes"\nimport Extra from "extra"\n\n'
        # The first alias that is never used is the one reported, at the alias and not at the whole line.
        unused = self.check({**shapes, "root.agc": root + "def main() -> Void\n  puts(Shapes.LIMIT)\nend\n"})
        problem = self.assert_rejected(unused, "CHECK-UNUSED-IMPORT", line=2, file="root.agc")
        assert start(problem) == (2, 8)
        assert problem["range"]["end"]["column"] == 13
        assert problem["help"]
        # Names of an import list are not reported, and an unused function of a file still counts as a use.
        used = self.check({**shapes, "root.agc": 'import {area} from "shapes"\nimport Extra from "extra"\n\n'
                                                  "def later() -> Int\n  return Extra.one()\nend\n\n" + MAIN})
        assert used[1] is None

    # The only place that writes `Shapes.` in each program: the alias is used there and nowhere else, so each case
    # is one use site. The names `Square`, `area` and `pick` come by name, which is no use of the alias.
    USE_SITES = [
        ("a parameter type", "def f(s: Shapes.Square) -> Int\n  return area(s)\nend\n\n"),
        ("a result type", "def f() -> Shapes.Square\n  return Square(side: 1)\nend\n\n"),
        ("a struct field type", "struct Holder\n  s: Shapes.Square\nend\n\n"),
        ("an enum payload type", "enum Box\n  Full(Shapes.Square)\nend\n\n"),
        ("a type alias target", "type Sq = Shapes.Square\n\n"),
        ("a constant initializer", "COPY = Shapes.LIMIT\n\n"),
        ("a parameter default", "def f(n: Int = Shapes.LIMIT) -> Int\n  return n\nend\n\n"),
        ("a binding type", "def main() -> Void\n  s: Shapes.Square = Square(side: 1)\n  puts(area(s))\nend\n"),
        ("a block parameter type", "def main() -> Void\n  xs = [Square(side: 1)]\n"
                                   "  ys = xs.map do |s: Shapes.Square| s.side end\n  puts(ys.size)\nend\n"),
        ("an interpolation", 'def main() -> Void\n  puts("n=#{Shapes.LIMIT}")\nend\n'),
        ("a pipe", "def main() -> Void\n  puts(Square(side: 2) |> Shapes.area())\nend\n"),
        ("a function value", "def main() -> Void\n  f = &Shapes.area\n  puts(f.call(Square(side: 1)))\nend\n"),
        ("a construction", "def main() -> Void\n  puts(area(Shapes.Square(side: 1)))\nend\n"),
        ("a nested pattern", "def main() -> Void\n  case pick()\n    some(Shapes.Shade.Dark) -> puts(1)\n"
                             "    _ -> puts(2)\n  end\nend\n"),
        ("an enum constructor expression", "def main() -> Void\n  _s = Shapes.Shade.Light(1)\n  puts(1)\nend\n"),
        ("a direct variant pattern arm", "def f(s: Shade) -> Int\n  case s\n    Shapes.Shade.Dark -> return 1\n"
                                         "    Shapes.Shade.Light(n) -> return n\n  end\nend\n\n"),
        ("a case guard", "def main() -> Void\n  case some(1)\n    some(n) if n < Shapes.LIMIT -> puts(n)\n"
                         "    _ -> puts(0)\n  end\nend\n"),
        ("a type argument", "def f(xs: List[Shapes.Square]) -> Int\n  return xs.size\nend\n\n"),
    ]

    @pytest.mark.parametrize("site, body", USE_SITES, ids=[site for site, _body in USE_SITES])
    def test_every_place_that_writes_an_alias_with_a_member_counts_as_a_use(self, site, body):
        root = self.USE_HEADER + body + ("" if "def main()" in body else MAIN)
        assert self.check({"shapes.agc": self.SHAPES, "root.agc": root})[1] is None, site

    USE_HEADER = 'import Shapes from "shapes"\nimport {Shade, Square, area, pick} from "shapes"\n\n'

    def test_the_same_program_without_a_use_is_the_unused_import(self):
        bare = self.USE_HEADER + MAIN
        self.assert_rejected(self.check({"shapes.agc": self.SHAPES, "root.agc": bare}), "CHECK-UNUSED-IMPORT", line=1)

    def test_a_re_export_a_regex_literal_and_a_template_use_the_import_they_need(self):
        url = {"url.agc": self.URL}
        facade = {**url, "facade.agc": 'import Url from "url"\n\nexport Url.parse\n',
                  "root.agc": 'import Facade from "facade"\n\ndef main() -> Void\n  puts(Facade.parse("a").host)\nend\n'}
        regex = 'import Regex from "std/regex"\n\ndef main() -> Void\n  _r = /a+/\nend\n'
        template = 'import EAG from "std/eag"\n\ndef page() -> String\n  return <<~EAG\n    hi\n  EAG\nend\n\n' + MAIN
        results = self.checks([(facade, "root.agc", None), ({"root.agc": regex}, "root.agc", None),
                               ({"root.agc": template}, "root.agc", None)])
        assert [problem for _directory, problem in results] == [None, None, None]

    def test_an_unused_alias_is_reported_in_the_file_that_has_it(self):
        files = {"shapes.agc": self.SHAPES,
                 "lib.agc": 'import Shapes from "shapes"\n\nexport def one() -> Int\n  return 1\nend\n',
                 "root.agc": 'import Lib from "lib"\n\ndef main() -> Void\n  puts(Lib.one())\nend\n'}
        self.assert_rejected(self.check(files), "CHECK-UNUSED-IMPORT", line=1, file="lib.agc")

    def test_an_alias_without_its_member_or_a_mistyped_alias_is_not_an_unused_import(self):
        shapes = {"shapes.agc": self.SHAPES}
        header = 'import Shapes from "shapes"\n\n'
        results = self.checks([
            ({**shapes, "root.agc": header + "def main() -> Void\n  x: Shapes = nil\nend\n"}, "root.agc", None),
            ({**shapes, "root.agc": header + "def main() -> Void\n  s = Shapes.Square(side: 1)\n  puts(Shpaes.area(s))\nend\n"},
             "root.agc", None),
            ({**shapes, "root.agc": header + "def main() -> Void\n  x = Shapes.Light(1)\nend\n"}, "root.agc", None)])
        bare = self.assert_rejected(results[0], "CHECK-IMPORT-NAME", line=4, file="root.agc")
        assert start(bare) == (4, 6)
        # A variant of an enum named like the alias: the enum is missing, and the help names it.
        variant = self.assert_rejected(results[2], "CHECK-IMPORT-NAME", line=4, file="root.agc")
        assert start(variant) == (4, 7)
        assert "Shade" in variant["help"]
        self.assert_rejected(results[1], "CHECK-UNKNOWN-NAME", line=5)

    BLOCKS = ("import Lib from \"lib\"\n\nTOP = 1\n\n"
              "export module Pub\n  export enum Tree[T]\n    Leaf(T)\n    Node(List[Tree[T]])\n  end\n\n"
              "  export struct Pair[A, B]\n    left: A\n    right: B\n  end\n\n"
              "  export def leaf[T](value: T) -> Tree[T] = Tree.Leaf(value)\n\n"
              "  export def total() -> Int = hidden() + Priv.f() + Lib.one()\n\n"
              "  def hidden() -> Int = TOP + secret()\nend\n\n"
              "module Priv\n  export def f() -> Int = Pub.total() - Pub.total() + 1\n\n  def g() -> Int = 2\nend\n\n"
              "def secret() -> Int = 3\n")

    def test_module_blocks_see_their_file_and_each_other_and_export_through_both_import_forms(self):
        lib = {"lib.agc": "export def one() -> Int = 1\n", "mods.agc": self.BLOCKS}
        braces = ('import {Pub} from "mods"\n\ndef main() -> Void\n'
                  "  t: Pub.Tree[Int] = Pub.Tree.Node([Pub.leaf(1)])\n"
                  "  p: Pub.Pair[Int, String] = Pub.Pair(left: Pub.total(), right: \"x\")\n"
                  "  case t\n    Pub.Tree.Leaf(n) -> puts(n + p.left)\n    Pub.Tree.Node(_) -> puts(p.right)\n  end\nend\n")
        alias = ('import Mods from "mods"\n\ndef main() -> Void\n'
                 "  t: Mods.Pub.Tree[Int] = Mods.Pub.Tree.Node([Mods.Pub.leaf(1)])\n"
                 "  p: Mods.Pub.Pair[Int, String] = Mods.Pub.Pair(left: Mods.Pub.total(), right: \"x\")\n"
                 "  case t\n    Mods.Pub.Tree.Leaf(n) -> puts(n + p.left)\n    Mods.Pub.Tree.Node(_) -> puts(p.right)\n"
                 "  end\nend\n")
        results = self.checks([({**lib, "root.agc": braces}, "root.agc", None),
                               ({**lib, "root.agc": alias}, "root.agc", None)])
        assert [problem for _directory, problem in results] == [None, None]

    def test_a_private_name_of_a_module_block_and_a_private_block_are_refused_like_private_exports(self):
        lib = {"lib.agc": "export def one() -> Int = 1\n", "mods.agc": self.BLOCKS}
        cases = [('import {Pub} from "mods"\n\ndef main() -> Void\n  puts(Pub.hidden())\nend\n', (4, 8)),
                 ('import {Priv} from "mods"\n\ndef main() -> Void\nend\n', (1, 9)),
                 ('import Mods from "mods"\n\ndef main() -> Void\n  puts(Mods.Priv.f())\nend\n', (4, 8))]
        results = self.checks([({**lib, "root.agc": root}, "root.agc", None) for root, _at in cases])
        for (_root, at), checked in zip(cases, results):
            assert start(self.assert_rejected(checked, "CHECK-IMPORT-NAME", file="root.agc")) == at
        # Inside the file, a private name of a block is refused the same way.
        local = "module A\n  def hidden() -> Int = 1\nend\n\ndef main() -> Void\n  puts(A.hidden())\nend\n"
        assert start(self.assert_rejected(self.check({"root.agc": local}), "CHECK-IMPORT-NAME")) == (6, 8)

    def test_a_module_block_name_follows_the_rules_of_an_import_alias(self):
        lib = {"lib.agc": "export def one() -> Int = 1\n"}
        cases = [("module String\nend\n\n" + MAIN, (1, 8)),
                 ("struct Point\n  x: Int\nend\n\nmodule Point\nend\n\n" + MAIN, (5, 8)),
                 ("module M\nend\n\nmodule M\nend\n\n" + MAIN, (4, 8)),
                 ('import Lib from "lib"\n\nmodule Lib\nend\n\n' + MAIN, (1, 1))]
        results = self.checks([({**lib, "root.agc": root}, "root.agc", None) for root, _at in cases])
        for (_root, at), checked in zip(cases, results):
            assert start(self.assert_rejected(checked, "CHECK-REDEFINED-NAME")) == at

    def test_a_module_block_is_top_level_ranks_with_the_types_and_may_be_empty(self):
        cases = [("module A\n  module B\n  end\nend\n\n" + MAIN, "PARSE-NESTED-MODULE", (2, 3)),
                 ("module A\n  ## B.\n  export module B\n  end\nend\n\n" + MAIN, "PARSE-NESTED-MODULE", (3, 10)),
                 ('module A\n  import B from "b"\nend\n\n' + MAIN, "PARSE-UNEXPECTED-TOKEN", (2, 3)),
                 ("def f() -> Int = 1\n\nmodule A\nend\n\n" + MAIN, "CHECK-DECL-ORDER", (3, 1))]
        results = self.checks([({"root.agc": root}, "root.agc", None) for root, _code, _at in cases])
        for (_root, code, at), checked in zip(cases, results):
            assert start(self.assert_rejected(checked, code)) == at
        empty = "module Empty\nend\n\n" + MAIN
        assert self.check({"root.agc": empty})[1] is None

    def test_an_import_a_re_export_or_an_extern_block_inside_a_module_block_is_a_parse_error(self):
        cases = ["module A\n  export Lib.one\nend\n\n" + MAIN,
                 'module A\n  extern module "m"\n    def f() -> Int\n  end\nend\n\n' + MAIN]
        results = self.checks([({"root.agc": root}, "root.agc", None) for root in cases])
        for checked in results:
            assert start(self.assert_rejected(checked, "PARSE-UNEXPECTED-TOKEN")) == (2, 3)

    def test_a_module_block_may_not_declare_a_name_its_file_has_and_may_not_declare_main(self):
        """One name means one thing in a scope: a block cannot hide a top-level declaration, private ones too, an
        import alias, an imported name or a block of its file. Two blocks may each declare the same name."""
        lib = {"lib.agc": "export def parse() -> Int = 1\n"}
        member = "  export def go() -> Int = 2\n"
        cases = [
            ("def helper() -> Int = 1\n", "module M\n" + member + "\n  def helper() -> Int = 3\nend\n", (4, 7)),
            ("LIMIT = 1\n", "module M\n  LIMIT = 2\n\n" + member + "end\n", (4, 3)),
            ('import {parse} from "lib"\n', "module M\n" + member + "\n  def parse() -> Int = parse()\nend\n",
             (6, 7)),
            ('import Lib from "lib"\n', "module M\n  export struct Lib\n    n: Int\n  end\nend\n", (4, 17)),
            ("", "module M\n  export enum N\n    V\n  end\nend\n\nmodule N\nend\n", (3, 15)),
        ]
        roots = []
        for top, block, _at in cases:
            text = top + "\n" + block + "\ndef main() -> Void\nend\n"
            # A top-level function goes after the block (CHECK-DECL-ORDER).
            if top.startswith("def "):
                text = block + "\n" + top + "\ndef main() -> Void\nend\n"
            roots.append(text)
        results = self.checks([({**lib, "root.agc": root}, "root.agc", None) for root in roots])
        for (_top, _block, at), checked in zip(cases, results):
            problem = self.assert_rejected(checked, "CHECK-SHADOWED-NAME", file="root.agc")
            assert start(problem) == at
            assert problem["help"]
        # `main` runs only at the top level of the root file, so a block may never declare one.
        mains = ["module M\n  def main() -> Void\n  end\nend\n\n" + MAIN,
                 "module M\n  def main() -> Void\n  end\nend\n"]
        for checked in self.checks([({"root.agc": root}, "root.agc", None) for root in mains]):
            assert start(self.assert_rejected(checked, "CHECK-MAIN")) == (2, 7)
        twins = ("module A\n  export def start() -> Int = 1\nend\n\nmodule B\n  export def start() -> Int = 2\nend\n\n"
                 "def main() -> Void\n  puts(A.start() * 10 + B.start())\nend\n")
        directory = self.files({"root.agc": twins})
        result = run(cli() + [str(directory / "root.agc")], cwd=self.cwd, env=vm_environment(HERMETIC))
        assert (result.code, result.stdout) == (0, "12\n")

    def test_a_file_re_exports_a_name_of_its_own_module_block(self):
        lib = ("export Counter.start\n\nmodule Counter\n  export def start() -> Int = 41\nend\n\n"
               "def main() -> Void\n  puts(Counter.start())\nend\n")
        root = 'import {start} from "lib"\n\ndef main() -> Void\n  puts(start() + 1)\nend\n'
        directory = self.files({"lib.agc": lib, "root.agc": root})
        runs = [run(cli() + [str(directory / name)], cwd=self.cwd, env=vm_environment(HERMETIC))
                for name in ("lib.agc", "root.agc")]
        assert [(result.code, result.stdout) for result in runs] == [(0, "41\n"), (0, "42\n")]

    def test_named_arguments_to_a_variant_of_a_module_block_enum_are_refused_through_an_alias_too(self):
        cases = [('import {B} from "lib"\n\ndef main() -> Void\n  _x = B.E.V(v: 1)\nend\n', (4, 8)),
                 ('import A from "lib"\n\ndef main() -> Void\n  _x = A.B.E.V(v: 1)\nend\n', (4, 8)),
                 ('import A from "lib"\n\ndef main() -> Void\n  _x = A.B.E.V(1)\n  _y = A.F.V(v: 1)\nend\n',
                  (5, 8))]
        lib_enum = {"lib.agc": "export module B\n  export enum E\n    V(Int)\n  end\nend\n\nexport enum F\n  V(Int)\nend\n"}
        results = self.checks([({**lib_enum, "root.agc": root}, "root.agc", None) for root, _at in cases])
        for (_root, at), checked in zip(cases, results):
            assert start(self.assert_rejected(checked, "CHECK-ENUM-POSITIONAL-ARGS", file="root.agc")) == at

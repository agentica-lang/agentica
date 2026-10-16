"""The Agentica linker (compiler/link.agc) against the frozen output of the Racket linker.

This module compares the Agentica linker with what the Racket linker printed once for the same inputs (frozen in
tests/fixtures/frontend/frozen/; tools/refreeze.py rewrites them from the Agentica stages): the corpus
(examples/, stdlib/ and tests/fixtures/ as they were at the freeze), the programs of the site, 300 mutated fixtures,
long chains of files, deep trees, files that are not UTF-8 or over 1 MiB, and the number of node ids each file takes.
Inputs that are a formula are rebuilt here; the manifests hold their hashes.
"""
import re
import shutil
import time
from pathlib import Path

from tests.agentica_test import FIXTURES, ROOT, scaled, slow, timeout
from tests.frontend_cases import nested_chains, repeat
from tests.frontend_support import (
    FROZEN, StageTestCase, load_corpus, load_json, sections, tree_files, tree_listing, write_files)

MODULE_FIXTURES = FIXTURES / "frontend" / "modules"

# Hermetic: no AGENTICA_PATH, and a user data folder that does not exist.
DEFAULT_ENV = {"AGENTICA_PATH": "", "XDG_DATA_HOME": "/nonexistent-agentica-xdg"}

# compiler/source_file.agc reads 262144 bytes at a time. The cases put a character, or the start of an invalid
# sequence, across the edges of the reads.
READ_SIZE = 262144

IMPORT_BAD_ROOT = "import Bad from \"./bad\"\n\ndef main() -> Void\nend\n"
SHARED_ROOT = "import Shared from \"../shared/x\"\n\ndef main() -> Void\n  puts(Shared.name())\nend\n"
SHARED_X = "export def name() -> String\n  return \"x\"\nend\n"


def env_arguments(env):
    arguments = ["--agentica-path=" + env["AGENTICA_PATH"], "--xdg-data-home=" + env["XDG_DATA_HOME"]]
    if "HOME" in env:
        arguments.append("--home=" + env["HOME"])
    return arguments


def function_body(body):
    return "def main() -> Void\n" + body + "end\n\n"


def big_comment():
    """A comment a little over 1 MiB, with a 4-, 3-, 2- and 4-byte character each cut by a read edge."""
    def filler(to_offset, so_far):
        return b"a" * (to_offset - so_far)

    return b"".join([
        b"# ", filler(READ_SIZE - 1, 2), "\U0001F600".encode(),
        filler(2 * READ_SIZE - 2, READ_SIZE + 3), "日".encode(),
        filler(3 * READ_SIZE - 1, 2 * READ_SIZE + 1), "é".encode(),
        filler(4 * READ_SIZE - 3, 3 * READ_SIZE + 1), "\U0001F600".encode(),
        b"a" * 100, b"\n"])


def invalid_utf8_cases():
    """(name, valid prefix, bad bytes, suffix). The span must start at the first byte of the bad sequence."""
    prefix = "# é日\U0001F600\ndef main() -> Void\n  puts(\"é".encode()
    suffix = b"\")\nend\n"
    return [
        ("a continuation byte alone", prefix, b"\x80", suffix),
        ("CRLF and a tab before the bad byte (CR and tab are one column, only LF starts a line)",
         b"# a\r\n\tx = \"\t", b"\xFF", b"\"\r\n"),
        ("a byte that never occurs", prefix, b"\xFF", suffix),
        ("a lead byte above F4", prefix, b"\xF5", suffix),
        ("an overlong two-byte form", prefix, b"\xC0\x80", suffix),
        ("an overlong three-byte form", prefix, b"\xE0\x80\x80", suffix),
        ("an overlong four-byte form", prefix, b"\xF0\x80\x80\x80", suffix),
        ("a surrogate", prefix, b"\xED\xA0\x80", suffix),
        ("a code point above U+10FFFF", prefix, b"\xF4\x90\x80\x80", suffix),
        ("a sequence cut short by an ASCII byte", prefix, b"\xE2\x82", suffix),
        ("a two-byte lead before a quote", prefix, b"\xC3", suffix),
        ("a truncated sequence at the end of the file", prefix + b"\")\n", b"\xE2\x82", b""),
        ("a lone lead byte at the end of the file", prefix + b"\")\n", b"\xC3", b""),
        ("a bad byte after the first read", b"# " + b"a" * (READ_SIZE + 10) + b"\n# \xC3\xA9\n", b"\xFF", suffix),
        ("a sequence whose first two bytes end the first read", b"# " + b"a" * (READ_SIZE - 4), b"\xE2\x82", b"a\n"),
        ("a lead byte cut off by the first read", b"# " + b"a" * (READ_SIZE - 3), b"\xE2", b"\x82a\n"),
    ]


def expected_position(prefix):
    text = prefix.decode("utf-8")
    lines = text.split("\n")
    column = len(lines[-1]) + 1
    return "%d:%d:%d-%d:%d:%d" % (len(text), len(lines), column, len(text) + 1, len(lines), column + 1)


def deep_files():
    """Trees as deep as the parser allows. Each ends in a name that the linker refuses (Nope.Thing), so that the
    diagnostic shows the walk reached the deepest node, and the legal variants are checked by their id ranges."""
    def bad_then(text):
        return function_body("  y = " + text + "\n")

    return {
        "chain-ok": bad_then("x" + repeat(" + x", 998)),
        "chain-bad": bad_then("Nope.Thing" + repeat(" + x", 998)),
        "method-bad": bad_then("Nope.Thing" + repeat(".f(1)", 997)),
        "nested-chains-ok": bad_then("x + (x + (x + (x" + repeat(" + x", 400) + ")))"),
        "nested-chains-bad": bad_then("x + (x + (x + (Nope.Thing" + repeat(" + x", 400) + ")))"),
        "nested-chains-deep-ok": bad_then(nested_chains(8, 900)),
        "nested-chains-limit-ok": bad_then(nested_chains(11, 900)),
        "nested-chains-deep-bad": bad_then("Nope.Thing + (" + nested_chains(7, 900) + ")" + repeat(" + x", 900)),
        "calls-bad": bad_then(repeat("f(", 900) + "Nope.Thing" + repeat(")", 900)),
        "lists-bad": bad_then(repeat("[", 990) + "Nope.Thing" + repeat("]", 990)),
        "types-bad": "def f(a: " + repeat("List[", 900) + "Nope.Thing" + repeat("]", 900) + ") -> Void\nend\n\n",
        "ifs-bad": function_body(repeat("  if x\n", 400) + "  y = Nope.Thing\n" + repeat("  end\n", 400)),
    }


def chain_files():
    files = {}
    for n in range(3000):
        if n < 2999:
            files["chain/m%d.agc" % n] = (
                "import Next from \"m%d\"\nexport def f%d() -> Int\n  return Next.f%d()\nend\n\n" % (n + 1, n, n + 1))
        else:
            files["chain/m%d.agc" % n] = "export def f%d() -> Int\n  return 1\nend\n\n" % n
    return files


def wide_files():
    files = {"wide/w%d.agc" % n: "export def g%d() -> Int\n  return %d\nend\n\n" % (n, n) for n in range(2000)}
    files["wide/root.agc"] = (
        "".join("import W%d from \"w%d\"\n" % (n, n) for n in range(2000))
        + "def main() -> Void\n  puts(W0.g0())\nend\n\n")
    return files


def cycle_files():
    return {"cycle/c%d.agc" % n: "import Next from \"c%d\"\n" % ((n + 1) % 1500) for n in range(1500)}


def broken_files():
    files = {}
    for n in range(1500):
        if n < 1499:
            files["broken/b%d.agc" % n] = (
                "import Next from \"b%d\"\nexport def f() -> Int\n  return Next.f()\nend\n\n" % (n + 1))
        else:
            files["broken/b%d.agc" % n] = "export def f() -> Int\n  return Nope.Thing\nend\n\n"
    return files


def ids_ranges(text):
    """The files of a `--ids` output as (name, first, next)."""
    return [(match.group(1), int(match.group(2)), int(match.group(3)))
            for match in re.finditer(r'^module "(.*)" first=(\d+) next=(\d+)$', text, flags=re.MULTILINE)]


def sizes_text(test, text, label):
    """The names and node counts of the id ranges of one link, one line each in name order, once the ranges are checked.

    The ids of a link are one numbering: the first file starts at 0 and each file starts where the one before it ended.
    A file takes as many ids as it has nodes, which is the size the Racket writer froze for it.
    """
    ranges = ids_ranges(text)
    test.assertTrue(ranges, "%s: no id ranges in:\n%s" % (label, text[:300]))
    test.assertEqual(ranges[0][1], 0, label)
    for earlier, later in zip(ranges, ranges[1:]):
        test.assertEqual(later[1], earlier[2], label)
    return "".join("%s %d\n" % (name, last - first) for name, first, last in sorted(ranges))


class ModulesFrozenTest(StageTestCase):
    ENTRY = "link.agc"
    STDLIB = True

    def link(self, specs, cwd, mode=None, stdlib=None):
        """Link each (env, root path) spec; gives the output of each by its root path.

        The std/ modules come from the stdlib/ of the freeze, or from `stdlib` (the live folder, for the goldens that
        track it).
        """
        arguments = ["--stdlib=%s" % (stdlib or self.stdlib)]
        if mode:
            arguments.append(mode)
        for env, root in specs:
            arguments += env_arguments(env) + [str(root)]
        return sections(self.run_stage(*arguments, cwd=cwd))

    def link_tree(self, files, root, mode=None, env=DEFAULT_ENV):
        """Write the files {path: text or bytes} into a fresh folder and link `root` (a path of the files)."""
        directory = self.make_temp_dir()
        write_files(directory, files)
        return self.link([(env, root)], directory, mode)[root]

    def link_trees(self, trees, mode=None):
        """Link several trees written side by side: {key: (files, root)}; gives {key: output}."""
        directory = self.make_temp_dir()
        for files, _ in trees.values():
            write_files(directory, files)
        outputs = self.link([(DEFAULT_ENV, root) for _, root in trees.values()], directory, mode)
        return {key: outputs[root] for key, (_, root) in trees.items()}

    def fixture_copy(self, name, destination):
        """A copy of a linker fixture with its links made, and its environment: Symbolic links are not kept in the
        repository (a checkout may drop or copy them), so a fixture lists them in fixture.links as `LINK TARGET`."""
        shutil.copytree(MODULE_FIXTURES / name, destination, symlinks=True)
        listing = destination / "fixture.links"
        if listing.exists():
            for line in listing.read_text(encoding="utf-8").splitlines():
                if line:
                    link, target = line.split(" ")
                    (destination / link).parent.mkdir(parents=True, exist_ok=True)
                    (destination / link).symlink_to(target)
        env = dict(DEFAULT_ENV)
        environment = destination / "fixture.env"
        if environment.exists():
            for line in environment.read_text(encoding="utf-8").splitlines():
                if line:
                    key, value = line.split("=", 1)
                    env[key] = value.replace("@/", str(destination.resolve()) + "/")
        return env

    def fixture_names(self):
        return sorted(path.name for path in MODULE_FIXTURES.iterdir() if path.is_dir())

    def test_every_fixture_has_a_golden_and_no_golden_is_left_over(self):
        self.fixture_goldens(MODULE_FIXTURES, self.fixture_names(), ".linked")

    def test_the_linker_matches_the_goldens_of_the_fixtures(self):
        goldens = self.fixture_goldens(MODULE_FIXTURES, self.fixture_names(), ".linked")
        directory = self.make_temp_dir()
        specs = [(self.fixture_copy(name, directory / name), str(directory / name / "root.agc")) for name in goldens]
        outputs = self.link(specs, directory, stdlib=ROOT / "stdlib")
        self.assert_goldens({name: outputs[root] for name, (_, root) in zip(goldens, specs)}, goldens, "linker fixtures")

    def test_the_std_modules_of_the_stdlib_folder_are_the_registry(self):
        # The registry of src/stdlib.rkt, frozen in modules/stdlib-registry.expected: a new std module is one more line.
        names = sorted("std/" + path.relative_to(ROOT / "stdlib").as_posix() for path in (ROOT / "stdlib").rglob("*.agc"))
        self.assert_golden("".join(name + "\n" for name in names), FROZEN / "modules" / "stdlib-registry.expected")

    def test_the_files_of_a_link_share_one_numbering_of_node_ids(self):
        names = ["diamond", "empty-modules", "every-node", "pkg-environment-first", "canonical-identities", "bdd-steps"]
        directory = self.make_temp_dir()
        specs = []
        for name in names:
            env = self.fixture_copy(name, directory / name)
            specs.append((env, str(directory / name / "root.agc")))
        outputs = self.link(specs, directory, "--ids")
        found = {}
        inputs = {}
        for name, (_, root) in zip(names, specs):
            found["ids-" + name] = sizes_text(self, outputs[root], name)
            self.assertGreater(len(ids_ranges(outputs[root])), 1, name)
            inputs["ids-" + name] = tree_listing(tree_files(MODULE_FIXTURES / name))
        self.assert_manifest(found, "modules/ids.sha256", inputs)

    def test_the_empty_files_of_a_link_take_ids_too(self):
        directory = self.make_temp_dir()
        env = self.fixture_copy("empty-modules", directory / "empty-modules")
        root = str(directory / "empty-modules" / "root.agc")
        names = [name for name, _, _ in ids_ranges(self.link([(env, root)], directory, "--ids")[root])]
        self.assertEqual(names, ["root.agc", "empty.agc", "imports_only.agc", "deep.agc", "after.agc"])

    def test_a_root_file_that_cannot_be_read_is_check_import_io_at_the_start_of_the_file(self):
        directory = self.make_temp_dir()
        root = str(directory / "missing.agc")
        output = self.link([(DEFAULT_ENV, root)], directory)[root]
        self.assertRegex(output, r"^ERROR CHECK-IMPORT-IO 0:1:1-0:1:1 ")

    def test_a_file_above_the_root_folder_is_printed_with_dotdot_parts(self):
        # Resolution allows "../", and the stored name of such a file keeps the .. part (35.4, "Source paths").
        output = self.link_tree({"above/app/root.agc": SHARED_ROOT, "above/shared/x.agc": SHARED_X}, "above/app/root.agc")
        self.assertIn('\n  module "../shared/x.agc"\n', output)
        self.assert_golden(output, FROZEN / "modules" / "above.expected")

    def test_an_entry_reached_through_a_symbolic_link_to_its_folder_is_named_from_the_real_folder(self):
        # The stored name comes from the canonical file, so a link in the way of the entry changes nothing.
        directory = self.make_temp_dir()
        write_files(directory, {"linked/real/app/root.agc": SHARED_ROOT, "linked/real/shared/x.agc": SHARED_X})
        (directory / "linked" / "linkapp").symlink_to(Path("real") / "app")
        root = "linked/linkapp/root.agc"
        output = self.link([(DEFAULT_ENV, root)], directory)[root]
        self.assertIn('\n  module "root.agc"\n', output)
        self.assertIn('\n  module "../shared/x.agc"\n', output)
        self.assert_golden(output, FROZEN / "modules" / "symlink.expected")

    def test_invalid_utf8_in_the_root_file_or_in_an_import_is_lex_invalid_utf8_at_its_first_bad_byte(self):
        trees = {}
        expected = {}
        inputs = {}
        for n, (name, prefix, bad, suffix) in enumerate(invalid_utf8_cases()):
            content = prefix + bad + suffix
            alone = {"root-%d/root.agc" % n: content}
            imported = {"import-%d/root.agc" % n: IMPORT_BAD_ROOT, "import-%d/bad.agc" % n: content}
            trees["utf8-%d-root" % n] = (alone, "root-%d/root.agc" % n)
            trees["utf8-%d-import" % n] = (imported, "import-%d/root.agc" % n)
            inputs["utf8-%d-root" % n] = tree_listing({"root.agc": content})
            inputs["utf8-%d-import" % n] = tree_listing({"root.agc": IMPORT_BAD_ROOT, "bad.agc": content})
            expected["utf8-%d-root" % n] = (name, expected_position(prefix), 'file="root.agc"')
            expected["utf8-%d-import" % n] = (name, expected_position(prefix), 'file="bad.agc"')
        outputs = self.link_trees(trees)
        self.assert_manifest(outputs, "modules/invalid-utf8.sha256", inputs)
        for key, (name, span, file) in expected.items():
            self.assertRegex(outputs[key], r'^ERROR LEX-INVALID-UTF8 %s "source file is not valid UTF-8" ' % re.escape(span), name)
            self.assertRegex(outputs[key], re.escape(file) + r"\n?$", name)

    def test_a_source_file_that_cannot_be_read_as_an_import_is_check_import_io(self):
        directory = self.make_temp_dir()
        write_files(directory, {"root.agc": IMPORT_BAD_ROOT})
        (directory / "bad.agc").mkdir()
        output = self.link([(DEFAULT_ENV, "root.agc")], directory)["root.agc"]
        self.assertRegex(output, r'^ERROR CHECK-IMPORT-IO [^ ]+ "cannot read import"')
        self.assert_golden(output, FROZEN / "modules" / "unreadable-import.expected")

    def test_a_valid_source_file_over_1_mib_links_as_the_root_and_as_an_import(self):
        comment = big_comment()
        self.assertGreater(len(comment), 1048576)
        program = b"def main() -> Void\n  puts(\"big\")\nend\n"
        alone = {"alone/root.agc": comment + program}
        imported = {
            "imported/big.agc": comment + b"export def one() -> Int\n  return 1\nend\n",
            "imported/root.agc": "import Big from \"./big\"\n\ndef main() -> Void\n  puts(Big.one().to_s)\nend\n"}
        outputs = self.link_trees({"big-alone": (alone, "alone/root.agc"), "big-imported": (imported, "imported/root.agc")})
        for key, text in outputs.items():
            self.assertFalse(text.startswith("ERROR"), key)
        inputs = {"big-alone": tree_listing({"root.agc": comment + program}),
                  "big-imported": tree_listing({"big.agc": imported["imported/big.agc"], "root.agc": imported["imported/root.agc"]})}
        self.assert_manifest(outputs, "modules/big.sha256", inputs)

    def test_the_user_library_root_falls_back_to_home_local_share_agentica_lib(self):
        # Racket's find-system-path ignores a replaced environment, so the HOME-based user root cannot be compared with
        # Racket in a hermetic way: the linker is given --home and no usable XDG_DATA_HOME (relative values are ignored).
        directory = self.make_temp_dir()
        write_files(directory, {
            "home/.local/share/agentica/lib/homelib.agc": "export def answer() -> Int\n  return 42\nend\n",
            "home-root/root.agc":
                "import Homelib from \"pkg/homelib\"\n\ndef main() -> Void\n  puts(Homelib.answer().to_s)\nend\n"})
        env = {"AGENTICA_PATH": "", "XDG_DATA_HOME": "relative/data", "HOME": str(directory / "home")}
        output = self.link([(env, "home-root/root.agc")], directory)["home-root/root.agc"]
        self.assertFalse(output.startswith("ERROR"), output)
        self.assertRegex(output, r'module "[^"]*homelib.agc"')

    @slow
    @timeout(1800)
    def test_corpus(self):
        directory = self.make_temp_dir()
        files = load_corpus("examples", "stdlib", "fixtures")
        # tests/fixtures/frontend/limits/limits.agc imports ../../../../compiler/..., so the snapshot of compiler/ is
        # written too, at the same place as in the repository, as the Racket writer had it. It is not a root.
        write_files(directory, dict(files, **load_corpus("compiler")))
        outputs = self.link([(DEFAULT_ENV, path) for path in sorted(files)], directory)
        self.assert_manifest(outputs, "modules/corpus.sha256", files)

    @slow
    @timeout(1800)
    def test_the_programs_of_the_site(self):
        programs = load_json("corpus/site-programs.json")
        self.assertGreater(len(programs), 100)
        files = {"site-%d" % n: text for n, text in enumerate(programs)}
        trees = {key: ({"site/block-%s.agc" % key[5:]: text}, "site/block-%s.agc" % key[5:]) for key, text in files.items()}
        self.assert_manifest(self.link_trees(trees), "modules/site.sha256", files)

    @slow
    @timeout(1800)
    def test_300_mutated_fixtures(self):
        directory = self.make_temp_dir()
        roots = {}
        inputs = {}
        for n, case in enumerate(load_json("modules/mutated.json")):
            target = directory / "mutated" / ("case-%d" % n)
            self.fixture_copy(case["fixture"], target)
            files = tree_files(target)
            for path, text in case["files"].items():
                (target / path).write_text(text, encoding="utf-8")
                files[path] = text.encode("utf-8")
            roots["case-%d" % n] = "mutated/case-%d/root.agc" % n
            # The links are not files; fixture_copy made them as the freeze did.
            inputs["case-%d" % n] = tree_listing(files)
        outputs = self.link([(DEFAULT_ENV, root) for root in roots.values()], directory)
        found = {key: outputs[root] for key, root in roots.items()}
        self.assert_manifest(found, "modules/mutated.sha256", inputs)
        errors = sum(1 for text in found.values() if text.startswith("ERROR"))
        self.assertTrue(30 < errors < 290, "%d of 300 mutated fixtures are errors" % errors)

    @slow
    @timeout(1800)
    def test_long_chains_of_files_link_with_one_numbering_of_ids(self):
        sets = {"chain": (chain_files(), "chain/m0.agc"), "wide": (wide_files(), "wide/root.agc"),
                "cycle": (cycle_files(), "cycle/c0.agc"), "broken": (broken_files(), "broken/b0.agc")}
        inputs = {key: tree_listing(files) for key, (files, _) in sets.items()}
        outputs = self.link_trees(sets)
        self.assert_manifest(outputs, "modules/large.sha256", inputs)
        self.assertRegex(outputs["cycle"], r"^ERROR CHECK-IMPORT-CYCLE")
        ids = self.link_trees({key: sets[key] for key in ("chain", "wide")}, "--ids")
        found = {key + "-ids": sizes_text(self, text, key) for key, text in ids.items()}
        self.assert_manifest(found, "modules/large-ids.sha256", {key + "-ids": inputs[key] for key in ("chain", "wide")})

    @slow
    @timeout(1800)
    def test_deep_trees_are_rewritten_as_deep_as_the_parser_lets_them_be(self):
        files = deep_files()
        trees = {"deep-" + name: ({"deep/%s.agc" % name: text}, "deep/%s.agc" % name) for name, text in files.items()}
        outputs = self.link_trees(trees, "--ids")
        found = {key: text if text.startswith("ERROR") else sizes_text(self, text, key) for key, text in outputs.items()}
        self.assert_manifest(found, "modules/deep.sha256", {"deep-" + name: text for name, text in files.items()})

    @slow
    @timeout(1800)
    def test_a_file_of_2000_declarations_links_in_linear_time(self):
        text = "".join("def f%d(a: Int) -> Int\n  return a + %d\nend\n\n" % (n, n) for n in range(2000))
        started = time.monotonic()
        output = self.link_tree({"flat.agc": text}, "flat.agc")
        self.assertLess(time.monotonic() - started, scaled(60))
        self.assert_manifest({"flat": output}, "modules/flat.sha256", {"flat": text})

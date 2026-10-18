"""What the tests of the Agentica front end share (tests/test_frontend_<stage>.py).

Each test compiles one stage of compiler/ with the product CLI, runs it on the VM over inputs and compares what it
prints with the frozen output of the original stage (tests/fixtures/frontend/frozen/, docs/future/18-front-end-language.md §18.7). The original stages wrote the frozen files once; tools/refreeze.py rewrites them from the Agentica
stages now.

The hashes of a manifest cover big outputs and big inputs. An input hash that differs means the Python side built a
different input than the original writer did, which is a test bug and not a front-end bug.
"""
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from collections import namedtuple
from pathlib import Path

from tests.agentica_test import FIXTURES, ROOT, TestCase, compile_agc, run_vm, scaled, vm_environment

FROZEN = FIXTURES / "frontend" / "frozen"

# tools/refreeze.py runs these tests with AGENTICA_REFREEZE=1: a comparison with a golden then rewrites the golden from the
# Agentica output instead of failing, and appends what changed, as one JSON line, to the file AGENTICA_REFREEZE_LOG. This is
# how the goldens are kept once the original stages that wrote them are gone.
def refreezing():
    """True while tools/refreeze.py runs the tests (read at each call, so a test can switch it)."""
    return os.environ.get("AGENTICA_REFREEZE", "") == "1"


# The stages read the environment of the pkg/ search when they are not given the flags; the original writers ran with
# no AGENTICA_PATH and a user data folder that does not exist, and so do the stages here.
HERMETIC_ENVIRONMENT = vm_environment({"AGENTICA_PATH": "", "XDG_DATA_HOME": "/nonexistent-agentica-xdg"})

# The default limit of one stage run over a corpus; a case that is big or slow passes its own.
STAGE_TIMEOUT = scaled(600)

Entry = namedtuple("Entry", "output_sha size input_sha key")


def sha256(data):
    """The hex SHA-256 of bytes or of text (UTF-8)."""
    return hashlib.sha256(data.encode("utf-8") if isinstance(data, str) else data).hexdigest()


def load_json(relative):
    with open(FROZEN / relative, encoding="utf-8") as handle:
        return json.load(handle)


def load_corpus(*names):
    """The snapshot files of frozen/corpus/<name>.json as one dict from path (relative to the repository) to text."""
    files = {}
    for name in names:
        files.update(load_json("corpus/%s.json" % name))
    return files


def read_manifest(relative):
    """The entries of a manifest: Entry(output_sha, size, input_sha, key), in the order of the file."""
    entries = []
    for line in (FROZEN / relative).read_text(encoding="utf-8").splitlines():
        output_sha, size, input_sha, key = line.split(" ", 3)
        entries.append(Entry(output_sha, int(size), input_sha, key))
    return entries


def write_files(directory, files):
    """Write path -> text (or bytes) below `directory`, creating folders."""
    for path, data in files.items():
        target = Path(directory) / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data.encode("utf-8") if isinstance(data, str) else data)


def sections(output):
    """The "== path" sections of a stage's output as {path: text}; the text keeps its final newline."""
    pieces = re.split(r"^== ", output, flags=re.MULTILINE)[1:]
    found = {}
    for piece in pieces:
        path, _, text = piece.partition("\n")
        found[path] = text
    return found


class GoldenTestCase(TestCase):
    """A test case that compares text with goldens, and rewrites them in refreeze mode (tools/refreeze.py)."""

    def rewrite_manifest(self, outputs, relative, entries, inputs, keys):
        """Refreeze mode of assert_manifest: write the manifest from the outputs and report the entries that changed."""
        old = {entry.key: entry for entry in entries}
        selected = set(old) | set(outputs) if keys is None else set(keys)
        rewritten, changed, added, removed = [], [], [], []
        for entry in entries:
            if entry.key not in selected:
                rewritten.append(entry)
            elif entry.key not in outputs:
                removed.append(entry.key)
            else:
                text = outputs[entry.key]
                input_sha = sha256(inputs[entry.key]) if inputs is not None else entry.input_sha
                new = Entry(sha256(text), len(text.encode("utf-8")), input_sha, entry.key)
                rewritten.append(new)
                if new != entry:
                    changed.append({"key": entry.key, "old": [entry.size, entry.output_sha[:12], entry.input_sha[:12]],
                                    "new": [new.size, new.output_sha[:12], new.input_sha[:12]]})
        for key in sorted(selected - set(old)):
            text = outputs[key]
            input_sha = sha256(inputs[key]) if inputs is not None else sha256("")
            rewritten.append(Entry(sha256(text), len(text.encode("utf-8")), input_sha, key))
            added.append(key)
        if changed or added or removed:
            (FROZEN / relative).write_text(
                "".join("%s %d %s %s\n" % (e.output_sha, e.size, e.input_sha, e.key) for e in rewritten), encoding="utf-8")
            report({"file": "frozen/" + relative, "changed": changed, "added": added, "removed": removed})

    def assert_golden(self, actual, path, label=None):
        """Compare text with the golden file at `path` (a Path); in refreeze mode, rewrite the golden."""
        path = Path(path)
        expected = path.read_bytes().decode("utf-8") if path.exists() else None
        if refreezing():
            if actual != expected:
                path.write_bytes(actual.encode("utf-8"))
                report({"file": shown(path), "diff": [expected or "", actual]})
            return
        self.assertEqual(actual, expected, label or str(path))

    def fixture_goldens(self, folder, stems, suffix):
        """The golden file of each stem in `stems`, as {stem: Path}: <folder>/<stem><suffix>.

        Every input has a golden and no golden is left over; in refreeze mode a missing golden is made by the caller's
        comparison and a leftover one is deleted.
        """
        folder = Path(folder)
        found = sorted(path.name[:-len(suffix)] for path in folder.iterdir() if path.name.endswith(suffix))
        if refreezing():
            for stem in sorted(set(found) - set(stems)):
                (folder / (stem + suffix)).unlink()
                report({"file": shown(folder / (stem + suffix)), "removed": True})
        else:
            self.assertEqual(found, sorted(stems), "the inputs and the %s goldens of %s" % (suffix, folder.name))
        return {stem: folder / (stem + suffix) for stem in stems}

    def fixture_pairs(self, folder, input_suffix, golden_suffix):
        """The goldens of the input files of a folder, as {input file name: Path of its golden}."""
        names = sorted(path.name for path in Path(folder).iterdir() if path.name.endswith(input_suffix))
        stems = {name[:-len(input_suffix)]: name for name in names}
        goldens = self.fixture_goldens(folder, list(stems), golden_suffix)
        return {stems[stem]: golden for stem, golden in goldens.items()}

    def assert_goldens(self, outputs, goldens, label):
        """Compare {name: text} with the golden file of each name ({name: Path}), naming every name that differs."""
        self.assertEqual(sorted(outputs), sorted(goldens), label)
        if refreezing():
            for name in sorted(goldens):
                self.assert_golden(outputs[name], goldens[name])
            return
        different = [name for name in sorted(goldens)
                     if outputs[name] != goldens[name].read_bytes().decode("utf-8")]
        self.assertEqual(different[:10], [], "%d of %d %s differ from their goldens" % (len(different), len(goldens), label))

    def assert_manifest(self, outputs, relative, inputs=None, keys=None):
        """Compare the outputs {key: text} with a manifest, key by key.

        `inputs` ({key: text or bytes}), when given, are also checked against the input hashes of the manifest;
        `keys` limits the check to those entries. Without `keys`, the outputs and the manifest must name the same inputs,
        so a path that the test stops listing is not a silent loss of coverage.
        """
        problems = []
        checked = 0
        entries = read_manifest(relative)
        if refreezing():
            self.rewrite_manifest(outputs, relative, entries, inputs, keys)
            return
        if keys is None:
            self.assertEqual(sorted(outputs), sorted(entry.key for entry in entries), relative)
        for entry in entries:
            if keys is not None and entry.key not in keys:
                continue
            checked += 1
            if inputs is not None and sha256(inputs[entry.key]) != entry.input_sha:
                problems.append("%s: the input is not the one the original writer used" % entry.key)
            text = outputs.get(entry.key)
            if text is None:
                problems.append("%s: no output" % entry.key)
            elif sha256(text) != entry.output_sha:
                problems.append("%s: the output differs from the frozen one (%d bytes, frozen %d), it starts with:\n%s" % (
                    entry.key, len(text.encode("utf-8")), entry.size, text[:300]))
        self.assertGreater(checked, 0, relative)
        self.assertEqual(problems[:5], [], "%d of %d entries of %s differ" % (len(problems), checked, relative))


class StageTestCase(GoldenTestCase):
    """A test case over one stage of compiler/: ENTRY is the file below compiler/ that is compiled once for the class."""

    ENTRY = None
    # A stage that finds the std/ modules in a folder (--stdlib=DIR) gets the stdlib/ of the freeze in cls.stdlib.
    STDLIB = False
    bytecode = None

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        directory = Path(tempfile.mkdtemp(prefix="agentica-frontend-"))
        cls.addClassCleanup(shutil.rmtree, directory, ignore_errors=True)
        cls.stage_dir = directory
        cls.bytecode = compile_agc(ROOT / "compiler" / cls.ENTRY, directory / "stage.agcb")
        if cls.STDLIB:
            write_files(directory, load_corpus("stdlib"))
            cls.stdlib = directory / "stdlib"

    def corpus_dir(self, *names):
        """A fresh folder with the snapshot files of the corpora `names` at their paths; removed after the test."""
        directory = self.make_temp_dir("agentica-corpus-")
        write_files(directory, load_corpus(*names))
        return directory

    def run_stage(self, *arguments, flags=(), cwd=None, timeout=STAGE_TIMEOUT):
        """Run the stage with the arguments; it must exit 0 and print nothing on stderr. Gives its stdout."""
        result = run_vm(self.bytecode, *flags, args=arguments, cwd=cwd, env=HERMETIC_ENVIRONMENT, timeout=timeout)
        self.assertEqual(result.code, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def run_sections(self, paths, *before, flags=(), cwd=None, timeout=STAGE_TIMEOUT):
        """Run the stage over the paths (after the arguments `before`); gives the output of each by its path."""
        return sections(self.run_stage(*before, *paths, flags=flags, cwd=cwd, timeout=timeout))

    def run_cases(self, cases, *before, flags=(), timeout=STAGE_TIMEOUT, folder="cases"):
        """Write the programs {key: text} as <folder>/<key>.agc into a fresh folder and run the stage over them.

        Gives {key: output}. `before` are the arguments the stage takes before the paths.
        """
        directory = self.make_temp_dir()
        write_files(directory, {"%s/%s.agc" % (folder, key): text for key, text in cases.items()})
        paths = {key: "%s/%s.agc" % (folder, key) for key in cases}
        if self.STDLIB:
            before = ("--stdlib=%s" % self.stdlib,) + before
        outputs = self.run_sections(sorted(paths.values()), *before, flags=flags, cwd=directory, timeout=timeout)
        return {key: outputs[path] for key, path in paths.items()}

def fixture_roots(folder):
    """{fixture name: path of its program relative to the repository} for a fixture folder of the repository: NAME.agc, or
    NAME/root.agc for a folder."""
    roots = {}
    for path in sorted(Path(folder).iterdir()):
        relative = path.relative_to(ROOT).as_posix()
        if path.is_dir():
            roots[path.name] = relative + "/root.agc"
        elif path.suffix == ".agc":
            roots[path.stem] = relative
    return roots


def shown(path):
    """A path as the refreeze report names it: relative to the repository when it is inside."""
    path = Path(path)
    return str(path.relative_to(ROOT)) if path.is_relative_to(ROOT) else str(path)


def report(record):
    """Tell tools/refreeze.py what a refreeze changed: one JSON line in AGENTICA_REFREEZE_LOG, or on stderr."""
    line = json.dumps(record)
    log = os.environ.get("AGENTICA_REFREEZE_LOG")
    if log:
        with open(log, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    else:
        print("refreeze: " + line, file=sys.stderr)


def tree_listing(files):
    """The text whose hash stands for a whole input: each path and the hash of its content, one line each, in path order.

    `files` maps a path (relative to the root of the input) to text or bytes. The original writer
    that froze the manifests wrote the same text.
    """
    return "".join("%s %s\n" % (path, sha256(files[path])) for path in sorted(files))


def tree_files(directory):
    """The files below a folder as {relative path: bytes}, without links and without going through them."""
    directory = Path(directory)
    found = {}
    for current, folders, names in os.walk(directory):
        folders[:] = [name for name in folders if not (Path(current) / name).is_symlink()]
        for name in names:
            path = Path(current) / name
            if not path.is_symlink():
                found[path.relative_to(directory).as_posix()] = path.read_bytes()
    return found

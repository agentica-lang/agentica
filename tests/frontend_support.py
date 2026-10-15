"""What the tests of the Agentica front end share (tests/test_frontend_<stage>.py).

Each test compiles one stage of compiler/ with the product CLI, runs it on the VM over inputs and compares what it
prints with the frozen output of the Racket stage (tests/fixtures/frontend/frozen/, docs/future/35-self-hosting.md,
35.10, phase 3). The frozen files are written by `make frontend-freeze` while the Racket stages exist; see
tests/frontend-freeze-common.rkt for their layout.

The hashes of a manifest cover big outputs and big inputs. An input hash that differs means the Python side built a
different input than the Racket writer did, which is a test bug and not a front-end bug.
"""
import hashlib
import json
import os
import re
import shutil
import tempfile
from collections import namedtuple
from pathlib import Path

from tests.agentica_test import FIXTURES, ROOT, TestCase, compile_agc, run_vm, vm_environment

FROZEN = FIXTURES / "frontend" / "frozen"

# The stages read the environment of the pkg/ search when they are not given the flags; the Racket writers ran with no
# AGENTICA_PATH and a user data folder that does not exist, and so do the stages here.
HERMETIC_ENVIRONMENT = vm_environment({"AGENTICA_PATH": "", "XDG_DATA_HOME": "/nonexistent-agentica-xdg"})

# The default limit of one stage run over a corpus; a case that is big or slow passes its own.
STAGE_TIMEOUT = 600

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


class StageTestCase(TestCase):
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

    def assert_manifest(self, outputs, relative, inputs=None, keys=None):
        """Compare the outputs {key: text} with a manifest, key by key.

        `inputs` ({key: text or bytes}), when given, are also checked against the input hashes of the manifest;
        `keys` limits the check to those entries. Without `keys`, the outputs and the manifest must name the same inputs,
        so a path that the test stops listing is not a silent loss of coverage.
        """
        problems = []
        checked = 0
        entries = read_manifest(relative)
        if keys is None:
            self.assertEqual(sorted(outputs), sorted(entry.key for entry in entries), relative)
        for entry in entries:
            if keys is not None and entry.key not in keys:
                continue
            checked += 1
            if inputs is not None and sha256(inputs[entry.key]) != entry.input_sha:
                problems.append("%s: the input is not the one the Racket writer used" % entry.key)
            text = outputs.get(entry.key)
            if text is None:
                problems.append("%s: no output" % entry.key)
            elif sha256(text) != entry.output_sha:
                problems.append("%s: the output differs from the frozen one (%d bytes, frozen %d), it starts with:\n%s" % (
                    entry.key, len(text.encode("utf-8")), entry.size, text[:300]))
        self.assertGreater(checked, 0, relative)
        self.assertEqual(problems[:5], [], "%d of %d entries of %s differ" % (len(problems), checked, relative))


def tree_listing(files):
    """The text whose hash stands for a whole input: each path and the hash of its content, one line each, in path order.

    `files` maps a path (relative to the root of the input) to text or bytes. tests/frontend-freeze-common.rkt
    (tree-listing) writes the same text.
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

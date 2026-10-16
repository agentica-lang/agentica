"""Stack traces on stderr.

Each stack-trace fixture of tests/fixtures/vm/ is run on the VM in the plain, --ai and --json formats, and its stderr
(with tests/fixtures/ written as @fixtures/) must equal the sidecar `<name>.stack.<format>` next to the program.
`python3 -m tests.test_vm_stack` rewrites the sidecars (make goldens). AGENTICA_FIXTURES limits the run to the named
fixtures.
"""
import sys
import tempfile
from pathlib import Path

from tests.agentica_test import FIXTURES, compile_agc, vm_binary
from tests.vm_diff_support import (
    FIXTURE_TOKEN, FIXTURES_PREFIX, Fixture, VmCase, check_fixture_filter, fixture_selected,
    run_vm_process)

CASES = [
    ("vm/stack-trace-nested", []),
    ("vm/stack-trace-main", []),
    ("vm/stack-trace-import", []),
    ("vm/constants-error", []),
    ("vm/stack-trace-block", []),
    ("vm/stack-trace-tail", []),
    ("vm/stack-trace-recursion", []),
    ("vm/stack-trace-mutual", []),
    ("vm/stack-trace-task", []),
    ("vm/stack-trace-big", []),
    ("vm/stack-trace-prelude", []),
    ("vm/prelude-error-slice", []),
    ("vm/prelude-error-tail", []),
    ("vm/prelude-error-nested", []),
    ("vm/prelude-error-sum", []),
    ("vm/prelude-error-callback", []),
    ("vm/step-limited/stack-trace-step-limit", ["--max-steps", "500"]),
    ("vm/step-limited/stack-trace-task-step-limit", ["--max-steps", "500"]),
    ("vm/step-limited/stack-trace-prelude-step-limit", ["--max-steps", "500"]),
]
STYLES = [("plain", []), ("ai", ["--ai"]), ("json", ["--json"])]


def sidecar(name, style):
    return FIXTURES / ("%s.stack.%s" % (name, style))


def compile_fixture(name, work):
    program = FIXTURES / (name + ".agc")
    return program, compile_agc(program, Path(work) / "program.agcb")


def stderr_of(program, bytecode, extra, options, work):
    """The stderr of one fixture run; the exit code must be 1."""
    status, _stdout, stderr = run_vm_process(
        Fixture(), [*extra, *options, "--source-root", str(program.parent)], bytecode, [], cwd=work)
    if status != 1:
        raise AssertionError("%s: exit %r, stderr: %s" % (program.stem, status, stderr))
    return stderr.replace(FIXTURES_PREFIX, FIXTURE_TOKEN)


def selected_cases():
    return [(name, extra) for name, extra in CASES if fixture_selected(Path(name).name)]


def _method(name, extra):
    def method(self):
        # One compile per fixture; the three formats only change the VM options.
        work = self.work_dir()
        program, bytecode = compile_fixture(name, work)
        for style, options in STYLES:
            with self.subTest(style=style):
                text = stderr_of(program, bytecode, extra, options, work)
                self.assertEqual(text, sidecar(name, style).read_text(encoding="utf-8"))

    method.__doc__ = "%s in the plain, --ai and --json formats" % name
    return method


def _methods():
    return {"test_%s" % Path(name).name.replace("-", "_"): _method(name, extra) for name, extra in selected_cases()}


def _set_up_class(cls):
    super(cls, cls).setUpClass()
    vm_binary()


StackTraces = type("StackTraces", (VmCase,), {**_methods(), "setUpClass": classmethod(_set_up_class)})


def write_sidecars():
    check_fixture_filter()
    vm_binary()
    with tempfile.TemporaryDirectory(prefix="agentica-stack-") as work:
        for name, extra in selected_cases():
            program, bytecode = compile_fixture(name, Path(work).resolve())
            for style, options in STYLES:
                text = stderr_of(program, bytecode, extra, options, Path(work).resolve())
                sidecar(name, style).write_text(text, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        sys.stderr.write("usage: python3 -m tests.test_vm_stack\n")
        sys.exit(2)
    write_sidecars()

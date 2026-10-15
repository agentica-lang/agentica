"""Stack traces on stderr (ported from vm-stack-test.rkt).

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
    ("vm/step-limited/stack-trace-step-limit", ["--max-steps", "500"]),
    ("vm/step-limited/stack-trace-task-step-limit", ["--max-steps", "500"]),
]
STYLES = [("plain", []), ("ai", ["--ai"]), ("json", ["--json"])]


def sidecar(name, style):
    return FIXTURES / ("%s.stack.%s" % (name, style))


def stderr_of(name, extra, options, work):
    """The stderr of one fixture run; the exit code must be 1."""
    program = FIXTURES / (name + ".agc")
    bytecode = compile_agc(program, Path(work) / "program.agcb")
    status, _stdout, stderr = run_vm_process(
        Fixture(), [*extra, *options, "--source-root", str(program.parent)], bytecode, [], cwd=work)
    if status != 1:
        raise AssertionError("%s: exit %r, stderr: %s" % (name, status, stderr))
    return stderr.replace(FIXTURES_PREFIX, FIXTURE_TOKEN)


def selected_cases():
    return [(name, extra) for name, extra in CASES if fixture_selected(Path(name).name)]


def _method(name, extra, style, options):
    def method(self):
        text = stderr_of(name, extra, options, self.work_dir())
        self.assertEqual(text, sidecar(name, style).read_text(encoding="utf-8"))

    method.__doc__ = "%s in the %s format" % (name, style)
    return method


def _methods():
    methods = {}
    for name, extra in selected_cases():
        for style, options in STYLES:
            methods["test_%s_%s" % (Path(name).name.replace("-", "_"), style)] = _method(name, extra, style, options)
    return methods


def _set_up_class(cls):
    super(cls, cls).setUpClass()
    vm_binary()


StackTraces = type("StackTraces", (VmCase,), {**_methods(), "setUpClass": classmethod(_set_up_class)})


def write_sidecars():
    check_fixture_filter()
    vm_binary()
    with tempfile.TemporaryDirectory(prefix="agentica-stack-") as work:
        for name, extra in selected_cases():
            for style, options in STYLES:
                text = stderr_of(name, extra, options, Path(work).resolve())
                sidecar(name, style).write_text(text, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        sys.stderr.write("usage: python3 -m tests.test_vm_stack\n")
        sys.exit(2)
    write_sidecars()

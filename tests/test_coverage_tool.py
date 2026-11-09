"""tools/coverage.py, the report of `make coverage`: a small C program in a vm/ tree, built with gcc's and with clang's
coverage, gives an LCOV report of vm/ alone, without vm/third_party and vm/tests, with the counts of the run."""
import os
import shutil
import subprocess
import sys

from tests.agentica_test import ROOT, tool

SOURCES = {
    "vm/core.c": "int used(int n) {\n  if (n > 100)\n    return 0;\n  return n + 1;\n}\n\nint unused(void) {\n  return 7;\n}\n",
    "vm/third_party/lib.c": "int lib(int n) {\n  return n * 2;\n}\n",
    "vm/tests/core_test.c": "int used(int n);\nint lib(int n);\n\nint main(void) {\n  return used(1) + lib(1) == 4 ? 0 : 1;\n}\n",
}


def tree(tmp_path):
    for name, text in SOURCES.items():
        (tmp_path / name).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / name).write_text(text)
    (tmp_path / "obj").mkdir()


def build(tmp_path, compiler, flags):
    """Compile each source into obj/ and link obj/core_test; returns its path."""
    objects = []
    for name in SOURCES:
        out = tmp_path / "obj" / (os.path.basename(name)[:-2] + ".o")
        subprocess.run([compiler, *flags, "-O0", "-c", name, "-o", str(out)], cwd=tmp_path, check=True)
        objects.append(str(out))
    binary = tmp_path / "obj" / "core_test"
    subprocess.run([compiler, *flags, *objects, "-o", str(binary)], cwd=tmp_path, check=True)
    return binary


def report(tmp_path, *arguments):
    subprocess.run([sys.executable, str(ROOT / "tools" / "coverage.py"), *arguments], cwd=tmp_path, check=True,
                   timeout=120)
    return (tmp_path / "lcov.info").read_text()


def assert_core_only(text):
    files = [line[3:] for line in text.splitlines() if line.startswith("SF:")]
    assert files == ["vm/core.c"], text
    lines = dict(line[3:].split(",")[:2] for line in text.splitlines() if line.startswith("DA:"))
    assert lines["4"] == "1" and lines["3"] == "0" and lines["8"] == "0", text
    functions = dict(line[5:].split(",")[::-1] for line in text.splitlines() if line.startswith("FNDA:"))
    assert functions == {"used": "1", "unused": "0"}, text


def test_the_gcc_report_has_vm_alone_with_the_counts_of_the_run(tmp_path):
    gcc = tool("gcc")
    major = subprocess.run([gcc, "-dumpversion"], capture_output=True, text=True, check=True).stdout.split(".")[0]
    gcov = shutil.which("gcov-" + major) or tool("gcov")
    tree(tmp_path)
    binary = build(tmp_path, gcc, ["--coverage"])
    subprocess.run([str(binary)], cwd=tmp_path, check=True)
    assert_core_only(report(tmp_path, "gcc", gcov, "obj", "lcov.info"))


def test_the_clang_report_has_vm_alone_with_the_counts_of_the_run(tmp_path):
    clang = tool("clang")
    profdata, cov = (subprocess.run([clang, "-print-prog-name=" + name], capture_output=True, text=True,
                                    check=True).stdout.strip() for name in ("llvm-profdata", "llvm-cov"))
    tree(tmp_path)
    binary = build(tmp_path, clang, ["-fprofile-instr-generate", "-fcoverage-mapping"])
    (tmp_path / "profraw").mkdir()
    subprocess.run([str(binary)], cwd=tmp_path, check=True,
                   env={**os.environ, "LLVM_PROFILE_FILE": str(tmp_path / "profraw" / "%m.profraw")})
    assert_core_only(report(tmp_path, "clang", tool(profdata), tool(cov), "profraw", "lcov.info", str(binary)))

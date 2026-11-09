#!/usr/bin/env python3
"""Write the LCOV report of `make coverage` (mk/vm-test.mk) for the C VM: the files of vm/ without vm/third_party and
vm/tests, with their lines and functions.

    coverage.py gcc GCOV OBJ_DIR OUT                      the .gcda files under OBJ_DIR, read with GCOV (gcc's)
    coverage.py clang PROFDATA COV PROFRAW_DIR OUT BIN... the raw profiles of PROFRAW_DIR, merged by PROFDATA (llvm-profdata)
                                                          and exported by COV (llvm-cov) over the binaries BIN

Run it from the root of the checkout: the paths in the report are relative to it, as the build compiles them.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

# gcov reads this many .gcda files per call.
BATCH = 64


def counted(path):
    """Whether the report has PATH (as the compiler names it, relative to the checkout or absolute)."""
    parts = Path(path).parts
    if parts and Path(path).is_absolute():
        root = Path.cwd().parts
        if parts[:len(root)] != root:
            return False
        parts = parts[len(root):]
    return len(parts) >= 2 and parts[0] == "vm" and parts[1] not in ("third_party", "tests")


def merge_gcov(documents):
    """The lines and functions of the counted files in gcov's JSON DOCUMENTS (one per .gcda): {path: (lines, functions)}
    with lines {number: count} and functions {name: (first line, count)}. A header's inline code shows up in several
    documents, so the counts add up."""
    files = {}
    for document in documents:
        for entry in document["files"]:
            if not counted(entry["file"]):
                continue
            lines, functions = files.setdefault(entry["file"], ({}, {}))
            for line in entry["lines"]:
                lines[line["line_number"]] = lines.get(line["line_number"], 0) + line["count"]
            for function in entry["functions"]:
                first, count = functions.get(function["name"], (function["start_line"], 0))
                functions[function["name"]] = (first, count + function["execution_count"])
    return files


def lcov(files):
    """The LCOV text of FILES, as merge_gcov returns them, sorted by path, line and name."""
    out = []
    for path in sorted(files):
        lines, functions = files[path]
        out.append("TN:\nSF:%s\n" % path)
        for name, (first, _) in sorted(functions.items(), key=lambda item: (item[1][0], item[0])):
            out.append("FN:%d,%s\n" % (first, name))
        for name, (_, count) in sorted(functions.items(), key=lambda item: (item[1][0], item[0])):
            out.append("FNDA:%d,%s\n" % (count, name))
        out.append("FNF:%d\nFNH:%d\n" % (len(functions), sum(1 for _, count in functions.values() if count)))
        for number in sorted(lines):
            out.append("DA:%d,%d\n" % (number, lines[number]))
        out.append("LF:%d\nLH:%d\nend_of_record\n" % (len(lines), sum(1 for count in lines.values() if count)))
    return "".join(out)


def gcc_report(gcov, obj_dir, out):
    data = sorted(str(path) for path in Path(obj_dir).rglob("*.gcda"))
    if not data:
        sys.exit("coverage.py: no .gcda file under %s: did the tests run on the COVERAGE=1 build?" % obj_dir)
    documents = []
    for start in range(0, len(data), BATCH):
        # gcov's warnings (a stale .gcda, a missing source) go to stderr, shown as they come; an error fails here.
        run = subprocess.run([gcov, "--json-format", "--stdout", *data[start:start + BATCH]], check=True,
                             stdout=subprocess.PIPE, text=True)
        documents += [json.loads(line) for line in run.stdout.splitlines() if line.strip()]
    Path(out).write_text(lcov(merge_gcov(documents)), encoding="utf-8")


def clang_report(profdata, cov, profraw_dir, out, binaries):
    raw = sorted(str(path) for path in Path(profraw_dir).glob("*.profraw"))
    if not raw:
        sys.exit("coverage.py: no .profraw file in %s: did the tests run on the COVERAGE=1 build?" % profraw_dir)
    with tempfile.TemporaryDirectory() as scratch:
        merged = str(Path(scratch) / "merged.profdata")
        subprocess.run([profdata, "merge", "-sparse", "-o", merged, *raw], check=True)
        objects = [word for binary in binaries[1:] for word in ("-object", binary)]
        run = subprocess.run([cov, "export", "-format=lcov", "-instr-profile", merged, binaries[0], *objects,
                              "-ignore-filename-regex=(^|/)vm/(third_party|tests)/"],
                             check=True, stdout=subprocess.PIPE, text=True)
    records = [record for record in run.stdout.split("end_of_record\n") if record.strip()]
    root = "SF:%s/" % Path.cwd()
    kept = [record.replace(root, "SF:", 1) + "end_of_record\n" for record in records if counted(source_of(record))]
    Path(out).write_text("".join(kept), encoding="utf-8")


def source_of(record):
    """The SF: path of one LCOV record."""
    return next(line[3:] for line in record.splitlines() if line.startswith("SF:"))


def main(argv):
    if len(argv) == 4 and argv[0] == "gcc":
        gcc_report(*argv[1:])
    elif len(argv) >= 6 and argv[0] == "clang":
        clang_report(argv[1], argv[2], argv[3], argv[4], argv[5:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])

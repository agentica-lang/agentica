"""The cost of one native call (#1149): a short call of a native module against an extern `def` (libffi), a
`compute def` and a plain Agentica call, in ns per call with the loop included, through dist/agentica.

`make bench-native` (or `python3 benchmarks/native/run.py --runs 5`) builds tests/fixtures/native/module_demo.c with
the system C compiler and times one program per case, `--runs` times, printing the median. Until the language has
`extern module` (part B of #1149), the module program is an extern `def add` compiled to bytecode whose signature
constant is then rewritten into the one of the module's `add`, which the VM binds through vm/native_module.c.
"""
import argparse
import os
import platform
import statistics
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXE = ROOT / "dist" / ("agentica.exe" if os.name == "nt" else "agentica")
DEMO = ROOT / "tests" / "fixtures" / "native" / "module_demo.c"
MACOS = platform.system() == "Darwin"
LIBC = "ucrtbase.dll" if os.name == "nt" else "libSystem.B.dylib" if MACOS else "libc.so.6"

PROGRAM = """extern "{library}"
  {extern}
end

def plain_add(a: Int, b: Int) -> Int
  return a + b
end

def main() -> Void
  n = {count}
  total = 0
  i = 0
  started = Time.monotonic_ns()
  while i < n
    total += {call}
    i += 1
  end
  elapsed = Time.monotonic_ns() - started
  puts("#{{elapsed / n}} #{{total}}")
end
"""

# name, calls, the extern line, the call in the loop, and whether the program's `add` becomes the module's.
CASES = [
    ("plain Agentica call", 1_000_000, "def labs(n: C.Long) -> C.Long", "plain_add(i, 1)", False),
    ("short native call", 1_000_000, "def add(a: C.Int64, b: C.Int64) -> C.Int64", "add(i, 1)", True),
    ("extern def (labs)", 1_000_000, "def labs(n: C.Long) -> C.Long", "labs(0 - i)", False),
    ("compute def (llabs)", 20_000, "compute def llabs(n: C.Int64) -> C.Int64", "llabs(0 - i)", False),
]


def build_module(folder):
    name = "module_demo.dll" if os.name == "nt" else "libmodule_demo.dylib" if MACOS else "libmodule_demo.so"
    kind = ["-shared"] if os.name == "nt" else ["-dynamiclib"] if MACOS else ["-shared", "-fPIC"]
    out = folder / name
    subprocess.run([os.environ.get("CC", "cc"), *kind, "-O2", "-o", str(out), str(DEMO)], check=True)
    return out


def as_module(bytecode, library):
    """BYTECODE with the signature constant of the extern `add` (a u32 length, then the text) made the module's."""
    old = ("lll add " + library).encode()
    new = ("module (Int, Int) -> Int add " + library).encode()
    framed = struct.pack("<I", len(old)) + old
    if bytecode.count(framed) != 1:
        sys.exit("the signature of add is not in the bytecode once: the lowering of extern functions changed")
    return bytecode.replace(framed, struct.pack("<I", len(new)) + new)


def program(folder, case, module):
    name, count, extern, call, rewrite = case
    library = str(module) if rewrite else LIBC
    source = folder / "bench.agc"
    source.write_text(PROGRAM.format(library=library.replace("\\", "\\\\"), extern=extern, count=count, call=call))
    compiled = folder / ("%s.agcb" % name.split()[0])
    subprocess.run([str(EXE), "compile", str(source), "-o", str(compiled)], check=True)
    if rewrite:
        compiled.write_bytes(as_module(compiled.read_bytes(), library))
    return compiled


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", type=int, default=5)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp)
        module = build_module(folder)
        for case in CASES:
            compiled = program(folder, case, module)
            samples = []
            for _ in range(args.runs):
                out = subprocess.run([str(EXE), "run", "--", str(compiled)], check=True, capture_output=True, text=True)
                samples.append(int(out.stdout.split()[0]))
            print("%-22s %8d ns per call (median of %d, %d calls)" % (case[0], statistics.median(samples), args.runs,
                                                                     case[1]))


if __name__ == "__main__":
    main()

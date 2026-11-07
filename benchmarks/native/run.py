"""The cost of one native call (#1149): a short call of a native module against an extern `def` (libffi), a
`compute def` and a plain Agentica call, and 1000 structs built by one module call against 1000 extern calls, in ns per
call with the loop included, through dist/agentica.

`make bench-native` (or `python3 benchmarks/native/run.py --runs 5`) builds tests/fixtures/native/module_demo.c with
the system C compiler and times one program per case, `--runs` times, printing the median. The program declares the
module's `add` and `points` in an `extern module` block and libc's `labs` and `llabs` in an extern block.
"""
import argparse
import os
import platform
import statistics
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXE = ROOT / "dist" / ("agentica.exe" if os.name == "nt" else "agentica")
DEMO = ROOT / "tests" / "fixtures" / "native" / "module_demo.c"
MACOS = platform.system() == "Darwin"
LIBC = "ucrtbase.dll" if os.name == "nt" else "libSystem.B.dylib" if MACOS else "libc.so.6"

PROGRAM = """struct Point
  x: Int
  y: Int
end

extern "{libc}"
  def labs(n: C.Long) -> C.Long
  compute def llabs(n: C.Int64) -> C.Int64
end

extern module "{module}"
  def add(a: Int, b: Int) -> Int
  def points(n: Int) -> List[Point]
end

def plain_add(a: Int, b: Int) -> Int
  return a + b
end

def extern_points(n: Int) -> Int
  made: List[Point] = []
  k = 0
  while k < n
    made = made.push(Point(x: labs(0 - k), y: 2 * k))
    k += 1
  end

  return made.size
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

# name, calls, the call in the loop.
CASES = [
    ("plain Agentica call", 1_000_000, "plain_add(i, 1)"),
    ("short native call", 1_000_000, "add(i, 1)"),
    ("extern def (labs)", 1_000_000, "labs(0 - i)"),
    ("compute def (llabs)", 20_000, "llabs(0 - i)"),
    ("1000 structs, 1 module call", 2_000, "points(1000).size"),
    ("1000 structs, 1000 extern calls", 2_000, "extern_points(1000)"),
]


def build_module(folder):
    name = "module_demo.dll" if os.name == "nt" else "libmodule_demo.dylib" if MACOS else "libmodule_demo.so"
    kind = ["-shared"] if os.name == "nt" else ["-dynamiclib"] if MACOS else ["-shared", "-fPIC"]
    out = folder / name
    subprocess.run([os.environ.get("CC", "cc"), *kind, "-O2", "-o", str(out), str(DEMO)], check=True)
    return out


def program(folder, case, module):
    _, count, call = case
    source = folder / "bench.agc"
    text = PROGRAM.format(libc=LIBC, module=str(module).replace("\\", "\\\\"), count=count, call=call)
    source.write_text(text)
    compiled = folder / ("case%d.agcb" % CASES.index(case))
    subprocess.run([str(EXE), "compile", str(source), "-o", str(compiled)], check=True)
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
            print("%-32s %9d ns per call (median of %d, %d calls)" % (case[0], statistics.median(samples), args.runs,
                                                                      case[1]))


if __name__ == "__main__":
    main()

import os
import sys
import tempfile


def main(scale: int) -> None:
    lines = 300000 * scale
    directory = os.environ.get("TMPDIR", tempfile.gettempdir())
    path = os.path.join(directory, f"agentica-bench-read-lines-{os.getpid()}.txt")
    with open(path, "w") as out:
        for i in range(lines):
            out.write(f"|-DeclRefExpr 0x{i} <line:{i}:{i % 80}> 'int' lvalue Var 'x'\n")
    count = 0
    total = 0
    with open(path) as source:
        for line in source:
            count += 1
            total += len(line.rstrip("\n"))
    os.remove(path)
    print(f"read-lines {count} {total}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)

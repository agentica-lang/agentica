import os
import sys
import tempfile


def line_of(i: int) -> str:
    match i % 6:
        case 0:
            return "{"
        case 1:
            return f'  "id": "0x{i}",'
        case 2:
            return '  "kind": "CallExpr",' if i % 12 == 2 else '  "kind": "DeclRefExpr",'
        case 3:
            return '  "inner": ['
        case 4:
            return "  ]"
        case _:
            return "}"


def calls_in(lines: list[str]) -> int:
    n = 0
    for line in lines:
        text = line.strip()
        if text.startswith('"kind": "CallExpr"') or text == "}":
            n += 1
    return n


def main(scale: int) -> None:
    count = 300000 * scale
    directory = os.environ.get("TMPDIR", tempfile.gettempdir())
    path = os.path.join(directory, f"agentica-bench-line-scan-{os.getpid()}.json")
    with open(path, "w") as out:
        for i in range(count):
            out.write(line_of(i) + "\n")
    with open(path) as source:
        lines = [line.rstrip("\n") for line in source]
    found = sum(calls_in(lines) for _ in range(5))
    calls = depth = 0
    with open(path) as source:
        for line in source:
            line = line.rstrip("\n")
            if line.endswith("{"):
                depth += 1
            elif line.strip().startswith('"kind": "CallExpr"'):
                calls += 1
    os.remove(path)
    print(f"line-scan {len(lines)} {found} {calls} {depth}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)

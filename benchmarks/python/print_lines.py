import sys


def main(scale: int) -> None:
    lines = 200000 * scale
    out = sys.stdout
    for i in range(lines):
        out.write(f"line number {i % 1000} with some text\n")
    out.write(f"print-lines {lines}\n")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)

import os
import subprocess
import sys
import tempfile


def main():
    text = sys.stdin.read()
    with tempfile.TemporaryDirectory(prefix="orders-") as directory:
        with open(os.path.join(directory, "orders.csv"), "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        done = subprocess.run(sys.argv[1:] + ["orders.csv", "report.json"], cwd=directory,
                              capture_output=True, text=True, timeout=30)
        sys.stderr.write(done.stderr)
        sys.stdout.write(done.stdout)
        print("--- files")
        for name in sorted(os.listdir(directory)):
            print(name)
        print("--- report.json")
        path = os.path.join(directory, "report.json")
        if os.path.isfile(path):
            with open(path, encoding="utf-8", newline="") as handle:
                print(repr(handle.read()))
        else:
            print("(missing)")
        with open(os.path.join(directory, "orders.csv"), encoding="utf-8", newline="") as handle:
            print("input unchanged:", "yes" if handle.read() == text else "no")
        print(f"--- exit {done.returncode}")


main()

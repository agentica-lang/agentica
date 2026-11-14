"""The peer of tests/fixtures/vm/format.agc in Python: the same lines, written with Python's printf-style `%`."""
import math
import struct
import sys

# Text-mode stdout writes CRLF on Windows; the VM and Node write LF.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")


def special(x, width=0, left=False):
    """A %f of NaN or an infinity: Python writes nan and inf, Ruby and Agentica NaN and Inf, padded with spaces."""
    word = "NaN" if math.isnan(x) else ("Inf" if x > 0 else "-Inf")
    return word.ljust(width) if left else word.rjust(width)


def row(name, price, count):
    return "%-8s|%8.3f|%04d|%x" % (name, price, count, count)


def main():
    print(row("apple", 2.5, 7))
    print(row("crème", -0.125, -255))
    print("[%d] [%5d] [%-5d] [%05d] [%-05d] [%0d]" % (42, -42, -42, -42, 42, 7))
    print("[%x] [%6x] [%-6x] [%06x] [%x] [%x]" % (255, -255, 48879, -1, 0, -(2 ** 63)))
    print("[%20d] [%-21d]" % (2 ** 63 - 1, -(2 ** 63)))
    for x in [0.5, 1.5, 2.5, 2.675, 1.005, -0.5, -0.0, 0.125, 1e-7, 123456.789]:
        print("%f|%.0f|%.1f|%.2f|%.3f|%10.4f|%-10.1f|%010.2f" % (x, x, x, x, x, x, x, x))
    print("%.50f" % 0.1)
    print("%.17f|%.20f" % (1.0 / 3.0, 2.0 / 3.0))
    print("%.1f" % 1.7976931348623157e308)
    print("%.3f|%.0f" % (5e-324, 1e22))
    nan = struct.unpack("<d", struct.pack("<Q", 9221120237041090560))[0]
    inf = struct.unpack("<d", struct.pack("<Q", 9218868437227405312))[0]
    print("[%s] [%s] [%s] [%s] [%s] [%s]" % (special(nan), special(nan, 6), special(inf, 6, True), special(inf, 6),
                                             special(-inf), special(-inf, 7)))
    print("[%s] [%7s] [%-7s] [%3s] [%s]" % ("héllo", "héllo", "日本", "toolong", "[1, 2]"))
    print("100%% of %s is %5.1f%%" % ("x", 99.95))
    n = 5
    n = len("%3d|%d" % (n * 2, n))
    print(n)
    print("in %03d text" % n)
    print("%.2f" % 3.14159)


main()

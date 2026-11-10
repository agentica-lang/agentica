"""The peer of tests/fixtures/vm/implicit-return.agc in Python: the same functions, each value given by `return`."""
import sys

# Text-mode stdout writes CRLF on Windows; the VM and Node write LF.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")


def area(shape):
    kind = shape[0]
    if kind == "square":
        return shape[1] * shape[1]
    if kind == "rect":
        return shape[1] * shape[2]
    return area(shape[1]) + area(shape[2])


def label(n):
    if n == 0:
        return "none"
    if n == 1:
        return "one"
    if n < 0:
        if n == -1:
            return "minus one"
        return "far below" if n < -100 else "below"
    return "%d items" % n


def fib(n):
    return n if n < 2 else fib(n - 1) + fib(n - 2)


def twice(item):
    return [item, item]


def parsed(text):
    try:
        return ("ok", int(text) + 1)
    except ValueError:
        return ("error", None)


def square(n):
    return n * n


def shown(result):
    return "ok %d" % result[1] if result[0] == "ok" else "error"


print(area(("square", 3)))
print(area(("pair", ("rect", 2, 5), ("square", 1))))
for n in [0, 1, -1, -5, -500, 7]:
    print(label(n))
print(fib(15))
print(",".join(twice("ab")))
print(shown(parsed("41")))
print(shown(parsed("x")))
print(square(12))
print("say done")

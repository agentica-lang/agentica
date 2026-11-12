"""The peer of tests/fixtures/vm/lambdas.agc in Python: the same function values, as Python lambdas and closures."""
import sys

# Text-mode stdout writes CRLF on Windows; the VM and Node write LF.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")


def add(a, b, c):
    return a + b + c


def apply_twice(f, x):
    return f(f(x))


def compose(f, g, x):
    return g(f(x))


def adder(n):
    return lambda x: x + n


def to_i(text):
    return ("ok", int(text)) if text.lstrip("-").isdigit() else ("error", 'cannot convert "%s" to Int' % text)


def parse_double(text):
    def doubled(s):
        result = to_i(s)
        if result[0] == "error":
            return result
        return ("ok", result[1] * 2)

    return doubled(text)


def shown(result):
    if result[0] == "ok":
        return "ok(%d)" % result[1]
    return 'error("%s")' % result[1].replace('"', '\\"')


def first(xs):
    return "first of %d" % len(xs)


def sign(x):
    if x < 0:
        return "negative"
    return "not negative"


def main():
    c = 100
    f = lambda a, b: add(a, b, c)
    print(f(1, 2))
    base = 10
    inc = lambda x: x + base
    print(inc(5))
    answer = lambda: 42
    print(answer())
    gen = {"name": "next", "make": lambda seed: seed + 1}
    print("%s %d" % (gen["name"], gen["make"](1)))
    ops = {"add": lambda a, b: a + b, "sub": lambda a, b: a - b}
    print(ops["add"](2, 3))
    print(ops["sub"](2, 3))
    steps = [lambda x: x + 1, lambda x: x * 3]
    print("[%s]" % ", ".join(str(step(2)) for step in steps))
    print(apply_twice(lambda x: x * x, 3))
    print(compose(lambda n: "%d!" % n, len, 12345))
    print(adder(7)(1))
    print(sign(-3))
    print(sign(4))
    curried = lambda a: lambda b: a * 10 + b
    print(curried(4)(2))
    labels = []
    for n in [1, 2]:
        label = lambda suffix, n=n: "%d%s" % (n, suffix)
        labels.append(label("st"))
    print("[%s]" % ", ".join('"%s"' % text for text in labels))
    print(shown(parse_double("21")))
    print(shown(parse_double("x")))
    xs = [1, 2, 3]
    print(sum(x * 2 for x in xs))
    print(sum(x for x in (x * 2 for x in xs) if x > 2))
    for x in xs:
        print(x * c)
    print(sum(xs))
    for key, value in {"a": 1, "b": 2}.items():
        print("%s=%d" % (key, value))
    # The program's own first wins over the method of that name.
    print(first(xs))
    print(xs[0])


main()

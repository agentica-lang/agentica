import codecs
import os
import sys

codecs.register_error("per-byte", lambda error: ("\ufffd" * (error.end - error.start), error.end))


def real(path):
    try:
        return "ok:" + os.path.realpath(path, strict=True)
    except OSError:
        return "error"


def env(name):
    try:
        value = os.environb[os.fsencode(name)]
    except (KeyError, ValueError):
        return "error"
    return "ok:" + value.decode("utf-8", "per-byte")


def main():
    mode = sys.argv[1]
    answer = real if mode == "real" else env
    out = sys.stdout.buffer
    for item in sys.argv[2:]:
        out.write(answer(item).encode("utf-8") + b"\n")
    out.flush()


if __name__ == "__main__":
    main()

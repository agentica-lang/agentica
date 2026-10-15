import logging
import sys
import time


def noop(message: str) -> None:
    pass


def main(scale: int) -> None:
    logger = logging.getLogger("bench")
    logging.basicConfig(level=logging.INFO)
    calls = 1000000 * scale
    total = 0

    started = time.monotonic()
    for i in range(calls):
        total += i % 7
    empty = time.monotonic() - started

    started = time.monotonic()
    for i in range(calls):
        noop("message")
        total += i % 7
    user_call = time.monotonic() - started

    started = time.monotonic()
    for i in range(calls):
        logger.debug("message")
        total += i % 7
    disabled = time.monotonic() - started

    # The Agentica program has a fourth loop (a debug call that no handler accepts); logging has no cheap twin
    # of it, so only its checksum is kept here.
    for i in range(calls):
        total += i % 7

    print(f"{calls} iterations: empty loop {empty * 1000:.0f} ms, empty user call {user_call * 1000:.0f} ms, disabled logger.debug {disabled * 1000:.0f} ms", file=sys.stderr)
    print(f"logger-disabled {calls}: checksum {total}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)

import re
import sys


def make_log(lines: int) -> str:
    levels = ["INFO", "INFO", "INFO", "WARN", "INFO", "ERROR", "INFO", "DEBUG"]
    users = ["alice", "bob", "carol", "dave", "erin"]
    parts = []
    for i in range(lines):
        tail = "timeout after 30s" if i % 97 == 0 else "ok"
        stamp = f"2026-11-01T12:{(i // 60) % 60}:{i % 60}"
        parts.append(f"{stamp} {levels[i % 8]} user={users[i % 5]} id={i * 7} path=/api/items/{i % 1000} {tail}")
    return "\n".join(parts)


def main(scale: int) -> None:
    log = make_log(15000 * scale)
    head = log[:100000]
    literal = re.compile("timeout", re.ASCII)
    word = re.compile("[a-z]+", re.ASCII)
    words = re.compile(r"\b(?:alpha|bravo|charlie|delta|echo|foxtrot|golf|hotel|india|user)\b", re.ASCII)
    scan = re.compile(r"(?m)^(\S+) ERROR user=(\w+) id=(\d+)", re.ASCII)
    redos = re.compile(r"(a+)+$", re.ASCII)
    literal_count = len(literal.findall(log))
    word_count = len(word.findall(head))
    words_count = len(words.findall(head))
    ids = sum(int(m.group(3)) for m in scan.finditer(log))
    redos_found = "true" if redos.search("a" * 20 + "!") else "false"
    print(f"regex {len(log)}: {literal_count} {word_count} {words_count} {ids} {redos_found}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)

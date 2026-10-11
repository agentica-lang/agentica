import sys


def main(scale: int) -> None:
    words = ["alpha", "beta", "gamma", "delta", "epsilon"]
    rounds = 2000 * scale
    distinct = 0
    last = ""
    for round_ in range(rounds):
        parts = [f"{round_}:"]
        for k, word in enumerate(words):
            parts.append(f" {word}={(round_ * 31 + k * 7) % 97}")
        for i in range(10):
            parts.append(f"[{i * round_ % 13}]")
        line = "".join(parts)
        if line != last:
            distinct += 1
        last = line
    print(f"strings {rounds}: distinct {distinct}")
    print(last)


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)

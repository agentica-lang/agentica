import sys


def main(scale: int) -> None:
    rounds = 4 * scale
    total = 0
    for round_ in range(rounds):
        filled = [round_] * 500000
        numbers = list(range(500000))
        backwards = numbers[::-1]
        head = backwards[:250000]
        tail = backwards[250000:]
        joined = head + tail
        text = "".join(["x"] * 300000)
        letters = list(text)
        ordered = sorted(backwards[:60000])
        total = (total + filled[round_] + numbers[round_] + backwards[round_] + len(head) + len(tail)
                 + joined[499999] + len(letters) + len(text) + ordered[round_]) % 1000000007
    print(f"list-bulk {rounds}: checksum {total}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)

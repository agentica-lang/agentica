import sys


def main(scale: int) -> None:
    rounds = 2 * scale
    text = " ".join(["ab,cd ef,,g"] * 3000)
    n = len(text)
    checksum = 0
    for _ in range(rounds):
        # One-character Strings: at, slice, from_code and split("").
        for i in range(n):
            checksum += ord(text[i]) + ord(text[i:i + 1]) + ord(chr(97 + i % 26))
        checksum += len(list(text))

        # Empty Strings: pieces between separators, a slice of no characters, blanks trimmed away and a join of nothing.
        for piece in text.split(","):
            checksum += len(piece[0:0]) + len("  ".strip(" \t\n\f\r")) + len(piece.strip(" \t\n\f\r")) + len(",".join([]))

        # Empty Lists and Maps: a default for a missing key, a seed for reduce, a filter that keeps nothing.
        groups: dict[int, list[int]] = {}
        for j in range(8000):
            groups[j % 101] = groups.get(j % 101, []) + [j]
        counts: dict[int, int] = {}
        for word in text.split(" "):
            counts[len(word)] = counts.get(len(word), 0) + 1
        drops = 0
        for k in range(8000):
            drops += len([x for x in [k, k + 1, k + 2, k + 3] if x < 0])
        checksum += len(groups) + len(groups.get(7, [])) + len(counts) + counts.get(2, 0) + drops

        # Empty Sets: a Set built from nothing, the last element deleted and a difference with nothing left.
        seen = 0
        for m in range(8000):
            one = {m}
            seen += len(set()) + len(one - {m}) + len(one - one)
        checksum = (checksum + seen) % 1000000007
    print(f"small-values {rounds}: checksum {checksum}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)

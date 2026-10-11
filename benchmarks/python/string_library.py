import sys


def main(scale: int) -> None:
    base = "Crème brûlée, naïve café; Straße ΟΔΥΣΣΕΥΣ 😀 smörgåsbord, jalapeño"
    rounds = 300 * scale
    checksum = 0
    last = ""
    for round_ in range(rounds):
        text = f"{round_}: {base}, {base}"
        words = [part.strip().upper() for part in text.split(", ")]
        swapped = " | ".join(words).replace("É", "e").lower()
        found = swapped.find("smörgåsbord")
        checksum += found if found >= 0 else -1
        checksum += sum(ord(c) % 7 for c in swapped)
        last = swapped
    print(f"string-library {rounds}: {checksum}")
    print(last)


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)

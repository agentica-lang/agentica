import sys


def digits(text: str) -> bool:
    return text != "" and all("0" <= c <= "9" for c in text)


def main() -> None:
    with open(sys.argv[1], encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split(" ")
            if len(parts) != 6 or not (digits(parts[0]) and digits(parts[4]) and digits(parts[5])):
                continue
            if parts[1] == "" or parts[2] == "" or parts[3] == "":
                continue
            if int(parts[4]) >= 500 and int(parts[5]) >= 800:
                print(f"{parts[0]} {parts[1]} {parts[5]}")


if __name__ == "__main__":
    main()

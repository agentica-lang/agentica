import sys


def line_total(quantity, price):
    return quantity * price


def main():
    total = 0
    for line in sys.stdin.read().split("\n"):
        if not line.strip():
            continue
        parts = line.strip().split(" ")
        quantity = parts[1]
        price = parts[2]
        amount = line_total(quantity, price)
        print(parts[0] + ": " + amount)
        total = total + amount
    print("total: " + total)


main()

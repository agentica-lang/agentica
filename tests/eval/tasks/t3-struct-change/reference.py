import sys

total = 0
for line in sys.stdin.read().split("\n"):
    if not line.strip():
        continue
    name, price, quantity = line.strip().split(" ")
    price, quantity = int(price), int(quantity)
    print(f"{name}: {price} x {quantity} = {price * quantity}")
    total += price * quantity
print(f"total: {total}")

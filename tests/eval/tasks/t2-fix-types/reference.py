import sys

total = 0.0
for line in sys.stdin.read().split("\n"):
    if not line.strip():
        continue
    parts = line.strip().split(" ")
    amount = int(parts[1]) * float(parts[2])
    print(parts[0] + ": " + str(amount))
    total = total + amount
print("total: " + str(total))
